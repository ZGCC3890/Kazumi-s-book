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
  for (final size in [const Size(360, 800), const Size(1280, 800)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('source cards read directly and query anime only on click at $size scale $scale', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final service = _Service();
        addTearDown(service.dispose);
        final first = _book('辉夜姬想让人告白', author: '羊山十一郎');
        final second = _book(first.title, source: 'wenku8', url: '2');
        final books = [first, second, _book('第二本书', url: '3')];
        NovelBook? selected;
        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: Scaffold(body: ListView(children: [
            NovelSearchGrid(service: service, books: books, onRead: (book) => selected = book),
          ])),
        ));
        expect(service.associations, 0);
        expect(find.byWidgetPredicate((widget) => widget is Semantics &&
          widget.properties.identifier == 'novel-search-result-0'), findsOneWidget);
        final covers = find.byType(NovelBookCover);
        expect(covers, findsNWidgets(3));
        expect(tester.getTopLeft(covers.first).dy, tester.getTopLeft(covers.at(1)).dy);
        expect(find.text(first.title), findsNWidgets(2));
        expect(find.text('轻小说文库'), findsOneWidget);
        await tester.tap(covers.first);
        await tester.pumpAndSettle();
        expect(selected, same(first));
        expect(service.associations, 0);
        expect(find.text('小说详情'), findsNothing);
        final read = find.descendant(
          of: find.byKey(const ValueKey('novel-result-wenku8-https://books/2')),
          matching: find.text('阅读'));
        await tester.ensureVisible(read);
        await tester.tap(read);
        await tester.pumpAndSettle();
        expect(selected, same(second));
        expect(service.associations, 0);
        final watch = find.text('看番').first;
        await tester.ensureVisible(watch);
        await tester.tap(watch);
        await tester.pumpAndSettle();
        expect(service.associations, 1);
        expect(selected, same(second));
        expect(find.textContaining('没有找到关联番剧'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('busy results cannot start reading', (tester) async {
    final service = _Service();
    addTearDown(service.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [
      NovelSearchGrid(service: service, books: [_book('书名')], onRead: null),
    ]))));
    await tester.tap(find.text('书名'));
    await tester.tap(find.text('阅读'));
    await tester.pump();
    expect(service.associations, 0);
    expect(find.text('小说详情'), findsNothing);
  });
}
