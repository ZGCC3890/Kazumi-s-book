import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/novel/novel_shelf_action.dart';
import 'package:kazumi/novel/novel_sync_state.dart';
import 'package:kazumi/services/sync/webdav.dart';

class _Shelf extends NovelService {
  _Shelf() : super(WebDav());
  bool shelved = false;
  List<int> associations = [];
  final writes = <(String, int)>[];
  Completer<void>? pending;
  Object? error;
  @override bool isShelved(String editionId) => shelved;
  @override List<int> animeIdsForEdition(String editionId) => associations;
  @override Future<void> addToShelf(String editionId, {int animeId = 0}) async {
    writes.add((editionId, animeId));
    if (pending != null) await pending!.future;
    if (error != null) throw error!;
    shelved = true;
    notifyListeners();
  }
}

Future<void> _open(WidgetTester tester, _Shelf service, {int animeId = 0}) async {
  addTearDown(() async { await tester.pumpWidget(const SizedBox.shrink()); service.dispose(); });
  await tester.pumpWidget(MaterialApp(home: Scaffold(body:
    NovelShelfAction(service: service, editionId: 'book', animeId: animeId))));
}

void main() {
  for (final example in [(42, <int>[7], 42), (0, <int>[7], 7),
      (0, <int>[], 0), (0, <int>[7, 8], 0)]) {
    testWidgets('shelf action keeps the intended anime association $example', (tester) async {
      final service = _Shelf()..associations = example.$2;
      await _open(tester, service, animeId: example.$1);
      await tester.tap(find.byTooltip('加入书架'));
      await tester.pumpAndSettle();
      expect(service.writes, [('book', example.$3)]);
      expect(find.byTooltip('已在书架'), findsOneWidget);
      expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    });
  }

  testWidgets('already shelved books do not create a duplicate write', (tester) async {
    final service = _Shelf()..shelved = true;
    await _open(tester, service);
    await tester.tap(find.byTooltip('已在书架'));
    await tester.pumpAndSettle();
    expect(service.writes, isEmpty);
  });

  testWidgets('pending shelving disables repeat taps and failure can be retried', (tester) async {
    final service = _Shelf()..pending = Completer<void>()..error = StateError('shelf disk failure');
    await _open(tester, service);
    await tester.tap(find.byTooltip('加入书架'));
    await tester.pump();
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    await tester.tap(find.byTooltip('加入书架'));
    expect(service.writes, hasLength(1));
    service.pending!.complete();
    await tester.pumpAndSettle();
    expect(service.shelved, isFalse);
    expect(find.textContaining('shelf disk failure'), findsOneWidget);
    service.pending = null;
    service.error = null;
    await tester.tap(find.byTooltip('加入书架'));
    await tester.pumpAndSettle();
    expect(service.writes, hasLength(2));
    expect(service.shelved, isTrue);
    expect(find.byTooltip('已在书架'), findsOneWidget);
  });

  testWidgets('cancelling a shelf conflict keeps both versions and does not write', (tester) async {
    final service = _Shelf();
    service.state = NovelSyncState().edit('shelf/book', {'editionId': 'book'}, 'a')
        .merge(NovelSyncState().edit('shelf/book', null, 'b'));
    final before = service.state.encode();
    await _open(tester, service);
    await tester.tap(find.byTooltip('加入书架'));
    await tester.pumpAndSettle();
    expect(find.text('保留在书架'), findsOneWidget);
    expect(find.text('保留删除'), findsOneWidget);
    Navigator.of(tester.element(find.text('保留删除'))).pop();
    await tester.pumpAndSettle();
    expect(service.state.encode(), before);
    expect(service.writes, isEmpty);
    expect(find.byTooltip('加入书架'), findsOneWidget);
  });

  for (final fails in [false, true]) {
    testWidgets('leaving while shelving is pending does not update disposed UI: $fails', (tester) async {
      final service = _Shelf()..pending = Completer<void>();
      if (fails) service.error = StateError('late write failure');
      await _open(tester, service);
      await tester.tap(find.byTooltip('加入书架'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      service.pending!.complete();
      await tester.pumpAndSettle();
      expect(service.shelved, !fails);
      expect(tester.takeException(), isNull);
    });
  }
}
