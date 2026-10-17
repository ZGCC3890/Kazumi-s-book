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
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/pages/menu/menu.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/pages/popular/popular_page.dart';
import 'package:kazumi/pages/search/image_search_page.dart';
import 'package:kazumi/pages/search/search_module.dart';
import 'package:kazumi/pages/search/search_page.dart';
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
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  final module = createModule(
    register: (c) {
      c.addSingleton<ICollectRepository>(CollectRepository.new);
      c.addSingleton<ISearchHistoryRepository>(SearchHistoryRepository.new);
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
      expect(tester.widget<SearchPage>(find.byType(SearchPage)), same(page));
      expect(tester.takeException(), isNull);
    },
  );
}
