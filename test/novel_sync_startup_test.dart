import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/novel/novel_book_cover.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/novel/novel_sync_state.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override Future<String?> getApplicationSupportPath() async => path;
}
class _Remote extends Fake implements WebDav {
  NovelSyncState snapshot = NovelSyncState();
  int calls = 0;
  bool fail = false;
  Completer<void>? pending;
  final merged = <NovelSyncState>[];
  @override Future<String?> syncNovels({required String deviceId,
    required Set<String> knownSnapshots, void Function()? onLegacyDetected,
    required Future<NovelSyncState> Function(NovelSyncState, Set<String>) merge}) async {
    calls++;
    await pending?.future;
    if (fail) throw StateError('fixture offline');
    merged.add(await merge(snapshot, {'fixture-snapshot'}));
    return null;
  }
}
class _Network implements HttpClientAdapter {
  _Network(this.png, this.rule);
  final Uint8List png;
  final String rule;
  final requests = <String>[];
  bool failCatalog = false;
  Completer<void>? pending;
  @override Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    final path = options.uri.path;
    requests.add(path);
    if (path.endsWith('/catalog.json')) {
      await pending?.future;
      return ResponseBody.fromString('{"version":1,"rules":[{"id":"wenku8","file":"wenku8.json"}]}',
        failCatalog ? 503 : 200);
    }
    if (path.endsWith('/wenku8.json')) return ResponseBody.fromString(rule, 200);
    if (path == '/cover.png') return ResponseBody.fromBytes(png, 200);
    if (path == '/book/1.htm') return ResponseBody.fromString('<a href="/catalog.htm">小说目录</a>', 200);
    if (path == '/catalog.htm') return ResponseBody.fromString('<table><tr><td class="vcss">第一卷</td></tr>'
      '<tr><td class="ccss"><a href="/1.htm">第一章</a></td></tr></table>', 200);
    throw StateError('Unexpected request: ${options.uri}');
  }
  @override void close({bool force = false}) {}
}
const _book = NovelBook(sourceId: 'wenku8', url: 'https://fixture.invalid/book/1.htm',
  title: '同步测试书', cover: 'https://fixture.invalid/cover.png');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  late NovelService service;
  late _Remote remote;
  late _Network network;
  late Uint8List png;
  late String rule;
  setUpAll(() async {
    Logger.level = Level.off;
    paths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('novel-sync-startup-');
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
    final image = await createTestImage(width: 8, height: 8);
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    image.dispose();
    final json = jsonDecode(await File('novel_rules/wenku8.json').readAsString()) as NovelJson;
    json['encoding'] = 'utf-8';
    rule = jsonEncode(json);
  });
  setUp(() async {
    final profile = await root.createTemp('device-');
    PathProviderPlatform.instance = _Paths(profile.path);
    await GStorage.putSetting(SettingsKeys.webDavEnable, true);
    await GStorage.putSetting(SettingsKeys.webDavEnableNovels, true);
    await GStorage.putSetting(SettingsKeys.webDavURL, 'https://dav.fixture.invalid');
    network = _Network(png, rule);
    DioFactory.pluginDio.httpClientAdapter = network;
    remote = _Remote();
    service = NovelService(remote);
    await service.init();
  });
  tearDown(() async {
    service.dispose();
    for (final name in ['novel_v1', 'novel_cache_v1', 'novel_rules_v1']) {
      await Hive.box<String>(name).close();
    }
    DioFactory.reset();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    await root.delete(recursive: true);
  });
  test('fresh synced shelf waits for the default rule before loading cover and reader catalog', () async {
    remote.snapshot = NovelSyncState()
      .edit('work/w', const NovelWork('w', '同步测试书', '').toJson(), 'remote')
      .edit('edition/e', const NovelEdition('e', 'w', '中文', 'zh').toJson(), 'remote')
      .edit('source/e/wenku8', {'book': _book.toJson()}, 'remote')
      .edit('selected/e', {'sourceId': 'wenku8'}, 'remote');
    await service.sync();
    expect(service.rules, isEmpty);
    expect(service.syncError, isNull);
    expect(service.shelfEditions.single.id, 'e');
    network.pending = Completer<void>();
    final catalog = service.catalog(_book);
    final cover = service.image(_book.sourceId, _book.cover);
    network.pending!.complete();
    expect((await catalog).single.title, '第一章');
    expect(await cover, png);
    expect(network.requests.where((p) => p.endsWith('/catalog.json')), hasLength(1));
    expect(service.state.covers(remote.snapshot), isTrue);
  });
  testWidgets('failed cover reloads when its missing custom rule is imported', (tester) async {
    await tester.runAsync(service.ensureDefaultRules);
    const book = NovelBook(sourceId: 'custom', url: 'https://fixture.invalid/book/1.htm',
      title: '自定义源', cover: 'https://fixture.invalid/cover.png');
    await tester.pumpWidget(MaterialApp(home: ListenableBuilder(listenable: service,
      builder: (_, _) => NovelBookCover(service: service, book: book))));
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byTooltip('封面加载失败：Bad state: 尚未安装书源“custom”，请在小说规则中导入对应规则'), findsOneWidget);
    await tester.runAsync(() async {
      final json = jsonDecode(rule) as NovelJson;
      json['id'] = 'custom';
      await service.importRule(jsonEncode(json));
      await service.image('custom', book.cover);
    });
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  test('default rule network failure stays explicit and retries on a later open', () async {
    network.failCatalog = true;
    await expectLater(service.catalog(_book), throwsA(isA<DioException>()));
    network.failCatalog = false;
    expect((await service.catalog(_book)).single.title, '第一章');
  });
  test('an intentionally deleted rule is not silently reinstalled', () async {
    await service.ensureDefaultRules();
    await service.removeRule('wenku8');
    final requests = network.requests.length;
    await expectLater(service.catalog(_book), throwsStateError);
    expect(network.requests.length, requests);
  });
  test('automatic events honor settings, flush current reader before syncing and expose failures', () async {
    await GStorage.putSetting(SettingsKeys.webDavEnableNovels, false);
    await service.syncAutomatically();
    expect(remote.calls, 0);
    await GStorage.putSetting(SettingsKeys.webDavEnableNovels, true);
    service.saveReader = () async => false;
    await service.syncAutomatically();
    expect(remote.calls, 0);
    expect(service.syncError, contains('尚未保存'));
    var saved = false;
    service.saveReader = () async { saved = true; return true; };
    remote.fail = true;
    await service.syncAutomatically();
    expect(saved, isTrue);
    expect(service.syncError, contains('fixture offline'));
    service.saveReader = null;
    remote.fail = false;
    await service.syncAutomatically();
    expect(remote.calls, 2);
    expect(service.syncError, isNull);
  });
  test('exit event queued behind startup is awaited rather than discarded', () async {
    remote.pending = Completer<void>();
    final startup = service.syncAutomatically();
    await Future<void>.delayed(Duration.zero);
    final closing = service.syncAutomatically();
    await Future<void>.delayed(Duration.zero);
    expect(remote.calls, 1);
    remote.pending!.complete();
    await Future.wait([startup, closing]);
    expect(remote.calls, 2);
    expect(service.syncing, isFalse);
  });
}
