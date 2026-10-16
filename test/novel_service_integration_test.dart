import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/novel/novel_locator.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/novel/novel_webdav_exchange.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _bookA = NovelBook(sourceId: 'wenku8', url: 'https://fixture.invalid/a', title: '同一文本版本');
const _bookB = NovelBook(sourceId: 'syosetu', url: 'https://fixture.invalid/b', title: '同一文本版本');
const _chapterA = NovelChapter(url: 'https://fixture.invalid/a/1', title: '第一章', volume: '第一卷', kind: '正文', number: 1);
const _chapterB = NovelChapter(url: 'https://fixture.invalid/b/7', title: '不同目录标题', volume: '不同卷名', kind: '正文', number: 7);
const _text = '这是两个测试书源共享的正文内容，仅用于确认映射、保存、重启以及因果同步。';
const _novelRoot = '/kazumiSync/novels/v1';
const _videoSentinel = '/kazumiSync/history/snapshot.json';

NovelPosition _position(String edition, int offset, {String source = 'wenku8', NovelChapter chapter = _chapterA}) =>
    NovelLocator.capture(editionId: edition, sourceId: source, chapter: chapter,
      text: _text, offset: offset, updatedAt: offset + 1);

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override Future<String?> getApplicationSupportPath() async => path;
}

/// An observable HTTP WebDAV peer. Production webdav_client performs every
/// OPTIONS/MKCOL/PROPFIND/GET/PUT/MOVE request; no client or transport is mocked.
class _HttpDav {
  late final HttpServer server;
  final files = <String, List<int>>{_videoSentinel: utf8.encode('existing video history sentinel')};
  final directories = <String>{'/', '/kazumiSync', '/kazumiSync/history'};
  final requests = <(String, String)>[];
  final errors = <Object>[];
  String? failOperation;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await _handle(request);
      } catch (error) {
        errors.add(error);
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    });
  }

  String get url => 'http://127.0.0.1:${server.port}';
  Set<String> get snapshots => files.keys.where((path) => path.startsWith('$_novelRoot/') &&
      NovelWebDavExchange.snapshotName.hasMatch(path.split('/').last)).toSet();
  int get snapshotGets => requests.where((r) => r.$1 == 'GET' && r.$2.startsWith('$_novelRoot/')).length;
  static String _path(String value) => value.length > 1 && value.endsWith('/') ? value.substring(0, value.length - 1) : value;
  static String _parent(String value) => value.substring(0, value.lastIndexOf('/')).isEmpty ? '/' : value.substring(0, value.lastIndexOf('/'));
  static String _xml(String value) => const HtmlEscape(HtmlEscapeMode.element).convert(value);
  String _entry(String path, bool directory) => '<d:response><d:href>${_xml(directory && path != '/' ? '$path/' : path)}</d:href>'
      '<d:propstat><d:prop><d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype>'
      '<d:getcontentlength>${directory ? 0 : files[path]!.length}</d:getcontentlength>'
      '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';

  Future<void> _handle(HttpRequest request) async {
    final path = _path(request.uri.path);
    final method = request.method;
    requests.add((method, path));
    final body = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    final response = request.response;
    if (method == failOperation && path.startsWith('$_novelRoot/')) {
      response.statusCode = HttpStatus.serviceUnavailable;
      response.write('injected $method failure');
    } else {
      switch (method) {
        case 'OPTIONS':
          response.statusCode = HttpStatus.ok;
          response.headers.set('DAV', '1, 2');
          response.headers.set('Allow', 'OPTIONS, MKCOL, PROPFIND, GET, PUT, MOVE');
        case 'MKCOL':
          response.statusCode = directories.add(path) ? HttpStatus.created : HttpStatus.methodNotAllowed;
        case 'PROPFIND':
          if (!directories.contains(path)) {
            response.statusCode = HttpStatus.notFound;
            break;
          }
          response.statusCode = HttpStatus.multiStatus;
          response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
          // webdav_client skips the first collection response as the collection itself.
          final children = [...directories.where((p) => p != path && p != '/' && _parent(p) == path),
            ...files.keys.where((p) => _parent(p) == path)]..sort();
          response.write('<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">'
            '${_entry(path, true)}${children.map((p) => _entry(p, directories.contains(p))).join()}'
            '</d:multistatus>');
        case 'GET':
          if (!files.containsKey(path)) {
            response.statusCode = HttpStatus.notFound;
            break;
          }
          response.statusCode = HttpStatus.ok;
          response.headers.contentType = ContentType.binary;
          response.contentLength = files[path]!.length;
          response.add(files[path]!);
        case 'PUT':
          if (!directories.contains(_parent(path))) {
            response.statusCode = HttpStatus.conflict;
            break;
          }
          files[path] = body;
          response.statusCode = HttpStatus.created;
        case 'MOVE':
          final destination = _path(Uri.parse(request.headers.value('destination')!).path);
          if (!files.containsKey(path)) {
            response.statusCode = HttpStatus.notFound;
            break;
          }
          if (files.containsKey(destination)) {
            response.statusCode = HttpStatus.preconditionFailed;
            break;
          }
          files[destination] = files.remove(path)!;
          response.statusCode = HttpStatus.created;
        default:
          throw StateError('Unexpected WebDAV method $method $path');
      }
    }
    await response.close();
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final webDav = WebDav();
  late Directory root;
  late Directory caseDirectory;
  late PathProviderPlatform originalPaths;
  HttpOverrides? originalHttpOverrides;
  late _HttpDav remote;
  NovelService? active;

  Future<void> closeDevice() async {
    await GStorage.putSetting(SettingsKeys.webDavEnableNovels, false);
    active?.dispose();
    active = null;
    for (final name in ['novel_v1', 'novel_cache_v1', 'novel_rules_v1']) {
      if (Hive.isBoxOpen(name)) await Hive.box<String>(name).close();
    }
    webDav.initialized = false;
  }

  Future<NovelService> device(String name) async {
    await closeDevice();
    final directory = Directory('${caseDirectory.path}/$name');
    await directory.create(recursive: true);
    PathProviderPlatform.instance = _TestPaths(directory.path);
    final service = NovelService(webDav);
    active = service;
    await service.init();
    return service;
  }

  Future<String> seed(NovelService service) async {
    await service.importRule(await File('novel_rules/wenku8.json').readAsString());
    await service.importRule(await File('novel_rules/syosetu.json').readAsString());
    final edition = await service.bind(animeId: 42, book: _bookA,
      editionLabel: 'fixture identical text', language: 'zh');
    await service.bind(animeId: 43, book: _bookB, editionLabel: 'fixture identical text',
      language: 'zh', existingEditionId: edition);
    return edition;
  }

  Future<void> sync(NovelService service) async {
    await GStorage.putSetting(SettingsKeys.webDavEnableNovels, true);
    try {
      await service.sync();
    } finally {
      await GStorage.putSetting(SettingsKeys.webDavEnableNovels, false);
    }
  }

  setUpAll(() async {
    Logger.level = Level.off;
    originalHttpOverrides = HttpOverrides.current;
    // This suite deliberately uses real loopback HTTP instead of Flutter's
    // widget-test HttpClient stub. No public source URL is requested.
    HttpOverrides.global = null;
    originalPaths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('kazumis_book_integration_');
    PathProviderPlatform.instance = _TestPaths('${root.path}/settings');
    Hive.init('${root.path}/settings');
    await GStorage.init();
  });

  setUp(() async {
    await GStorage.resetSettings(SettingsKeys.byGroup(SettingGroup.webdav));
    caseDirectory = await root.createTemp('case_');
    remote = _HttpDav();
    await remote.start();
    await GStorage.putSetting(SettingsKeys.webDavURL, remote.url);
    await GStorage.putSetting(SettingsKeys.webDavUsername, 'fixture');
    await GStorage.putSetting(SettingsKeys.webDavPassword, 'fixture-only');
    await GStorage.putSetting(SettingsKeys.webDavEnable, true);
  });

  tearDown(() async {
    await closeDevice();
    await remote.close();
    expect(remote.errors, isEmpty);
    expect(utf8.decode(remote.files[_videoSentinel]!), 'existing video history sentinel');
    expect(remote.requests.where((r) => r.$2 == _videoSentinel), isEmpty,
      reason: 'Novel sync must not read or mutate legacy video files.');
  });

  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    HttpOverrides.global = originalHttpOverrides;
    expect(root.absolute.path.startsWith(Directory.systemTemp.absolute.path), isTrue);
    expect(root.uri.pathSegments.where((part) => part.isNotEmpty).last,
      startsWith('kazumis_book_integration_'));
    await root.delete(recursive: true);
  });

  test('first use installs separate rules once and retains deletion after restart', () async {
    remote.files['/rules/catalog.json'] = utf8.encode(jsonEncode({'version': 1, 'rules': [
      {'id': 'wenku8', 'file': 'wenku8.json', 'replaces': <String>[]},
      {'id': 'syosetu', 'file': 'syosetu.json', 'replaces': <String>[]},
    ]}));
    for (final id in ['wenku8', 'syosetu']) {
      remote.files['/rules/$id.json'] = await File('novel_rules/$id.json').readAsBytes();
    }
    var service = await device('automatic-rules');
    await service.saveRuleCatalogUrl('${remote.url}/rules/catalog.json');
    await Future.wait([service.ensureDefaultRules(), service.ensureDefaultRules()]);
    expect(service.rules.map((r) => r.id), unorderedEquals(['wenku8', 'syosetu']));
    expect(service.preferredSource, 'wenku8');
    expect(remote.requests.where((r) => r.$2 == '/rules/catalog.json').length, 1);
    await service.removeRule('syosetu');
    await service.selectSource('wenku8');
    final count = remote.requests.length;
    service = await device('automatic-rules');
    await service.ensureDefaultRules();
    expect(service.rules.map((r) => r.id), ['wenku8']);
    expect(service.preferredSource, 'wenku8');
    expect(remote.requests.length, count);
  });

  test('0.1.0 source deletion survives adding new defaults on upgrade', () async {
    remote.files['/rules/catalog.json'] = await File('novel_rules/catalog.json').readAsBytes();
    for (final id in ['wenku8', 'syosetu', 'linovel', 'lightnovel']) {
      remote.files['/rules/$id.json'] = await File('novel_rules/$id.json').readAsBytes();
    }
    final service = await device('legacy-rule-upgrade');
    await service.importRule(await File('novel_rules/syosetu.json').readAsString());
    await Hive.box<String>('novel_v1').put('defaultRulesInstalled', '1');
    final rewrite = InterceptorsWrapper(onRequest: (options, handler) {
      if (options.uri.toString().startsWith(NovelService.defaultCatalog.replaceAll('catalog.json', ''))) {
        options.path = '${remote.url}/rules/${options.uri.pathSegments.last}';
      }
      handler.next(options);
    });
    DioFactory.pluginDio.interceptors.add(rewrite);
    try {
      await service.ensureDefaultRules();
      expect(service.rules.map((r) => r.id), unorderedEquals(['syosetu', 'linovel', 'lightnovel']));
    } finally {
      DioFactory.pluginDio.interceptors.remove(rewrite);
    }
  });

  for (final action in ['import', 'delete']) {
    test('background default upgrade preserves a concurrent manual $action', () async {
      final service = await device('concurrent-rule-$action');
      final old = await File('novel_rules/wenku8.json').readAsString();
      await service.importRule(old);
      final stored = service.rules.single;
      final replacement = jsonEncode({...stored.json, 'name': '默认新版书源'});
      remote.files['/rules/catalog.json'] = utf8.encode(jsonEncode({'version': 1, 'rules': [
        {'id': 'wenku8', 'file': 'wenku8.json', 'replaces': [sha256.convert(utf8.encode(stored.encode())).toString()]},
        {'id': 'syosetu', 'file': 'syosetu.json', 'replaces': <String>[]},
      ]}));
      remote.files['/rules/wenku8.json'] = utf8.encode(replacement);
      remote.files['/rules/syosetu.json'] = await File('novel_rules/syosetu.json').readAsBytes();
      await service.saveRuleCatalogUrl('${remote.url}/rules/catalog.json');
      final blocked = Completer<void>(), release = Completer<void>();
      final dio = DioFactory.pluginDio;
      final interceptor = InterceptorsWrapper(onRequest: (options, handler) async {
        if (options.uri.path == '/rules/syosetu.json') {
          blocked.complete();
          await release.future;
        }
        handler.next(options);
      });
      dio.interceptors.add(interceptor);
      final update = service.ensureDefaultRules();
      try {
        await blocked.future.timeout(const Duration(seconds: 5));
        if (action == 'import') {
          await service.importRule(jsonEncode({...stored.json, 'name': '我的自定义书源'}));
        } else {
          await service.removeRule('wenku8');
        }
        release.complete();
        await update;
        if (action == 'import') {
          expect(service.rules.firstWhere((rule) => rule.id == 'wenku8').name, '我的自定义书源');
        } else {
          expect(service.rules.any((rule) => rule.id == 'wenku8'), isFalse);
          expect(Hive.box<String>('novel_v1').get('ruleRemoved/wenku8'), '1');
        }
        expect(service.needsDefaultRules, isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        await update;
        dio.interceptors.remove(interceptor);
      }
    });
  }

  test('legacy shelves retain membership; new shelf membership syncs to another device', () async {
    var service = await device('A');
    final edition = await seed(service);
    final stored = Hive.box<String>('novel_v1');
    final envelope = jsonDecode(stored.get('state')!) as Map<String, dynamic>;
    // Reproduce a 0.1.0 edition by removing only its new preview field.
    final old = service.state.edit('edition/$edition', {
      ...service.state.value('edition/$edition')!, 'preview': false,
    }, service.deviceId);
    envelope['data'] = old.encode();
    await stored.put('state', jsonEncode(envelope));
    service = await device('A');
    expect(service.isShelved(edition), true);
    await service.addToShelf(edition, animeId: 42);
    await sync(service);
    service = await device('B');
    await sync(service);
    expect(service.shelfEditions.single.id, edition);
    expect(service.state.value('shelf/$edition')!['animeId'], 42);
  });

  test('interrupted default rule install reports failure without partial registry and retries', () async {
    remote.files['/rules/catalog.json'] = utf8.encode(jsonEncode({'version': 1, 'rules': [
      {'id': 'wenku8', 'file': 'wenku8.json', 'replaces': <String>[]},
      {'id': 'syosetu', 'file': 'syosetu.json', 'replaces': <String>[]},
    ]}));
    remote.files['/rules/wenku8.json'] = await File('novel_rules/wenku8.json').readAsBytes();
    final service = await device('rule-download-retry');
    await service.saveRuleCatalogUrl('${remote.url}/rules/catalog.json');
    await expectLater(service.ensureDefaultRules(), throwsA(isA<DioException>()));
    expect(service.rules, isEmpty);
    remote.files['/rules/syosetu.json'] = await File('novel_rules/syosetu.json').readAsBytes();
    await service.ensureDefaultRules();
    expect(service.rules.length, 2);
  });

  test('known previous default upgrades but custom rules and old v1 catalogs remain supported', () async {
    final current = jsonDecode(await File('novel_rules/wenku8.json').readAsString()) as Map<String, dynamic>;
    final old = Map<String, dynamic>.from(current)..remove('login');
    old['revision'] = '2026-10-17.2';
    old['headers'] = {'Referer': 'https://www.wenku8.net/'};
    var service = await device('old-default');
    await service.importRule(jsonEncode(old));
    final oldHash = sha256.convert(utf8.encode(service.rules.single.encode())).toString();
    final index = jsonDecode(await File('novel_rules/catalog.json').readAsString()) as Map<String, dynamic>;
    expect((index['rules'] as List).singleWhere((r) => r['id'] == 'wenku8')['replaces'], contains(oldHash));
    remote.files['/rules/catalog.json'] = utf8.encode(jsonEncode(index));
    for (final id in ['wenku8', 'syosetu', 'linovel', 'lightnovel']) {
      remote.files['/rules/$id.json'] = await File('novel_rules/$id.json').readAsBytes();
    }
    await service.saveRuleCatalogUrl('${remote.url}/rules/catalog.json');
    await service.ensureDefaultRules();
    expect(service.rule('wenku8').headers['Accept-Encoding'], 'identity');
    service = await device('custom-old-index');
    current['name'] = '本机自定义文库';
    await service.importRule(jsonEncode(current));
    remote.files['/rules/catalog.json'] = utf8.encode(jsonEncode({'version': 1,
      'rules': [{'id': 'wenku8', 'file': 'wenku8.json'}]}));
    await service.saveRuleCatalogUrl('${remote.url}/rules/catalog.json');
    await service.ensureDefaultRules();
    expect(service.rules.single.name, '本机自定义文库');
  });

  test('cross-source chapter identity remains stable after reopening the target source', () async {
    var service = await device('A');
    final edition = await seed(service);
    final original = await service.chapterReadIdentity(edition, _bookA, _chapterA, null);
    expect(await service.recordReadChapters(edition, {original}), 1);
    final mapped = await service.chapterReadIdentity(edition, _bookB, _chapterB, _position(edition, 5));
    expect(mapped, original);
    service = await device('A');
    final reopened = await service.chapterReadIdentity(edition, _bookB, _chapterB,
      _position(edition, 9, source: 'syosetu', chapter: _chapterB));
    expect(reopened, original);
    expect(await service.recordReadChapters(edition, {mapped, reopened}), 1);
  });

  test('preview progress is separate from shelf membership and survives restart', () async {
    var service = await device('A');
    final edition = await seed(service);
    expect(service.shelfEditions, isEmpty);
    expect(await service.recordReadChapters(edition, {_chapterA.url}), 1);
    service = await device('A');
    expect(await service.recordReadChapters(edition, {_chapterA.url, _chapterB.url}), 2);
    expect(service.shelfEditions, isEmpty);
    await service.addToShelf(edition, animeId: 42);
    service = await device('A');
    expect(service.shelfEditions.single.id, edition);
    expect(service.state.value('shelf/$edition')!['animeId'], 42);
    expect(service.animeIdsForEdition(edition), containsAll([42, 43]));
    expect(service.editionForBook(_bookA), edition);
  });

  test('disk restart preserves position, bookmark, local preferences and both mapping directions', () async {
    var service = await device('A');
    final edition = await seed(service);
    final deviceId = service.deviceId;
    final original = _position(edition, 5);
    await service.savePosition(original);
    await service.addBookmark(original, '跨源书签');
    await service.confirmChapterMapping(original, _bookB, _chapterB);
    await service.savePreferences({...service.preferences, 'fontSize': 27.0});
    await service.saveRuleCatalogUrl('https://fixture.invalid/custom/catalog.json');
    final bookmarkId = service.bookmarks(edition).single['id'] as String;

    service = await device('A');
    expect(service.deviceId, deviceId);
    expect(service.rules.map((r) => r.id).toSet(), {'wenku8', 'syosetu'});
    expect(service.position(edition)!.textOffset, 5);
    expect(service.bookmarks(edition).single['note'], '跨源书签');
    expect(service.preferences['fontSize'], 27.0);
    expect(service.ruleCatalogUrl, 'https://fixture.invalid/custom/catalog.json');
    expect(service.boundEditions(42), [edition]);
    expect(service.boundEditions(43), [edition]);
    expect(service.mappedChapter(original, _bookB)!.url, _chapterB.url);
    expect(service.mappedChapter(_position(edition, 5, source: 'syosetu', chapter: _chapterB), _bookA)!.url, _chapterA.url);

    await service.deleteBookmark(bookmarkId);
    service = await device('A');
    expect(service.bookmarks(edition), isEmpty);
    expect(service.state.revisions('bookmark/$bookmarkId').single.value, isNull);
    expect(remote.requests, isEmpty);
  });

  test('real HTTP sync persists seen snapshots and resolves two offline devices without touching video data', () async {
    var service = await device('A');
    final edition = await seed(service);
    final deviceA = service.deviceId;
    await service.savePosition(_position(edition, 4));
    await service.addBookmark(_position(edition, 4), '同步书签');
    await service.confirmChapterMapping(_position(edition, 4), _bookB, _chapterB);
    await sync(service);
    expect(remote.snapshots, hasLength(1));
    expect(remote.requests.map((r) => r.$1).toSet(), containsAll(['OPTIONS', 'MKCOL', 'PROPFIND', 'PUT', 'MOVE']));

    service = await device('A');
    remote.requests.clear();
    await sync(service);
    expect(remote.snapshotGets, 0, reason: 'Seen names must survive a disk restart.');

    service = await device('B');
    expect(service.deviceId, isNot(deviceA));
    remote.requests.clear();
    await sync(service);
    expect(remote.snapshotGets, 1);
    expect(service.position(edition)!.textOffset, 4);
    expect(service.bookmarks(edition).single['note'], '同步书签');
    expect(service.mappedChapter(_position(edition, 4), _bookB)!.url, _chapterB.url);
    await service.savePosition(_position(edition, 2));
    await sync(service);

    service = await device('A');
    await service.savePosition(_position(edition, 8));
    remote.requests.clear();
    await sync(service);
    expect(remote.snapshotGets, 2, reason: 'Only B initial and B edited snapshots are unseen.');
    final key = 'position/$edition';
    expect(service.state.revisions(key), hasLength(2));
    expect(() => service.position(edition), throwsStateError);
    final selected = service.state.revisions(key).singleWhere((r) => r.value!['textOffset'] == 2);
    await service.resolve(key, selected);
    await sync(service);

    service = await device('B');
    await sync(service);
    expect(service.state.conflicts, isEmpty);
    expect(service.position(edition)!.textOffset, 2, reason: 'Explicit earlier progress wins; never take maximum progress.');
    remote.requests.clear();
    await sync(service);
    expect(remote.snapshotGets, 0);
  });

  for (final operation in ['PUT', 'MOVE']) {
    test('$operation failure preserves old published state and newer local progress across restart', () async {
      var service = await device('A');
      final edition = await seed(service);
      await service.savePosition(_position(edition, 8));
      await sync(service);
      final oldSnapshot = remote.snapshots.single;
      final oldBytes = List<int>.of(remote.files[oldSnapshot]!);
      await service.savePosition(_position(edition, 2));
      remote.failOperation = operation;
      await expectLater(sync(service), throwsA(isA<DioException>()));
      expect(remote.snapshots, {oldSnapshot});
      expect(remote.files[oldSnapshot], oldBytes);
      expect(service.position(edition)!.textOffset, 2);
      expect(service.syncError, isNotNull);

      service = await device('A');
      expect(service.position(edition)!.textOffset, 2);
      remote.failOperation = null;
      await sync(service);
      expect(remote.snapshots, hasLength(2));
      expect(remote.files[oldSnapshot], oldBytes);
      expect(service.syncError, isNull);
      expect(remote.requests.where((r) => r.$1 == 'DELETE'), isEmpty);
    });
  }
}
