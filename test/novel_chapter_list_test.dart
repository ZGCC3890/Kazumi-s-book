import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_chapter_list.dart';
import 'package:kazumi/novel/novel_models.dart';

void main() {
  final chapters = List.generate(
    600,
    (index) => NovelChapter(
      url: '$index',
      title: '第$index章：长章节名称，目录按实际文字高度排列，无需估算行高',
      volume: '第${index ~/ 30}卷',
      kind: '正文',
    ),
  );
  for (final scale in [1.0, 2.0]) {
    for (final current in [0, 450, 599, -1]) {
      testWidgets(
        'catalog initially reveals current chapter $current at scale $scale',
        (tester) async {
          NovelChapter? selected;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: SizedBox(
                    width: 360,
                    height: 500,
                    child: NovelChapterList(
                      chapters: chapters,
                      current: current < 0
                          ? const NovelChapter(
                              url: 'other',
                              title: '旧源章节',
                              volume: '',
                              kind: '正文',
                            )
                          : chapters[current],
                      onSelected: (chapter) => selected = chapter,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final target = chapters[current < 0 ? 0 : current];
          final row = find.widgetWithText(ListTile, target.title);
          expect(row.hitTestable(), findsOneWidget);
          expect(tester.widget<ListTile>(row).selected, current >= 0);
          await tester.tap(row);
          expect(selected, same(target));
          if (current == 450) {
            await tester.drag(
              find.byType(CustomScrollView),
              const Offset(0, 330),
            );
            await tester.pumpAndSettle();
            expect(
              find.widgetWithText(ListTile, chapters[449].title),
              findsOneWidget,
            );
            await tester.drag(
              find.byType(CustomScrollView),
              const Offset(0, -600),
            );
            await tester.pumpAndSettle();
            expect(
              tester
                  .widgetList<ListTile>(find.byType(ListTile).hitTestable())
                  .any(
                    (tile) =>
                        chapters.indexWhere(
                          (chapter) =>
                              chapter.title == (tile.title as Text).data,
                        ) >
                        450,
                  ),
              isTrue,
            );
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
