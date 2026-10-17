import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:hive_ce/hive.dart';
import 'package:mobx/mobx.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/search/search_history_module.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_reader_page.dart';
import 'package:kazumi/novel/novel_rule.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/pages/search/search_controller.dart';
import 'package:kazumi/pages/search/search_page.dart';
import 'package:kazumi/repositories/collect_repository.dart';
import 'package:kazumi/repositories/search_history_repository.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Collect extends Fake implements ICollectRepository {}

class _History extends Fake implements ISearchHistoryRepository {}

class _Anime extends SearchPageController {
  _Anime() : super(_Collect(), _History());
  final queries = <String>[];
  Completer<void>? pending;
  Completer<void>? filterSave;
  final remembered = <String>[];
  @override
  Future<void> rememberSearch(String input) async {
    remembered.add(input);
    runInAction(() => searchHistories.insert(0, SearchHistory(input, 2)));
  }
  @override
  Future<void> setNotShowWatchedBangumis(bool value) async {
    if (filterSave != null) await filterSave!.future;
    runInAction(() => notShowWatchedBangumis = value);
  }

  @override
  Future<void> setNotShowAbandonedBangumis(bool value) async {
    runInAction(() => notShowAbandonedBangumis = value);
  }

  @override
  void loadSearchHistories() => runInAction(() {
    searchHistories = ObservableList.of([SearchHistory('番剧专属历史', 1)]);
  });
  @override
  Future<void> searchBangumi(String input, {String type = 'add'}) async {
    queries.add(input);
    runInAction(() {
      isLoading = true;
      bangumiList.clear();
    });
    if (pending != null) await pending!.future;
    runInAction(() {
      isLoading = false;
      isTimeOut = true;
      hasMoreSearchResults = false;
    });
  }
}

class _Source implements NovelSourceAdapter {
  final requests = <(String, Completer<List<NovelBook>>)>[];
  @override
  Future<List<NovelBook>> search(String query) {
    final result = Completer<List<NovelBook>>();
    requests.add((query, result));
    return result.future;
  }

  void finish(int request, String name) => requests[request].$2.complete([
    NovelBook(sourceId: 'linovel', url: 'https://test/$name', title: name),
  ]);
  @override
  Future<NovelBook> bookFromUrl(String url) => throw UnimplementedError();
  @override
  Future<List<NovelChapter>> catalog(NovelBook book) =>
      throw UnimplementedError();
  @override
  Future<List<NovelBlock>> content(NovelChapter chapter) =>
      throw UnimplementedError();
}

class _Novels extends NovelService {
  _Novels() : super(WebDav());
  final source = _Source();
  NovelBook? selected;
  NovelPosition? saved;
  @override
  List<NovelRule> get rules => [
    NovelRule.decode(File('novel_rules/linovel.json').readAsStringSync()),
  ];
  @override
  bool get needsDefaultRules => false;
  @override
  String? get preferredSource => 'linovel';
  @override
  NovelSourceAdapter adapter(String id) => source;
  @override
  Future<List<BangumiItem>> relatedAnime(
    NovelBook book, {
    String? editionId,
    bool refresh = false,
  }) async => [];
  @override
  Future<String> bind({
    required int animeId,
    required NovelBook book,
    required String editionLabel,
    required String language,
    String? existingEditionId,
    String? existingWorkId,
  }) async {
    selected = book;
    return 'edition';
  }

  @override
  String? editionForBook(NovelBook book) => null;
  @override
  NovelBook? selectedBook(String editionId) => selected;
  @override
  NovelJson get preferences => {
    'fontSize': 20.0,
    'lineHeight': 1.8,
    'theme': 0,
    'mode': 'scroll',
    'font': 'system',
    'margin': 24.0,
    'brightness': 0.0,
  };
  @override
  NovelPosition? position(String editionId) => saved;
  @override
  Future<List<NovelChapter>> catalog(
    NovelBook book, {
    bool refresh = false,
  }) async => [
    const NovelChapter(
      url: 'https://test/1',
      title: '第一章',
      volume: '第一卷',
      kind: '正文',
    ),
  ];
  @override
  Future<List<NovelBlock>> content(
    String source,
    NovelChapter chapter, {
    bool refresh = false,
  }) async => [const NovelBlock.text('小说正文，在主搜索页选择后直接阅读。')];
  @override
  Future<String> chapterReadIdentity(
    String editionId,
    NovelBook book,
    NovelChapter chapter,
    NovelPosition? restoredFrom,
  ) async => chapter.url;
  @override
  Future<void> savePosition(NovelPosition value) async {
    saved = value;
  }

  @override
  Future<int> recordReadChapters(
    String editionId,
    Set<String> chapters,
  ) async => 1;
  @override
  Future<void> retrySync() async {}
}

Future<void> _open(
  WidgetTester tester,
  _Anime anime,
  _Novels novels, {
  Size size = const Size(480, 900),
  double scale = 1,
  String inputTag = '',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    novels.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: SearchPage(
        controller: anime,
        novelService: novels,
        inputTag: inputTag,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _switch(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('搜索类型'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text(label).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _submit(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.tap(find.byTooltip('搜索'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  late Directory root;
  late PathProviderPlatform paths;
  setUpAll(() async {
    paths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('search-domains-');
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    expect(
      root.uri.pathSegments.where((part) => part.isNotEmpty).last,
      startsWith('search-domains-'),
    );
    await root.delete(recursive: true);
  });

  testWidgets(
    'left selector separates input, requests, results and anime-only tools',
    (tester) async {
      final anime = _Anime(), novels = _Novels();
      await _open(tester, anime, novels);
      expect(find.text('番剧专属历史'), findsOneWidget);
      expect(find.byTooltip('以图搜番'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byTooltip('搜索类型')).dx,
        lessThan(tester.getTopLeft(find.byType(TextField)).dx),
      );
      await _submit(tester, '番剧书名');
      await tester.pumpAndSettle();
      expect(anime.queries, ['番剧书名']);
      await _switch(tester, '小说');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      expect(find.text('番剧专属历史'), findsOneWidget);
      expect(find.byTooltip('以图搜番'), findsNothing);
      expect(find.byTooltip('小说规则'), findsOneWidget);
      const query = '小说 tag:冒险 sort:rank';
      await _submit(tester, query);
      expect(novels.source.requests.single.$1, query);
      expect(anime.remembered, [query]);
      expect(anime.queries, ['番剧书名']);
      novels.source.finish(0, '独立小说结果');
      await tester.pumpAndSettle();
      expect(find.text('独立小说结果'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      await _switch(tester, '番剧');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '番剧书名',
      );
      expect(find.text('独立小说结果'), findsNothing);
      expect(anime.queries, ['番剧书名']);
    },
  );

  testWidgets(
    'same novel query retries; late results and switching modes never open a reader',
    (tester) async {
      final anime = _Anime(), novels = _Novels();
      await _open(tester, anime, novels);
      await _switch(tester, '小说');
      await _submit(tester, '同词');
      await _submit(tester, '同词');
      expect(novels.source.requests.length, 2);
      novels.source.finish(1, '最新结果');
      await tester.pumpAndSettle();
      novels.source.finish(0, '旧请求结果');
      await tester.pumpAndSettle();
      expect(find.text('最新结果'), findsOneWidget);
      expect(find.text('旧请求结果'), findsNothing);
      await _submit(tester, '离开前的查询');
      await _switch(tester, '番剧');
      novels.source.finish(2, '离开后完成');
      await tester.pumpAndSettle();
      expect(find.text('离开后完成'), findsNothing);
      expect(find.byType(NovelReaderPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('history is visible in both modes and a history click uses the active domain', (tester) async {
    final anime = _Anime(), novels = _Novels();
    await _open(tester, anime, novels);
    await _switch(tester, '小说');
    await tester.tap(find.text('番剧专属历史'));
    await tester.pump();
    expect(novels.source.requests.single.$1, '番剧专属历史');
    expect(anime.queries, isEmpty);
    novels.source.finish(0, '历史小说');
    await tester.pumpAndSettle();
    await _submit(tester, '新小说历史');
    novels.source.finish(1, '新小说');
    await tester.pumpAndSettle();
    await _switch(tester, '番剧');
    expect(find.text('新小说历史'), findsOneWidget);
    await tester.tap(find.text('新小说历史'));
    await tester.pumpAndSettle();
    expect(anime.queries, ['新小说历史']);
  });

  testWidgets(
    'selecting a novel opens the reader and returning keeps the main search page',
    (tester) async {
      final anime = _Anime(), novels = _Novels();
      await _open(tester, anime, novels);
      await _switch(tester, '小说');
      await _submit(tester, '阅读');
      novels.source.finish(0, '直接阅读的小说');
      await tester.pumpAndSettle();
      await tester.tap(find.text('直接阅读的小说'));
      await tester.pumpAndSettle();
      expect(novels.selected, isNull);
      expect(find.text('小说详情'), findsOneWidget);
      await tester.tap(find.text('选择书源阅读'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('novel-source-linovel-https://test/直接阅读的小说')));
      await tester.pumpAndSettle();
      expect(find.byType(NovelReaderPage), findsOneWidget);
      await tester.tapAt(const Offset(240, 450));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(NovelReaderPage), findsNothing);
      expect(find.byType(SearchPage), findsOneWidget);
      expect(find.text('直接阅读的小说'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(360, 800),
    const Size(1280, 800),
    const Size(800, 360),
  ]) {
    testWidgets(
      'mode selector and one input fit double scale and keyboard $size',
      (tester) async {
        await _open(tester, _Anime(), _Novels(), size: size, scale: 2);
        await _switch(tester, '小说');
        tester.view.viewInsets = const FakeViewPadding(bottom: 250);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        expect(find.byType(SearchBar), findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final returnToAnime in [false, true]) {
    testWidgets(
      'saving filters stays in its original domain, switch back=$returnToAnime',
      (tester) async {
        final anime = _Anime()..filterSave = Completer<void>();
        final novels = _Novels();
        await _open(tester, anime, novels);
        await tester.tap(find.text('按条件查找'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('查看结果'));
        await tester.pumpAndSettle();
        await _switch(tester, '小说');
        if (returnToAnime) await _switch(tester, '番剧');
        await tester.enterText(find.byType(TextField), '新输入');
        anime.filterSave!.complete();
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '新输入',
        );
        expect(anime.queries, isEmpty);
        expect(novels.source.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final sourceError in [false, true]) {
    testWidgets(
      'short landscape keyboard can show novel loading and result/error=$sourceError',
      (tester) async {
        final novels = _Novels();
        await _open(
          tester,
          _Anime(),
          novels,
          size: const Size(800, 360),
          scale: 2,
        );
        await _switch(tester, '小说');
        tester.view.viewInsets = const FakeViewPadding(bottom: 250);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '横屏查询');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(novels.source.requests.single.$1, '横屏查询');
        expect(tester.takeException(), isNull);
        if (sourceError) {
          novels.source.requests.single.$2.completeError(StateError('横屏源错误'));
        } else {
          novels.source.finish(0, '横屏结果');
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'tag route remains an anime search and never starts a novel request',
    (tester) async {
      final anime = _Anime(), novels = _Novels();
      final encoded = Uri.encodeComponent('奇幻');
      final routes = RouteCollection()
        ..add(ModularRoute('/search/:tag', (_, _) => const SizedBox.shrink()));
      final tag = routes
          .match(Uri.parse('/search/$encoded'))!
          .last
          .params['tag']!;
      expect(tag, encoded);
      await _open(tester, anime, novels, inputTag: tag);
      expect(anime.queries.single, contains('奇幻'));
      expect(find.text('番剧搜索'), findsOneWidget);
      expect(novels.source.requests, isEmpty);
    },
  );
}
