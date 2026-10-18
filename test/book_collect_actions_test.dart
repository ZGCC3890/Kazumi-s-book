import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/pages/collect/collect_library_view.dart';

void main() {
  for (final scenario in [
    (360.0, CollectLayout.cards, 1.0),
    (360.0, CollectLayout.cards, 2.0),
    (360.0, CollectLayout.list, 2.0),
    (600.0, CollectLayout.cards, 1.0),
    (800.0, CollectLayout.cards, 1.0),
    (1080.0, CollectLayout.cards, 1.0),
    (1280.0, CollectLayout.cards, 1.0),
    (1440.0, CollectLayout.cards, 1.0),
    (1440.0, CollectLayout.cards, 1.3),
    (1440.0, CollectLayout.cards, 2.0),
    (1440.0, CollectLayout.list, 1.0),
  ]) {
    testWidgets('collection quick actions ${scenario.$1} ${scenario.$2.name} scale ${scenario.$3}', (tester) async {
      tester.view.physicalSize = Size(scenario.$1, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final anime = BangumiItem(id: 42, type: 2, name: 'test', nameCn: '测试番剧',
        summary: '', airDate: '2026-01-01', airWeekday: 1, rank: 0,
        images: {}, tags: [], alias: [], ratingScore: 7, votes: 1, votesCount: [], info: '');
      final opened = <int>[], played = <int>[], read = <int>[];
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scenario.$3)),
          child: child!,
        ),
        home: Scaffold(body: CollectLibraryView(
          entries: [CollectedBangumi(anime, DateTime(2026), 1)],
          showRating: true, onOpen: (item) => opened.add(item.id),
          onPlay: (item) => played.add(item.id), onRead: (item) => read.add(item.id),
          onChangeType: (_, _) {}, canEdit: (_) => true,
          layout: scenario.$2, onLayoutChanged: (_) {},
        )),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final play = find.byTooltip('播放《测试番剧》');
      final book = find.byTooltip('阅读《测试番剧》的轻小说');
      await tester.ensureVisible(play);
      await tester.tap(play);
      await tester.pump();
      await tester.ensureVisible(book);
      if (scenario.$2 == CollectLayout.cards) {
        final card = find.byKey(const ValueKey('collect-42'));
        expect(tester.getRect(book).bottom, lessThanOrEqualTo(tester.getRect(card).bottom));
        expect(tester.getRect(book).right, lessThanOrEqualTo(tester.getRect(card).right));
        expect(book.hitTestable(), findsOneWidget);
      }
      await tester.tap(book);
      await tester.pump();
      expect(played, [42]);
      expect(read, [42]);
      expect(opened, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
