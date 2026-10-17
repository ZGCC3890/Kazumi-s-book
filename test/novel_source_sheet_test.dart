import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_entry.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_rule.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';

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

Future<void> _open(WidgetTester tester, _Service service) async {
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
  await tester.pump(const Duration(milliseconds: 400));
  await tester.ensureVisible(find.text('书源状态'));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.text('书源状态'));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _chooseSource(WidgetTester tester) async {
  await tester.tap(find.text('选择书源阅读'));
  await tester.pumpAndSettle();
  final source = find.byWidgetPredicate((widget) => widget is ListTile &&
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('novel-source-'));
  await tester.ensureVisible(source.first);
  await tester.pump();
  await tester.tap(source.first);
  await tester.pumpAndSettle();
}

void main() {
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
    await _chooseSource(tester);
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
      expect(find.byTooltip('查看番剧详情'), findsNothing);
      expect(find.text('1 个书源正在搜索…'), findsOneWidget);
      await tester.tap(find.text('源甲小说'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('查看番剧详情'), findsOneWidget);
      await _chooseSource(tester);
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
      await _open(tester, service);
      service.sources['linovel']!.requests[0].$2.completeError(
        const NovelLoginRequired(),
      );
      service.sources['lightnovel']!.complete(0, '公开小说');
      await tester.pumpAndSettle();
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
      expect(find.text('重试结果'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
    },
  );
}
