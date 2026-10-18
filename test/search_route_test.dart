import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/modules/search/search_history_module.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/novel/novel_rule.dart';
import 'package:kazumi/novel/novel_rules_page.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_reader_page.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/menu/menu.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/pages/popular/popular_page.dart';
import 'package:kazumi/pages/search/image_search_page.dart';
import 'package:kazumi/pages/search/search_module.dart';
import 'package:kazumi/pages/search/search_page.dart';
import 'package:kazumi/pages/search/search_controller.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/repositories/search_history_repository.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Popular extends PopularController {
  @override
  Future<void> queryBangumiByTrend({String type = 'add'}) async {}
}

class _RulesService extends NovelService {
  _RulesService() : super(WebDav());
  final source = _NovelSource();
  NovelBook? selected;
  NovelPosition? saved;
  @override
  List<NovelRule> get rules => [NovelRule.decode(
      File('novel_rules/linovel.json').readAsStringSync())];
  @override String? get preferredSource => 'linovel';
  @override bool get needsDefaultRules => false;
  @override NovelSourceAdapter adapter(String id) => source;
  @override Future<List<BangumiItem>> relatedAnime(NovelBook book,
      {String? editionId, bool refresh = false}) async => [];
  @override Future<String> bind({required int animeId, required NovelBook book,
      required String editionLabel, required String language,
      String? existingEditionId, String? existingWorkId}) async {
    selected = book;
    return 'route-edition';
  }
  @override NovelBook? selectedBook(String id) => selected;
  @override NovelJson get preferences => {
    'fontSize': 20.0, 'lineHeight': 1.8, 'theme': 0, 'mode': 'scroll',
    'font': 'system', 'margin': 24.0, 'brightness': 0.0,
  };
  @override Future<List<NovelChapter>> catalog(NovelBook book, {bool refresh = false}) async =>
      const [NovelChapter(url: 'https://test/chapter', title: '路由章节',
          volume: '第一卷', kind: '正文', number: 1)];
  @override Future<List<NovelBlock>> content(String sourceId, NovelChapter chapter,
      {bool refresh = false}) async => const [NovelBlock.text('规则页返回后真正打开的正文。')];
  @override NovelPosition? position(String editionId) => saved;
  @override Future<void> savePosition(NovelPosition position) async { saved = position; }
  @override Future<String> chapterReadIdentity(String editionId, NovelBook book,
      NovelChapter chapter, NovelPosition? restoredFrom) async => chapter.url;
  @override Future<void> retrySync() async {}
}

class _NovelSource extends Fake implements NovelSourceAdapter {
  final queries = <String>[];
  @override Future<List<NovelBook>> search(String keyword) async {
    queries.add(keyword);
    return const [NovelBook(sourceId: 'linovel', url: 'https://test/book',
        title: 'Fixture novel', author: 'Author A')];
  }
}

// Keep this route test about production DI/navigation. Filesystem persistence
// is exercised by integration tests and the installed Android app flows.
class _Collect extends Fake implements ICollectRepository {
  bool private = false;
  @override
  bool getPrivateMode() => private;
}

class _History implements ISearchHistoryRepository {
  final values = <SearchHistory>[];
  @override
  List<SearchHistory> getAllHistories() => List.of(values);
  @override
  Future<bool> saveHistory(String keyword) async {
    values.add(SearchHistory(keyword, values.length + 1));
    return true;
  }

  @override
  Future<void> deleteDuplicates(String keyword) async =>
      values.removeWhere((value) => value.keyword == keyword);
  @override
  bool isHistoryFull(int maxCount) => values.length >= maxCount;
  @override
  Future<void> deleteOldest() async {
    values.removeAt(0);
  }

  @override
  Future<void> deleteHistory(SearchHistory history) async {
    values.remove(history);
  }

  @override
  Future<void> clearAllHistories() async {
    values.clear();
  }
}

class _Bangumi implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'data': [
          {
            'id': 55770,
            'name': '入口结果番剧',
            'name_cn': '入口结果番剧',
            'rating': {'rank': 10, 'total': 3, 'score': 8.0},
            'images': <String, String>{},
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _open(
  WidgetTester tester,
  NovelService novels, {
  Size size = const Size(480, 900),
  String initialRoute = '/tab/popular/',
  TargetPlatform? platform,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  final module = createModule(
    register: (c) {
      c.addSingleton<ICollectRepository>(_Collect.new);
      c.addSingleton<ISearchHistoryRepository>(_History.new);
      c.addSingleton<NovelService>(() => novels);
      c.module(
        createModule(
          path: '/tab',
          register: (tabs) {
            tabs.route(
              '/',
              child: (context, state) => ScaffoldMenu(location: state.uri.path),
              children: (sub) {
                sub.route(
                  '/popular/',
                  child: (_, _) => PopularPage(controller: _Popular()),
                );
              },
            );
          },
        ),
      );
      // Use the production module, page-scoped controller and route builders.
      c.module(searchModule);
    },
  );
  await tester.pumpWidget(
    ModularApp(
      module: module,
      initialRoute: initialRoute,
      navigatorObservers: [rootRouteObserver],
      child: Builder(
        builder: (context) => MaterialApp.router(
          theme: platform == null ? null : ThemeData(platform: platform),
          routerConfig: ModularApp.routerConfigOf(context),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _clickSearch(WidgetTester tester, Size size) async {
  if (size.width > size.height) {
    await tester.tap(find.widgetWithIcon(FloatingActionButton, Icons.search));
  } else {
    await tester.tap(find.byTooltip('搜索'));
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  late _Bangumi network;
  late NovelService novels;
  setUpAll(() async {
    paths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('book-search-route-');
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
  });
  setUp(() async {
    await GStorage.searchHistory.clear();
    DioFactory.reset();
    network = _Bangumi();
    DioFactory.bangumiDio.httpClientAdapter = network;
    novels = NovelService(WebDav());
  });
  tearDown(() async {
    novels.dispose();
    DioFactory.reset();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    expect(
      root.uri.pathSegments.where((part) => part.isNotEmpty).last,
      startsWith('book-search-route-'),
    );
    await root.delete(recursive: true);
  });

  test('novels and anime persist to one bounded history and respect private mode', () async {
    final collect = _Collect();
    final controller = SearchPageController(collect, SearchHistoryRepository());
    await controller.rememberSearch('辉夜小说');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await controller.searchBangumi('辉夜番剧', type: 'init');
    expect(controller.searchHistories.map((item) => item.keyword), ['辉夜番剧', '辉夜小说']);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await controller.rememberSearch('小说$i');
    }
    expect(controller.searchHistories, hasLength(10));
    expect(controller.searchHistories.any((item) => item.keyword == '辉夜小说'), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await controller.rememberSearch('小说4');
    expect(controller.searchHistories, hasLength(10));
    expect(controller.searchHistories.first.keyword, '小说4');
    final stored = controller.searchHistories.map((item) => item.keyword).toList();
    collect.private = true;
    await controller.rememberSearch('无痕小说');
    collect.private = false;
    await controller.rememberSearch('   ');
    final reopened = SearchPageController(collect, SearchHistoryRepository())..loadSearchHistories();
    expect(reopened.searchHistories.map((item) => item.keyword), stored);
  });

  for (final size in [const Size(480, 900), const Size(1280, 800)]) {
    testWidgets(
      'actual home/menu search opens, searches, switches and reopens $size',
      (tester) async {
        await _open(tester, novels, size: size);
        expect(find.byType(PopularPage), findsOneWidget);
        await _clickSearch(tester, size);
        expect(tester.takeException(), isNull);
        expect(find.byType(ErrorWidget), findsNothing);
        expect(
          tester.widget<SearchPage>(find.byType(SearchPage)).novelService,
          same(novels),
        );
        await tester.enterText(find.byType(TextField), '入口查询');
        await tester.tap(find.byTooltip('搜索'));
        await tester.pumpAndSettle();
        expect(network.requests.single.data['keyword'], '入口查询');
        expect(find.text('入口结果番剧'), findsOneWidget);
        await tester.tap(find.byTooltip('搜索类型'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('小说').last);
        await tester.pumpAndSettle();
        expect(find.text('小说搜索'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '',
        );
        await tester.tap(find.byIcon(Icons.arrow_back).first);
        await tester.pumpAndSettle();
        expect(find.byType(PopularPage), findsOneWidget);
        await _clickSearch(tester, size);
        expect(
          tester.widget<SearchPage>(find.byType(SearchPage)).novelService,
          same(novels),
        );
        expect(find.text('番剧搜索'), findsOneWidget);
        expect(find.text('入口查询'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scenario in [
    (const Size(480, 900), '尚未提交的书名', TargetPlatform.android),
    (const Size(1280, 800), '尚未提交的书名', TargetPlatform.android),
    (const Size(840, 600), '', TargetPlatform.windows),
    (const Size(1280, 860), '', TargetPlatform.windows),
  ]) {
    final (size, draft, platform) = scenario;
    testWidgets('novel rules app bar returns to the production search route $size $platform', (tester) async {
      final service = _RulesService();
      addTearDown(service.dispose);
      await _open(tester, service, size: size, platform: platform);
      await _clickSearch(tester, size);
      final original = tester.widget<SearchPage>(find.byType(SearchPage));
      await tester.tap(find.byTooltip('搜索类型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小说').last);
      await tester.pumpAndSettle();
      if (draft.isNotEmpty) await tester.enterText(find.byType(TextField), draft);
      await tester.tap(find.byTooltip('小说规则'));
      await tester.pumpAndSettle();
      expect(find.byType(NovelRulesPage), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(NovelRulesPage),
          matching: find.byIcon(Icons.arrow_back)));
      await tester.pumpAndSettle();
      expect(find.byType(NovelRulesPage), findsNothing);
      expect(find.byType(SearchPage), findsOneWidget);
      expect(tester.widget<SearchPage>(find.byType(SearchPage)).controller,
          same(original.controller));
      expect(find.text('小说搜索'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          draft);
      await tester.enterText(find.byType(TextField), 'Fixture');
      final submit = find.byTooltip('搜索');
      await tester.ensureVisible(submit);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(service.source.queries, ['Fixture']);
      expect(find.text('Fixture novel'), findsOneWidget);
      await tester.tap(find.text('Fixture novel'));
      await tester.pumpAndSettle();
      expect(find.text('小说详情'), findsNothing);
      expect(service.selected?.title, 'Fixture novel');
      expect(find.byType(NovelReaderPage), findsOneWidget);
      expect(find.text('规则页返回后真正打开的正文。'), findsOneWidget);
      expect(service.saved?.chapter.title, '路由章节');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('production encoded tag route opens and submits the tag filter', (
    tester,
  ) async {
    await _open(
      tester,
      novels,
      initialRoute: '/search/${Uri.encodeComponent('奇幻')}',
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.widget<SearchPage>(find.byType(SearchPage)).novelService,
      same(novels),
    );
    expect(network.requests.single.data['filter']['tag'], contains('奇幻'));
    expect(find.text('入口结果番剧'), findsOneWidget);
  });

  testWidgets(
    'production image route opens and returns to the same search page',
    (tester) async {
      await _open(tester, novels);
      await _clickSearch(tester, const Size(480, 900));
      final page = tester.widget<SearchPage>(find.byType(SearchPage));
      await tester.tap(find.byTooltip('以图搜番'));
      await tester.pumpAndSettle();
      expect(find.byType(ImageSearchPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byIcon(Icons.arrow_back).first);
      await tester.pumpAndSettle();
      final returned = tester.widget<SearchPage>(find.byType(SearchPage));
      expect(returned.controller, same(page.controller));
      expect(returned.novelService, same(page.novelService));
      expect(tester.takeException(), isNull);
    },
  );
}
