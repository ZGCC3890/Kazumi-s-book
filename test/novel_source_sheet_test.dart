import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_entry.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_reader_page.dart';
import 'package:kazumi/novel/novel_rule.dart';
import 'package:kazumi/novel/novel_search_results.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/novel/novel_ai.dart';
import 'package:kazumi/novel/novel_accounts.dart';
import 'package:dio/dio.dart';

class _Adapter implements NovelSourceAdapter {
  _Adapter(this.source);
  final String source;
  final requests = <(String, Completer<List<NovelBook>>)>[];
  @override
  Future<List<NovelBook>> search(String query) {
    final result = Completer<List<NovelBook>>();
    requests.add((query, result));
    return result.future;
  }

  void complete(int i, String title) => requests[i].$2.complete([
    NovelBook(
      sourceId: source,
      url: 'https://test/$source/$title',
      title: title,
    ),
  ]);
  @override
  Future<NovelBook> bookFromUrl(String url) async =>
      NovelBook(sourceId: source, url: url, title: '链接小说');
  @override
  Future<List<NovelChapter>> catalog(NovelBook book) =>
      throw UnimplementedError();
  @override
  Future<List<NovelBlock>> content(NovelChapter chapter) =>
      throw UnimplementedError();
}

class _Service extends NovelService {
  _Service() : super(WebDav());
  @override String accountName(String sourceId) => '';
  @override Future<NovelAccount?> accountCredentials(String sourceId) async => null;
  bool aiEnabled = false;
  final aiRequests = <(String, bool)>[];
  @override NovelAiSettings get aiSettings => NovelAiSettings(enabled: aiEnabled, token: 'test-token');
  @override Future<List<String>> suggestTitles(String title, {required bool toAnime,
    bool sameNovel = false, NovelAiSettings? settings, CancelToken? cancelToken}) async {
    aiRequests.add((title, sameNovel));
    return ['AI 小说译名'];
  }
  final sources = {
    'linovel': _Adapter('linovel'),
    'lightnovel': _Adapter('lightnovel'),
  };
  NovelBook? selected;
  String? knownEdition, boundEdition;
  final loginResult = Completer<void>();
  List<BangumiItem> linkedAnime = [];
  bool pendingDefaults = false;
  Object? defaultError;
  int defaultRequests = 0;
  void Function()? installDefaults;
  Completer<void>? defaultInstallGate;
  final ruleOverrides = <String, NovelRule>{};
  @override
  Future<List<BangumiItem>> relatedAnime(NovelBook book,
      {String? editionId, bool refresh = false}) async => linkedAnime;
  @override
  List<NovelRule> get rules => sources.keys
      .map(
        (id) =>
            ruleOverrides[id] ?? NovelRule.decode(File('novel_rules/$id.json').readAsStringSync()),
      )
      .toList();
  @override
  String? get preferredSource => null;
  @override
  bool get needsDefaultRules => pendingDefaults;
  @override
  Future<void> ensureDefaultRules() async {
    defaultRequests++;
    if (defaultError != null) throw defaultError!;
    if (defaultInstallGate != null) await defaultInstallGate!.future;
    installDefaults?.call();
    pendingDefaults = false;
  }
  @override
  NovelSourceAdapter adapter(String id) => sources[id]!;
  @override
  String? editionForBook(NovelBook book) => knownEdition;
  @override
  Future<void> login(String source, String username, String password) =>
      loginResult.future;
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
    boundEdition = existingEditionId;
    return 'selected-edition';
  }
}

class _ReadingService extends _Service {
  _ReadingService() {
    selected = const NovelBook(sourceId: 'linovel', url: 'https://test/original', title: '当前小说');
  }
  NovelPosition? saved;
  @override NovelBook? selectedBook(String editionId) => selected;
  @override NovelPosition? position(String editionId) => saved;
  @override NovelJson get preferences => {'fontSize': 20.0, 'lineHeight': 1.8,
    'theme': 0, 'mode': 'scroll', 'font': 'system', 'margin': 24.0, 'brightness': 0.0};
  @override Future<void> savePosition(NovelPosition position) async { saved = position; }
  @override Future<List<NovelChapter>> catalog(NovelBook book, {bool refresh = false}) async => [
    NovelChapter(url: 'https://test/${book.sourceId}/chapter', title: '第一章', volume: '第一卷', kind: '正文', number: 1),
  ];
  @override Future<List<NovelBlock>> content(String sourceId, NovelChapter chapter,
      {bool refresh = false}) async => [NovelBlock.text('跨源阅读保留当前正文。' * 100)];
  @override Future<String> chapterReadIdentity(String editionId, NovelBook book,
      NovelChapter chapter, NovelPosition? restoredFrom) async => chapter.url;
  @override Future<int> recordReadChapters(String editionId, Set<String> chapters) async => 1;
}

Future<void> _open(WidgetTester tester, _Service service, {String? editionId}) async {
  addTearDown(service.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showAdaptiveBottomSheet<String>(
              context: context,
              maxHeightFactor: .88,
              builder: (_) => NovelSearchPage(
                    service: service,
                    animeId: 42,
                    initialQuery: '原词',
                    existingEditionId: editionId,
              ),
            ),
            child: const Text('选择小说'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('选择小说'));
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _scrollTo(WidgetTester tester, Finder target, {double delta = 250}) async {
  await tester.scrollUntilVisible(target, delta,
    scrollable: find.descendant(of: find.byType(NovelSearchPage),
      matching: find.byWidgetPredicate((widget) => widget is Scrollable &&
          widget.axisDirection == AxisDirection.down)).first);
  await tester.pump();
}

Future<void> _openStatus(WidgetTester tester) async {
  await _scrollTo(tester, find.text('书源状态'));
  await tester.tap(find.text('书源状态'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('production reader source picker cancels then changes source without stacking readers', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    final service = _ReadingService()..aiEnabled = true;
    addTearDown(() async { await tester.pumpWidget(const SizedBox.shrink()); service.dispose(); });
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => NovelEntry.read(context, service, 'selected-edition'),
        child: const Text('打开阅读器'))))));
    await tester.tap(find.text('打开阅读器'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(4, 300));
    await tester.pumpAndSettle();
    final readerState = tester.state(find.byType(NovelReaderPage));
    final original = service.saved!.toJson();
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.tap(find.byTooltip('更换书源'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(NovelSearchPage), findsOneWidget);
      for (final source in service.sources.values) {
        expect(source.requests[attempt].$1, '当前小说');
        source.complete(attempt, '目标小说');
      }
      await tester.pumpAndSettle();
      if (attempt == 0) {
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(service.saved!.toJson(), original);
        expect(service.selected!.sourceId, 'linovel');
      } else {
        await tester.tap(find.byTooltip('AI 搜索'));
        await tester.pumpAndSettle();
        expect(service.aiRequests.single, ('当前小说', true));
        expect(find.text('AI 搜索书名'), findsOneWidget);
        await tester.tap(find.text('AI 小说译名'));
        await tester.pump();
        for (final source in service.sources.values) {
          expect(source.requests.last.$1, 'AI 小说译名');
          source.complete(2, '目标小说');
        }
        await tester.pumpAndSettle();
        expect(service.selected!.sourceId, 'linovel');
        expect(service.saved!.toJson(), original);
        final card = find.byKey(const ValueKey('novel-result-lightnovel-https://test/lightnovel/目标小说'));
        final read = find.descendant(of: card, matching: find.text('阅读'));
        await _scrollTo(tester, read);
        await tester.tap(read);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 700));
        expect(service.boundEdition, 'selected-edition');
        expect(service.selected!.sourceId, 'lightnovel');
        expect(service.saved!.editionId, 'selected-edition');
        expect(service.saved!.sourceId, 'lightnovel');
        expect(service.saved!.quote, original['quote']);
      }
      expect(find.byType(NovelSearchPage), findsNothing);
      expect(tester.state(find.byType(NovelReaderPage)), same(readerState));
    }
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NovelReaderPage), findsNothing);
    expect(find.text('打开阅读器'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final cancel in [false, true]) {
    testWidgets('anime entry resolves AI name before querying sources (cancel: $cancel)', (tester) async {
      final service = _Service()..aiEnabled = true;
      addTearDown(service.dispose);
      final anime = BangumiItem.fromJson({'id': 42, 'name': '原番剧名', 'name_cn': '原番剧名',
        'rating': {'rank': 1, 'score': 8, 'total': 1}, 'images': <String, String>{}});
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
        body: TextButton(onPressed: () => NovelEntry.open(context, anime, service),
          child: const Text('阅读小说'))))));
      await tester.tap(find.text('阅读小说'));
      await tester.pumpAndSettle();
      expect(service.sources.values.every((source) => source.requests.isEmpty), true);
      await tester.tap(find.text(cancel ? '取消' : 'AI 小说译名'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      if (cancel) {
        expect(find.byType(NovelSearchPage), findsNothing);
      } else {
        for (final source in service.sources.values) {
          expect(source.requests.single.$1, 'AI 小说译名');
          source.complete(0, '搜索到的小说');
        }
        await tester.pumpAndSettle();
        expect(find.text('搜索到的小说'), findsNWidgets(2));
      }
    });
  }
  testWidgets('explicit AI action searches the selected candidate and cancelling keeps results', (tester) async {
    final service = _Service()..aiEnabled = true;
    await _open(tester, service);
    for (final source in service.sources.values) { source.complete(0, '原作品'); }
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('AI 搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.sources['linovel']!.requests.length, 1);
    await tester.tap(find.byTooltip('AI 搜索'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 小说译名'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    for (final source in service.sources.values) {
      expect(source.requests.last.$1, 'AI 小说译名');
      source.complete(1, '关联作品');
    }
    await tester.pumpAndSettle();
    expect(find.text('关联作品'), findsNWidgets(2));
  });
  for (final width in [360.0, 1280.0]) {
    testWidgets('source AI and ordinary search share the book field at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _Service()..aiEnabled = true;
      await _open(tester, service, editionId: 'current-edition');
      for (final source in service.sources.values) { source.complete(0, '原作品'); }
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      final ai = find.byTooltip('AI 搜索');
      final search = find.byTooltip('搜索');
      expect(find.descendant(of: field, matching: ai), findsOneWidget);
      expect(find.descendant(of: field, matching: search), findsOneWidget);
      expect(tester.getCenter(ai).dy, tester.getCenter(search).dy);
      expect(tester.getCenter(ai).dx, greaterThan(tester.getCenter(search).dx));
      await tester.enterText(field, '当前小说 第三卷');
      await tester.tap(ai);
      await tester.pumpAndSettle();
      expect(service.aiRequests.single, ('当前小说 第三卷', true));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, '当前小说 第三卷');
      expect(find.text('原作品'), findsNWidgets(2));
      await tester.tap(search);
      await tester.pump();
      for (final source in service.sources.values) {
        expect(source.requests.last.$1, '当前小说 第三卷');
        source.complete(1, '普通搜索结果');
      }
      await tester.pumpAndSettle();
      expect(service.aiRequests.length, 1);
      expect(service.selected, isNull);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('same-ID default upgrade re-searches the changed source and ignores its old response', (tester) async {
    final service = _Service()..pendingDefaults = true..defaultInstallGate = Completer<void>();
    final oldAdapter = service.sources['linovel']!;
    service.installDefaults = () {
      final previous = service.rules.firstWhere((rule) => rule.id == 'linovel');
      service.ruleOverrides['linovel'] = NovelRule.decode(jsonEncode({...previous.json, 'name': '更新后的书源'}));
      service.sources['linovel'] = _Adapter('linovel');
    };
    await _open(tester, service);
    expect(oldAdapter.requests.length, 1);
    service.defaultInstallGate!.complete();
    await tester.pump();
    final updatedAdapter = service.sources['linovel']!;
    expect(updatedAdapter.requests.single.$1, '原词');
    updatedAdapter.complete(0, '新规则小说');
    await tester.pump();
    oldAdapter.complete(0, '过时旧规则小说');
    service.sources['lightnovel']!.complete(0, '未更改的源');
    await tester.pumpAndSettle();
    expect(find.text('新规则小说'), findsOneWidget);
    expect(find.text('过时旧规则小说'), findsNothing);
    expect(service.sources['lightnovel']!.requests.length, 1);
  });

  testWidgets('late source results preserve visible cards and each source opens directly', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _Service();
    service.sources
      ..clear()
      ..addAll({'lightnovel': _Adapter('lightnovel'), 'wenku8': _Adapter('wenku8')});
    await _open(tester, service);
    const wenku = NovelBook(sourceId: 'wenku8', url: 'https://test/wenku/1',
      title: '辉夜姬想让人告白(辉夜大小姐想让我告白)');
    service.sources['wenku8']!.requests.single.$2.complete([
      wenku, const NovelBook(sourceId: 'wenku8', url: 'https://test/wenku/2', title: '文库独有作品'),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<NovelSearchGrid>(find.byType(NovelSearchGrid)).books.first, same(wenku));
    service.sources['lightnovel']!.requests.single.$2.complete([
      const NovelBook(sourceId: 'lightnovel', url: 'https://test/light/1',
        title: '辉夜大小姐想让我告白小说版 ～秀知院学园的七大不可思议～'),
      const NovelBook(sourceId: 'lightnovel', url: 'https://test/light/2', title: '超时空辉夜姬'),
    ]);
    await tester.pumpAndSettle();
    final results = tester.widget<NovelSearchGrid>(find.byType(NovelSearchGrid)).books;
    expect(results.map((book) => book.title), [wenku.title, '文库独有作品',
      '辉夜大小姐想让我告白小说版 ～秀知院学园的七大不可思议～', '超时空辉夜姬']);
    expect(results.map((book) => book.sourceId), ['wenku8', 'wenku8', 'lightnovel', 'lightnovel']);
    await tester.tap(find.text(wenku.title));
    await tester.pumpAndSettle();
    expect(service.selected, same(wenku));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cover grid shows all results and resets for a new search', (tester) async {
    final service = _Service();
    await _open(tester, service);
    service.sources['linovel']!.requests[0].$2.complete([
      for (var i = 0; i < 4; i++) NovelBook(sourceId: 'linovel', url: 'https://test/$i', title: '甲源第$i本'),
    ]);
    service.sources['lightnovel']!.complete(0, '乙源小说');
    await tester.pumpAndSettle();
    expect(find.text('甲源第0本'), findsOneWidget);
    expect(find.text('甲源第1本'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '新书名');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    service.sources['linovel']!.requests[1].$2.complete([
      for (var i = 0; i < 3; i++) NovelBook(sourceId: 'linovel', url: 'https://test/new$i', title: '新第$i本'),
    ]);
    service.sources['lightnovel']!.complete(1, '乙源新小说');
    await tester.pumpAndSettle();
    expect(find.text('新第0本'), findsOneWidget);
    expect(find.text('新第1本'), findsOneWidget);
    expect(find.text('甲源第0本'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('default upgrade failure does not block installed sources and retry searches only added sources', (tester) async {
    final service = _Service()..pendingDefaults = true..defaultError = StateError('默认规则下载失败');
    await _open(tester, service);
    expect(service.sources['linovel']!.requests.length, 1);
    expect(service.defaultRequests, 1);
    service.sources['linovel']!.complete(0, '仍可阅读的小说');
    service.sources['lightnovel']!.complete(0, '另一个源');
    await tester.pumpAndSettle();
    expect(find.textContaining('已安装书源可继续使用'), findsOneWidget);
    service.defaultError = null;
    service.installDefaults = () => service.sources['wenku8'] = _Adapter('wenku8');
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(service.sources['wenku8']!.requests.single.$1, '原词');
    expect(service.sources['linovel']!.requests.length, 1);
    service.sources['wenku8']!.complete(0, '新安装源的小说');
    await tester.pumpAndSettle();
    expect(find.textContaining('已安装书源可继续使用'), findsNothing);
    await tester.tap(find.text('仍可阅读的小说'));
    await tester.pumpAndSettle();
    expect(service.selected?.title, '仍可阅读的小说');
  });

  testWidgets('first installation failure offers retry without a manual catalog form', (tester) async {
    final service = _Service()..pendingDefaults = true..defaultError = StateError('首次下载失败');
    service.sources.clear();
    await _open(tester, service);
    expect(find.text('重试获取书源'), findsOneWidget);
    expect(find.byTooltip('管理小说规则'), findsOneWidget);
    service.defaultError = null;
    service.installDefaults = () => service.sources['linovel'] = _Adapter('linovel');
    await tester.tap(find.text('重试获取书源'));
    await tester.pump();
    service.sources['linovel']!.complete(0, '重试后可读');
    await tester.pumpAndSettle();
    expect(find.text('重试后可读'), findsOneWidget);
  });

  testWidgets(
    'public book URL transfers from fetching metadata to binding and opening',
    (tester) async {
      final service = _Service();
      await _open(tester, service);
      for (final source in service.sources.values)
        source.complete(0, '${source.source}结果');
      await tester.pumpAndSettle();
      await _openStatus(tester);
      await tester.ensureVisible(find.byType(PopupMenuButton<String>).first);
      await tester.pump();
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开书籍链接'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'https://www.linovel.net/book/42.html',
      );
      await tester.tap(find.text('读取详情'));
      await tester.pumpAndSettle();
      expect(service.selected?.url, 'https://www.linovel.net/book/42.html');
      expect(find.byType(NovelSearchPage), findsNothing);
    },
  );
  testWidgets(
    'each source finishes independently and a selected result opens without version forms',
    (tester) async {
      final service = _Service();
      service.knownEdition = 'already-reading';
      service.linkedAnime = [BangumiItem.fromJson({
        'id': 42, 'type': 2, 'name': '源甲小说', 'name_cn': '源甲小说',
        'rating': {'rank': 1, 'score': 8.0, 'total': 1},
        'images': <String, String>{},
      })];
      await _open(tester, service);
      service.sources['linovel']!.complete(0, '源甲小说');
      await tester.pump();
      expect(find.text('源甲小说'), findsOneWidget);
      await tester.pump();
      expect(find.text('看番'), findsOneWidget);
      await _scrollTo(tester, find.text('1 个书源正在搜索…'));
      expect(find.text('1 个书源正在搜索…'), findsOneWidget);
      await _scrollTo(tester, find.text('源甲小说'), delta: -250);
      await tester.tap(find.text('源甲小说'));
      await tester.pumpAndSettle();
      expect(find.byType(NovelSearchPage), findsNothing);
      expect(service.selected!.sourceId, 'linovel');
      expect(service.boundEdition, 'already-reading');
      expect(find.text('确认对应小说和版本'), findsNothing);
      service.sources['lightnovel']!.complete(0, '已关闭弹窗的结果');
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'closing the source dialog during URL dialog exit does not bind a book',
    (tester) async {
      final service = _Service();
      await _open(tester, service);
      for (final source in service.sources.values) {
        source.complete(0, '${source.source}结果');
      }
      await tester.pumpAndSettle();
      await _openStatus(tester);
      await tester.ensureVisible(find.byType(PopupMenuButton<String>).first);
      await tester.pump();
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开书籍链接'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'https://www.linovel.net/book/42.html',
      );
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      await tester.tap(find.text('读取详情'));
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byType(NovelSearchPage), findsNothing);
      expect(service.selected, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'system back during login can finish without touching a closed dialog',
    (tester) async {
      final service = _Service();
      final rule = jsonDecode(File('novel_rules/linovel.json').readAsStringSync()) as Map<String, dynamic>;
      rule['login'] = jsonDecode(File('novel_rules/wenku8.json').readAsStringSync())['login'];
      service.ruleOverrides['linovel'] = NovelRule.decode(jsonEncode(rule));
      await _open(tester, service);
      service.sources['linovel']!.requests[0].$2.completeError(
        const NovelLoginRequired(),
      );
      service.sources['lightnovel']!.complete(0, '公开小说');
      await tester.pumpAndSettle();
      await _openStatus(tester);
      await tester.ensureVisible(find.text('首次登录'));
      await tester.pump();
      await tester.tap(find.text('首次登录'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), 'reader');
      await tester.enterText(
        find.byType(TextField).last,
        'temporary-test-password',
      );
      await tester.tap(find.text('登录并搜索'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      // Finish the login while the popped dialog is still animating and mounted.
      await tester.pump();
      service.loginResult.complete();
      await tester.pumpAndSettle();
      expect(find.text('登录并搜索'), findsNothing);
      expect(service.sources['linovel']!.requests, hasLength(1));
      await _scrollTo(tester, find.text('公开小说'), delta: -250);
      expect(find.text('公开小说'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'new query ignores stale results; single-source retry uses submitted query',
    (tester) async {
      final service = _Service();
      await _open(tester, service);
      await tester.enterText(find.byType(TextField), '新词');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pump();
      for (final source in service.sources.values) {
        source.complete(0, '过期结果');
        source.complete(1, '${source.source}新结果');
      }
      await tester.pumpAndSettle();
      expect(find.text('过期结果'), findsNothing);
      expect(find.text('linovel新结果'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '未提交的词');
      await _openStatus(tester);
      await tester.ensureVisible(find.byType(PopupMenuButton<String>).first);
      await tester.pump();
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新搜索'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(service.sources['linovel']!.requests.last.$1, '新词');
      service.sources['linovel']!.complete(2, '重试结果');
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('重试结果'), delta: -250);
      expect(find.text('重试结果'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
    },
  );
}
