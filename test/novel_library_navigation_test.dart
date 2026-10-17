import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/novel/novel_book_cover.dart';
import 'package:kazumi/novel/novel_library_page.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_rule.dart';
import 'package:kazumi/novel/novel_rules_page.dart';
import 'package:kazumi/novel/novel_rule_catalog_page.dart';
import 'package:kazumi/novel/novel_entry.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/novel/novel_sync_state.dart';
import 'package:kazumi/pages/menu/menu.dart';
import 'package:kazumi/pages/collect/collect_module.dart';
import 'package:kazumi/pages/collect/collect_page.dart';
import 'package:kazumi/pages/collect/collect_library_tabs.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _book = NovelBook(
  sourceId: 'source-a',
  url: 'https://source/book/1',
  title: '已入架的小说',
  cover: 'https://source/covers/1.png',
);

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Library extends NovelService {
  _Library(this.bytes) : super(WebDav());
  final Uint8List bytes;
  final images = <(String, String)>[];
  final removed = <String>{};
  bool failRemove = false;
  int shelfCount = 1, syncCalls = 0;
  @override
  Future<void> sync() async { syncCalls++; }
  @override
  Future<void> removeFromShelf(String id) async {
    if (failRemove) throw StateError('删除写入失败');
    removed.add(id);
    notifyListeners();
  }
  @override
  List<NovelRule> get rules => const [];
  @override
  String? get ruleCatalogUrl => 'https://rules.test/catalog.json';
  @override
  Future<void> ensureDefaultRules() async {}
  @override
  Future<List<BangumiItem>> relatedAnime(NovelBook book,
      {String? editionId, bool refresh = false}) async => [BangumiItem.fromJson({
        'id': 42, 'type': 2, 'name': '已入架的小说', 'name_cn': '已入架的小说',
        'rating': {'rank': 1, 'score': 8.0, 'total': 1},
        'images': <String, String>{},
      })];
  @override
  List<NovelEdition> get shelfEditions => [
    for (var i = 0; i < shelfCount; i++)
      if (!removed.contains(i == 0 ? 'e' : 'e$i'))
        NovelEdition(i == 0 ? 'e' : 'e$i', 'w', '中文', 'zh'),
  ];
  @override
  NovelWork work(String id) => const NovelWork('w', '已入架的小说', '作者');
  @override
  NovelBook? selectedBook(String id) => _book;
  @override
  Future<Uint8List> image(String source, String url) async {
    images.add((source, url));
    return bytes;
  }
}

class _Collection extends CollectCrudRepository {
  @override
  List<CollectedBangumi> getAllCollectibles() => [CollectedBangumi(
    BangumiItem.fromJson({
      'id': 42, 'type': 2, 'name': '已入架的小说', 'name_cn': '已入架的小说',
      'rating': {'rank': 1, 'score': 8.0, 'total': 1},
      'images': <String, String>{},
    }), DateTime(2026), 1,
  )];
}

class _CatalogNetwork implements HttpClientAdapter {
  final requests = <String>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream,
      Future<void>? cancelFuture) async {
    requests.add(options.uri.toString());
    return ResponseBody.fromString(
      '{"version":1,"rules":[{"id":"fixture","name":"路由测试书源",'
      '"file":"rule.json","description":"受控仓库响应"}]}', 200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }
  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  late Uint8List cover;
  setUpAll(() async {
    final image = await createTestImage(width: 8, height: 8);
    cover = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    paths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('book-library-nav-');
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    await root.delete(recursive: true);
  });
  for (final size in [const Size(480, 900), const Size(1280, 900)]) {
    testWidgets(
      'heart opens anime first; the neighboring bookshelf tab at $size displays source cover',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        final service = _Library(cover);
        service.state = NovelSyncState()
            .edit('edition/e', const NovelEdition('e', 'w', '中文', 'zh').toJson(), 'a')
            .edit('edition/e2', const NovelEdition('e2', 'w', '中文', 'zh').toJson(), 'a')
            .edit('anime/42', {'animeId': 42, 'editionIds': ['e', 'e2']}, 'a');
        final repository = _Collection();
        final network = _CatalogNetwork();
        final previousAdapter = DioFactory.pluginDio.httpClientAdapter;
        DioFactory.pluginDio.httpClientAdapter = network;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          service.dispose();
          DioFactory.pluginDio.httpClientAdapter = previousAdapter;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final module = createModule(
          register: (c) {
            c.addSingleton<NovelService>(() => service);
            c.addSingleton<CollectController>(
              () => CollectController(repository),
            );
            c.route(
              '/tab/',
              child: (context, state) => ScaffoldMenu(location: state.uri.path),
              children: (sub) {
                for (final name in ['popular', 'timeline', 'my']) {
                  sub.route(
                    '/$name/',
                    child: (_, _) => Center(child: Text('page:$name')),
                  );
                }
                sub.module(collectModule);
              },
            );
          },
        );
        await tester.pumpWidget(
          ModularApp(
            module: module,
            initialRoute: '/tab/collect/',
            child: Builder(
              builder: (context) => MaterialApp.router(
                routerConfig: ModularApp.routerConfigOf(context),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CollectPage), findsOneWidget);
        expect(find.byType(NovelLibraryPage), findsNothing);
        await tester.tap(
          find.descendant(
            of: find.byType(CollectLibraryTabs),
            matching: find.text('书架'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(NovelLibraryPage), findsOneWidget);
        expect(find.text('已入架的小说'), findsOneWidget);
        expect(service.images, [('source-a', 'https://source/covers/1.png')]);
        expect(find.byType(Image), findsOneWidget);
        expect(find.byTooltip('查看番剧详情'), findsOneWidget);
        if (size.width < size.height) {
          final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
          expect(nav.selectedIndex, 2);
          expect(nav.destinations, hasLength(4));
          expect((nav.destinations[2] as NavigationDestination).label, '追番');
        } else {
          final nav = tester.widget<NavigationRail>(
            find.byType(NavigationRail),
          );
          expect(nav.selectedIndex, 2);
          expect(nav.destinations, hasLength(4));
        }
        await tester.tap(find.byTooltip('小说规则'));
        await tester.pumpAndSettle();
        expect(find.byType(NovelRulesPage), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(NovelLibraryPage), findsOneWidget,
            reason: 'System back from novel rules must restore the same bookshelf.');
        expect(find.byType(NovelRulesPage), findsNothing);
        await tester.tap(find.byTooltip('小说规则'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('添加规则'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('浏览规则仓库'));
        await tester.pumpAndSettle();
        expect(find.byType(NovelRuleCatalogPage), findsOneWidget);
        expect(find.text('路由测试书源'), findsOneWidget);
        expect(network.requests, ['https://rules.test/catalog.json']);
        await tester.tap(find.descendant(of: find.byType(NovelRuleCatalogPage),
            matching: find.byIcon(Icons.arrow_back)));
        await tester.pumpAndSettle();
        expect(find.byType(NovelRuleCatalogPage), findsNothing,
            reason: 'The catalog app bar arrow must only pop the catalog route.');
        expect(find.byType(NovelRulesPage), findsOneWidget);
        await tester.tap(find.descendant(of: find.byType(NovelRulesPage),
            matching: find.byIcon(Icons.arrow_back)));
        await tester.pumpAndSettle();
        expect(find.byType(NovelRulesPage), findsNothing,
            reason: 'The rules app bar arrow must pop its own imperative route.');
        expect(find.byType(NovelLibraryPage), findsOneWidget);
        expect(find.text('page:popular'), findsNothing);
        await tester.tap(find.text('搜索小说'));
        await tester.pumpAndSettle();
        expect(find.byType(NovelSearchPage), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(NovelLibraryPage), findsOneWidget,
            reason: 'System back from source selection must restore the same bookshelf.');
        await tester.tap(find.byTooltip('小说操作'));
        await tester.pumpAndSettle();
        expect(find.text('更换书源'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(NovelLibraryPage), findsOneWidget,
            reason: 'System back from book actions must restore the same bookshelf.');
        await tester.tap(find.byIcon(Icons.favorite));
        await tester.pumpAndSettle();
        expect(find.byType(CollectPage), findsOneWidget);
        expect(find.byType(NovelLibraryPage), findsNothing);
        await tester.tap(find.byTooltip('阅读《已入架的小说》的轻小说'));
        await tester.pumpAndSettle();
        expect(find.text('选择小说'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('选择小说'), findsNothing);
        expect(find.byType(CollectPage), findsOneWidget,
            reason: 'System back from linked books must restore anime collection.');
        expect(find.text('page:popular'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('source cover is retained across unrelated library rebuilds', (
    tester,
  ) async {
    final service = _Library(cover);
    addTearDown(service.dispose);
    for (var i = 0; i < 2; i++) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NovelBookCover(service: service, book: _book),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }
    expect(service.images, hasLength(1));
    expect(find.bySemanticsLabel('已入架的小说封面'), findsOneWidget);
  });

  testWidgets('bookshelf uses a cover grid and deletes only after confirming; errors remain visible', (tester) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _Library(cover)..shelfCount = 2;
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(home: NovelLibraryPage(service: service)));
    await tester.pumpAndSettle();
    final covers = find.byType(NovelBookCover);
    expect(covers, findsNWidgets(2));
    expect(tester.getTopLeft(covers.first).dy, tester.getTopLeft(covers.last).dy);
    expect(tester.getSize(covers.first).width, greaterThan(100));
    Future<void> removeMenu() async {
      await tester.tap(find.byTooltip('小说操作').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除书籍'));
      await tester.pumpAndSettle();
    }
    await removeMenu();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.removed, isEmpty);
    service.failRemove = true;
    await removeMenu();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除写入失败'), findsOneWidget);
    expect(service.removed, isEmpty);
    service.failRemove = false;
    await removeMenu();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(service.removed, {'e'});
    expect(covers, findsOneWidget);
    expect(service.syncCalls, 0);
    await tester.tap(find.byTooltip('同步小说'));
    await tester.pumpAndSettle();
    expect(service.syncCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabling bookshelf cloud sync waits for the manual button', (tester) async {
    final service = _Library(cover);
    addTearDown(service.dispose);
    await tester.runAsync(() async {
      await GStorage.putSetting(SettingsKeys.webDavEnable, true);
      await GStorage.putSetting(SettingsKeys.webDavEnableNovels, false);
    });
    addTearDown(() => tester.runAsync(() => GStorage.resetSettings(SettingsKeys.byGroup(SettingGroup.webdav))));
    await tester.pumpWidget(MaterialApp(home: NovelLibraryPage(service: service)));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('WebDAV 手动同步阅读进度与书签')));
    await tester.pumpAndSettle();
    expect(GStorage.getSetting(SettingsKeys.webDavEnableNovels), isTrue);
    expect(service.syncCalls, 0);
    await tester.tap(find.byTooltip('同步小说'));
    await tester.pumpAndSettle();
    expect(service.syncCalls, 1);
  });
  testWidgets('unrelated conflicts remain visible without hiding the normal bookshelf', (tester) async {
    final service = _Library(cover);
    addTearDown(service.dispose);
    const key = 'bookmark/another-book';
    service.state = NovelSyncState().edit(key, {
      'id': 'another-book', 'note': '另一部书的书签',
      'position': {'editionId': 'other', 'chapter': {'volume': '一卷', 'title': '第一章'}, 'quote': '原文'},
    }, 'a').merge(NovelSyncState().edit(key, null, 'b'));
    final before = service.state.encode();
    await tester.pumpWidget(MaterialApp(home: NovelLibraryPage(service: service)));
    await tester.pumpAndSettle();
    expect(find.text('已入架的小说'), findsOneWidget);
    expect(find.text('书签有冲突'), findsOneWidget);
    expect(find.bySemanticsLabel('已入架的小说封面'), findsOneWidget);
    await tester.tap(find.text('书签有冲突'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.state.encode(), before);
    expect(find.text('已入架的小说'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('book lookup skips an unrelated source conflict but reports a related one', () {
    final service = NovelService(WebDav());
    addTearDown(service.dispose);
    const unrelated = NovelBook(sourceId: 'source-a', url: 'https://source/other', title: '别的小说');
    service.state = NovelSyncState()
        .edit('edition/other', const NovelEdition('other', 'w2', '中文', 'zh').toJson(), 'a')
        .edit('edition/e', const NovelEdition('e', 'w', '中文', 'zh').toJson(), 'a')
        .edit('source/other/source-a', {'editionId': 'other', 'book': unrelated.toJson()}, 'a')
        .edit('source/e/source-a', {'editionId': 'e', 'book': _book.toJson()}, 'a')
        .merge(NovelSyncState().edit('source/other/source-a', null, 'b'));
    expect(service.editionForBook(_book), 'e');
    expect(() => service.editionForBook(unrelated), throwsStateError);
  });
  testWidgets('invalid source cover bytes report a decoding error', (
    tester,
  ) async {
    final service = _Library(Uint8List.fromList([0, 1, 2]));
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NovelBookCover(service: service, book: _book),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
