import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_entry.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_rule.dart';
import 'package:kazumi/novel/novel_service.dart';
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
  @override
  Future<List<BangumiItem>> relatedAnime(NovelBook book,
      {String? editionId, bool refresh = false}) async => linkedAnime;
  @override
  List<NovelRule> get rules => sources.keys
      .map(
        (id) =>
            NovelRule.decode(File('novel_rules/$id.json').readAsStringSync()),
      )
      .toList();
  @override
  String? get preferredSource => null;
  @override
  Future<void> ensureDefaultRules() async {}
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
            onPressed: () => showDialog<String>(
              context: context,
              builder: (_) => Dialog(
                child: SizedBox(
                  width: 640,
                  height: 500,
                  child: NovelSearchPage(
                    service: service,
                    animeId: 42,
                    initialQuery: '原词',
                  ),
                ),
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
}

void main() {
  testWidgets(
    'public book URL transfers from fetching metadata to binding and opening',
    (tester) async {
      final service = _Service();
      await _open(tester, service);
      for (final source in service.sources.values)
        source.complete(0, '${source.source}结果');
      await tester.pumpAndSettle();
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
      expect(find.byTooltip('查看番剧详情'), findsOneWidget);
      expect(find.text('正在搜索…'), findsOneWidget);
      await tester.tap(find.text('源甲小说'));
      await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
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
