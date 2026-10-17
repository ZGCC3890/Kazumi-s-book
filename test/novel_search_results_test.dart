import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/novel/novel_book_cover.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_rule.dart';
import 'package:kazumi/novel/novel_search_results.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/services/sync/webdav.dart';

NovelBook _book(String title, {String source = 'linovel', String url = '1', String author = ''}) =>
    NovelBook(sourceId: source, url: 'https://books/$url', title: title, author: author);

class _Service extends NovelService {
  _Service() : super(WebDav());
  int associations = 0;
  @override
  List<NovelRule> get rules => [for (final id in ['linovel', 'wenku8'])
    NovelRule.decode(File('novel_rules/$id.json').readAsStringSync())];
  @override
  Future<List<BangumiItem>> relatedAnime(NovelBook book, {String? editionId, bool refresh = false}) async {
    associations++;
    return [];
  }
}

void main() {
  test('work grouping merges exact titles and aliases without merging unrelated volumes', () {
    final first = _book('辉夜大小姐想让我告白小说版 ～秀知院学园的七大不可思议～');
    final alias = _book('辉夜姬想让人告白', source: 'wenku8');
    final bridge = _book('辉夜姬想让人告白(辉夜大小姐想让我告白)', url: '2');
    final groups = NovelSearchResult.group([first, alias, bridge, first,
      _book('辉夜魔王式! 第1卷'), _book('辉夜魔王式! 第2卷'),
      _book('超时空辉夜姬')]);
    expect(groups, hasLength(4));
    expect(groups.first.books, [first, alias, bridge]);
    expect(NovelSearchResult.group([]), isEmpty);
  });

  for (final size in [const Size(360, 800), const Size(1280, 800)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('cover grid and detail/source choice fit $size scale $scale', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = _Service();
        addTearDown(service.dispose);
        final first = _book('辉夜姬想让人告白', author: '羊山十一郎');
        final second = _book(first.title, source: 'wenku8', url: '2');
        final results = NovelSearchResult.group([first, second, _book('第二本书', url: '3')]);
        NovelBook? selected;
        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: Builder(builder: (context) => Scaffold(body: ListView(children: [
            NovelSearchGrid(service: service, results: results, onOpen: (result) async {
              selected = await Navigator.push<NovelBook>(context,
                MaterialPageRoute(builder: (_) => NovelSearchDetailPage(service: service, result: result)));
            }),
          ]))),
        ));
        expect(service.associations, 0);
        expect(find.byWidgetPredicate((widget) => widget is Semantics &&
          widget.properties.identifier == 'novel-search-result-0'), findsOneWidget);
        final covers = find.byType(NovelBookCover);
        expect(covers, findsNWidgets(2));
        expect(tester.getTopLeft(covers.first).dy, tester.getTopLeft(covers.last).dy);
        expect(tester.getTopLeft(find.text(first.title)).dy, greaterThan(tester.getBottomLeft(covers.first).dy));
        await tester.tap(find.text(first.title));
        await tester.pumpAndSettle();
        expect(find.text('小说详情'), findsOneWidget);
        expect(find.text('羊山十一郎'), findsOneWidget);
        expect(selected, isNull);
        expect(service.associations, 1);
        final choose = find.text('选择书源阅读');
        await tester.ensureVisible(choose);
        await tester.tap(choose);
        await tester.pumpAndSettle();
        expect(find.text('轻小说文库'), findsOneWidget);
        await tester.tap(find.text('收起书源'));
        await tester.pumpAndSettle();
        expect(find.text('轻小说文库'), findsNothing);
        await tester.tap(choose);
        await tester.pumpAndSettle();
        final source = find.byKey(const ValueKey('novel-source-wenku8-https://books/2'));
        await tester.ensureVisible(source);
        await tester.pump();
        expect(tester.getCenter(source).dy, lessThan(size.height));
        await tester.tap(source);
        await tester.pumpAndSettle();
        expect(selected, same(second));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('第二本书'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(selected, isNull);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('busy results cannot open detail', (tester) async {
    final service = _Service();
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [
      NovelSearchGrid(service: service, results: NovelSearchResult.group([_book('书名')]), onOpen: null),
    ]))));
    await tester.tap(find.text('书名'));
    await tester.pump();
    expect(service.associations, 0);
    expect(find.text('小说详情'), findsNothing);
  });
}
