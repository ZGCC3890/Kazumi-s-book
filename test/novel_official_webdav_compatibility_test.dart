import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:hive_ce/src/adapters/big_int_adapter.dart';
import 'package:hive_ce/src/adapters/date_time_adapter.dart';
import 'package:hive_ce/src/adapters/duration_adapter.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/history_sync_service.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _novels = '/kazumiSync/novels';
const _novelFile = '$_novels/v1/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-'
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

/// A real HTTP peer for the unchanged upstream viewing/collection sync paths.
/// Requests and MOVE destinations are recorded, including attempted deletions.
class _DavPeer {
  late HttpServer server;
  final files = <String, List<int>>{
    _novelFile: utf8.encode('immutable novel snapshot sentinel'),
    '$_novels/v1/unfinished.cache': utf8.encode('novel upload sentinel'),
  };
  final directories = <String>{'/', '/kazumiSync', _novels, '$_novels/v1'};
  final requests = <(String, String)>[];
  final errors = <Object>[];
  String get url => 'http://127.0.0.1:${server.port}/';
  static String pathOf(String path) => path.length > 1 && path.endsWith('/')
      ? path.substring(0, path.length - 1) : path;
  static String parent(String path) {
    final index = path.lastIndexOf('/');
    return index == 0 ? '/' : path.substring(0, index);
  }
  String entry(String path) {
    final isDirectory = directories.contains(path);
    final href = const HtmlEscape(HtmlEscapeMode.element)
        .convert(isDirectory && path != '/' ? '$path/' : path);
    return '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
        '<d:resourcetype>${isDirectory ? '<d:collection/>' : ''}</d:resourcetype>'
        '<d:getcontentlength>${isDirectory ? 0 : files[path]!.length}</d:getcontentlength>'
        '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
  }
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await handle(request);
      } catch (error) {
        errors.add(error);
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    });
  }
  Future<void> handle(HttpRequest request) async {
    final path = pathOf(request.uri.path);
    final method = request.method;
    requests.add((method, path));
    final body = await request.fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
    final response = request.response;
    switch (method) {
      case 'OPTIONS':
        response.headers.set('DAV', '1, 2');
        response.headers.set('Allow', 'OPTIONS, PROPFIND, MKCOL, GET, PUT, MOVE, DELETE');
      case 'MKCOL':
        response.statusCode = directories.add(path) ? 201 : 405;
      case 'PROPFIND':
        if (!directories.contains(path)) {
          response.statusCode = 404;
          break;
        }
        response.statusCode = 207;
        response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
        final children = [...directories.where((p) => p != '/' && p != path && parent(p) == path),
          ...files.keys.where((p) => parent(p) == path)]..sort();
        response.write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
            '${entry(path)}${children.map(entry).join()}</d:multistatus>');
      case 'GET':
        final bytes = files[path];
        if (bytes == null) {
          response.statusCode = 404;
          break;
        }
        response.headers.contentType = ContentType.binary;
        response.contentLength = bytes.length;
        response.add(bytes);
      case 'PUT':
        if (!directories.contains(parent(path))) {
          response.statusCode = 409;
          break;
        }
        files[path] = body;
        response.statusCode = 201;
      case 'DELETE':
        if (directories.contains(path)) throw StateError('Unexpected directory deletion: $path');
        response.statusCode = files.remove(path) == null ? 404 : 204;
      case 'MOVE':
        final destination = pathOf(Uri.parse(request.headers.value('destination')!).path);
        requests.add(('MOVE-TO', destination));
        if (!files.containsKey(path)) {
          response.statusCode = 404;
          break;
        }
        if (files.containsKey(destination) && request.headers.value('overwrite') != 'T') {
          response.statusCode = 412;
          break;
        }
        files[destination] = files.remove(path)!;
        response.statusCode = 201;
      default:
        throw StateError('Unexpected request: $method $path');
    }
    await response.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final webDav = WebDav();
  late Directory root;
  late _DavPeer peer;
  late PathProviderPlatform originalPaths;
  HttpOverrides? originalHttpOverrides;

  Future<void> switchDevice(String name) async {
    await Hive.close();
    Hive.resetAdapters();
    // resetAdapters also removes the built-ins normally registered by the
    // HiveImpl/TypeRegistryImpl constructor. Restore that exact initialization
    // before GStorage.init registers the app's own adapters for this device.
    Hive.registerAdapter(DateTimeWithTimezoneAdapter(), internal: true);
    Hive.registerAdapter(DateTimeAdapter<DateTimeWithoutTZ>(), internal: true);
    Hive.registerAdapter(BigIntAdapter(), internal: true);
    Hive.registerAdapter(DurationAdapter(), internal: true);
    final directory = Directory('${root.path}/$name');
    await directory.create(recursive: true);
    PathProviderPlatform.instance = _Paths(directory.path);
    Hive.init('${directory.path}/hive');
    await GStorage.init();
    await GStorage.putSetting(SettingsKeys.webDavURL, peer.url);
    await GStorage.putSetting(SettingsKeys.webDavUsername, 'fixture');
    await GStorage.putSetting(SettingsKeys.webDavPassword, 'fixture-only');
    await GStorage.putSetting(SettingsKeys.webDavEnable, true);
    await GStorage.putSetting(SettingsKeys.webDavEnableHistory, true);
    await GStorage.putSetting(SettingsKeys.webDavEnableCollect, true);
    webDav.initialized = false;
    await webDav.init();
  }

  setUpAll(() async {
    Logger.level = Level.off;
    originalPaths = PathProviderPlatform.instance;
    originalHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('kazumis_official_compat_');
    peer = _DavPeer();
    await peer.start();
  });

  tearDownAll(() async {
    await Hive.close();
    await peer.server.close(force: true);
    PathProviderPlatform.instance = originalPaths;
    HttpOverrides.global = originalHttpOverrides;
    expect(peer.errors, isEmpty);
    expect(root.absolute.path.startsWith(Directory.systemTemp.absolute.path), isTrue);
    expect(root.uri.pathSegments.where((s) => s.isNotEmpty).last, startsWith('kazumis_official_compat_'));
    await root.delete(recursive: true);
  });

  test('upstream-compatible viewing and collection sync round-trip without touching novels', () async {
    // These production methods and their Hive models are unchanged from
    // upstream/main 025dcb5. This executes their real webdav_client HTTP calls;
    // it does not claim an official packaged application's UI was launched.
    final novelBefore = peer.files.map((key, value) => MapEntry(key, List<int>.of(value)));
    final anime = BangumiItem(id: 42, type: 2, name: 'test', nameCn: '兼容测试番剧',
        summary: '', airDate: '2026-01-01', airWeekday: 1, rank: 0,
        images: {}, tags: [], alias: [], ratingScore: 7, votes: 1, votesCount: [], info: '');
    final initialTime = DateTime.utc(2026, 1, 1);
    final laterTime = initialTime.add(const Duration(days: 1));
    await switchDevice('official-compatible-a');
    await GStorage.collectibles.put(anime.id, CollectedBangumi(anime, initialTime, 1));
    final history = History(anime, 2, 'fixture-source', initialTime,
        'https://fixture.invalid/anime', '第二集')
      ..progresses[2] = Progress(2, 0, 12000, updatedAtMs: initialTime.millisecondsSinceEpoch);
    await GStorage.histories.put(history.key, history);
    await GStorage.collectibles.flush();
    await GStorage.histories.flush();
    await HistorySyncService().appendUpsertProgress(history: history, episode: 2,
        road: 0, progressMs: 12000);
    await webDav.syncCollectibles();
    await webDav.syncHistory();
    expect(peer.files.containsKey('/kazumiSync/collectibles.tmp'), isTrue);
    expect(peer.files.containsKey('/kazumiSync/history/snapshot.json'), isTrue);

    await switchDevice('book-b');
    expect(GStorage.collectibles, isEmpty);
    expect(GStorage.histories, isEmpty);
    await webDav.syncCollectibles();
    await webDav.syncHistory();
    expect(GStorage.collectibles.get(anime.id)!.type, 1);
    final imported = GStorage.histories.get(history.key)!;
    expect(imported.progresses[2]!.progress.inMilliseconds, 12000);
    expect(imported.lastWatchEpisode, 2);
    expect(imported.adapterName, 'fixture-source');

    await GStorage.collectibles.put(anime.id, CollectedBangumi(anime, laterTime, 4));
    final changeId = laterTime.millisecondsSinceEpoch ~/ 1000;
    await GStorage.collectChanges.put(changeId, CollectedBangumiChange(changeId, anime.id, 2, 4, changeId));
    imported.lastWatchTime = laterTime;
    imported.progresses[2] = Progress(2, 0, 34321, updatedAtMs: laterTime.millisecondsSinceEpoch);
    await GStorage.histories.put(history.key, imported);
    await GStorage.collectibles.flush();
    await GStorage.collectChanges.flush();
    await GStorage.histories.flush();
    await HistorySyncService().appendUpsertProgress(history: imported, episode: 2,
        road: 0, progressMs: 34321);
    await webDav.syncCollectibles();
    await webDav.syncHistory();

    await switchDevice('official-compatible-a');
    await webDav.syncCollectibles();
    await webDav.syncHistory();
    expect(GStorage.collectibles.get(anime.id)!.type, 4);
    expect(GStorage.histories.get(history.key)!.progresses[2]!.progress.inMilliseconds, 34321);
    expect(peer.files['/kazumiSync/collectchanges.tmp'], isNotEmpty);
    expect(peer.files.entries.where((entry) => entry.key.startsWith(_novels))
        .map((entry) => entry.key).toSet(), novelBefore.keys.toSet());
    for (final entry in novelBefore.entries) {
      expect(peer.files[entry.key], orderedEquals(entry.value));
    }
    expect(peer.requests.where((request) => request.$2.startsWith(_novels)), isEmpty,
        reason: 'Official-compatible sync must not read, write, rename or delete novel files or directories.');
    expect(peer.requests.map((request) => request.$1).toSet(),
        containsAll(['OPTIONS', 'PROPFIND', 'MKCOL', 'GET', 'PUT', 'MOVE', 'DELETE']));
  });
}
