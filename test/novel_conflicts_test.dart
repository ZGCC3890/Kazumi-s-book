import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_conflicts.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_reader_store.dart';
import 'package:kazumi/novel/novel_sync_state.dart';

const _key = 'position/book-a';
NovelSyncState _revision(String device, String title, {String key = _key}) =>
    NovelSyncState().edit(key, {'title': title}, device);

class _Store extends ChangeNotifier implements NovelReaderStore {
  _Store(this.current);
  NovelSyncState current;
  Completer<void>? gate;
  int writes = 0;
  @override NovelSyncState get state => current;
  @override Future<void> resolve(String key, NovelRevision selected,
      {required String expectedToken}) async {
    await gate?.future;
    current = current.resolve(key, selected, 'ui', expectedToken: expectedToken);
    writes++;
    notifyListeners();
  }
  @override NovelJson get preferences => {};
  @override String? get syncError => null;
  @override NovelPosition? position(String editionId) => null;
  @override Future<String> chapterReadIdentity(String editionId, NovelBook book,
      NovelChapter chapter, NovelPosition? restoredFrom) async => chapter.url;
  @override String chapterMappingKey(NovelPosition from, NovelBook target) => 'unused';
  @override List<String> chapterMappingWriteKeys(NovelPosition from, NovelBook target,
      NovelChapter chapter) => [];
  @override NovelChapter? mappedChapter(NovelPosition from, NovelBook target) => null;
  @override Future<void> confirmChapterMapping(NovelPosition from, NovelBook target,
      NovelChapter chapter) async => throw UnimplementedError();
  @override Future<List<NovelChapter>> catalog(NovelBook book, {bool refresh = false}) async => [];
  @override Future<List<NovelBlock>> content(String sourceId, NovelChapter chapter,
      {bool refresh = false}) async => [];
  @override Future<Uint8List> image(String sourceId, String url) async => throw UnimplementedError();
  @override Future<void> savePosition(NovelPosition position) async => throw UnimplementedError();
  @override Future<void> savePreferences(NovelJson value) async => throw UnimplementedError();
  @override Future<void> addBookmark(NovelPosition position, String note) async => throw UnimplementedError();
  @override Future<void> deleteBookmark(String id) async => throw UnimplementedError();
  @override List<NovelJson> bookmarks(String editionId) => [];
  @override Future<void> syncAutomatically() async {}
}

Future<void> _open(WidgetTester tester, _Store store,
    {String key = _key, void Function(bool)? completed}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
    builder: (context) => TextButton(
      onPressed: () async {
        final result = await NovelConflicts.ensure(context, store, () => [key]);
        completed?.call(result);
      },
      child: const Text('打开'),
    ),
  ))));
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cancel leaves all candidates untouched and stops the action', (tester) async {
    final store = _Store(_revision('a', 'A').merge(_revision('b', 'B')));
    final before = store.state.encode();
    bool? result;
    await _open(tester, store, completed: (value) => result = value);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(store.writes, 0);
    expect(store.state.encode(), before);
  });

  testWidgets('a third candidate arriving before queued commit rejects the displayed choice', (tester) async {
    final store = _Store(_revision('a', 'A').merge(_revision('b', 'B')))
      ..gate = Completer<void>();
    bool? result;
    await _open(tester, store, completed: (value) => result = value);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    store.current = store.state.merge(_revision('c', 'C'));
    store.gate!.complete();
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(store.writes, 0);
    expect(store.state.revisions(_key), hasLength(3));
    expect(find.text('Bad state: 冲突已发生变化，请重新选择'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unchanged selection resolves only its own record', (tester) async {
    final other = _revision('x', 'X', key: 'position/book-b')
        .merge(_revision('y', 'Y', key: 'position/book-b'));
    final store = _Store(_revision('a', 'A').merge(_revision('b', 'B')).merge(other));
    bool? result;
    await _open(tester, store, completed: (value) => result = value);
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(store.writes, 1);
    expect(store.state.value(_key)!['title'], 'B');
    expect(store.state.revisions('position/book-b'), hasLength(2));
  });

  testWidgets('unrelated conflicts never open a choice for a different operation', (tester) async {
    final store = _Store(_revision('a', 'A').merge(_revision('b', 'B')));
    bool? result;
    await _open(tester, store, key: 'position/book-b', completed: (value) => result = value);
    expect(result, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(store.writes, 0);
  });

  testWidgets('cancelling the second dependency leaves it and other books unresolved', (tester) async {
    final second = _revision('x', 'X', key: 'selected/book-a')
        .merge(_revision('y', 'Y', key: 'selected/book-a'));
    final store = _Store(_revision('a', 'A').merge(_revision('b', 'B')).merge(second));
    bool? result;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => TextButton(onPressed: () async {
        result = await NovelConflicts.ensure(context, store,
            () => [_key, 'selected/book-a']);
      }, child: const Text('继续')),
    ))));
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(find.text('选择要保留的当前书源'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(store.writes, 1);
    expect(store.state.revisions('selected/book-a'), hasLength(2));
    expect(store.state.value(_key)!['title'], 'A');
  });

  testWidgets('closing the owner before choosing cannot commit or pop another page', (tester) async {
    final store = _Store(_revision('a', 'A').merge(_revision('b', 'B')));
    final navigator = GlobalKey<NavigatorState>();
    late Route<void> owner;
    await tester.pumpWidget(MaterialApp(navigatorKey: navigator,
      home: const Scaffold(body: Text('父页'))));
    owner = MaterialPageRoute<void>(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => NovelConflicts.choose(context, store, _key),
      child: const Text('打开冲突'),
    )));
    unawaited(navigator.currentState!.push(owner));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开冲突'));
    await tester.pumpAndSettle();
    navigator.currentState!.removeRoute(owner);
    await tester.pump();
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(store.writes, 0);
    expect(store.state.revisions(_key), hasLength(2));
    expect(find.text('父页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bookmark delete versus edit remains an explicit choice', (tester) async {
    const key = 'bookmark/one';
    final edited = NovelSyncState().edit(key, {
      'id': 'one', 'note': '已编辑书签',
      'position': {'editionId': 'book-a', 'chapter': {'volume': '一卷', 'title': '第一章'}, 'quote': '原文'},
    }, 'b');
    final store = _Store(edited.merge(NovelSyncState().edit(key, null, 'a')));
    expect(NovelConflicts.bookmarkKeys(store.state, 'book-a'), [key]);
    expect(NovelConflicts.bookmarkKeys(store.state, 'book-b'), isEmpty);
    await _open(tester, store, key: key);
    expect(find.textContaining('已编辑书签'), findsOneWidget);
    await tester.tap(find.text('保留删除'));
    await tester.pumpAndSettle();
    expect(store.state.value(key), isNull);
    expect(store.state.merge(edited).value(key), isNull);
    expect(store.writes, 1);
  });

  testWidgets('same chapter and quote choices expose distinct offsets times and clocks', (tester) async {
    NovelSyncState position(int offset, int time, String device) =>
        NovelSyncState().edit(_key, {
          'chapter': {'volume': '一卷', 'title': '第一章'},
          'quote': '相同原文', 'sourceId': 'source',
          'textOffset': offset, 'updatedAt': time,
        }, device);
    final store = _Store(position(3, 1000, 'device-a')
        .merge(position(30, 2000, 'device-b')));
    await _open(tester, store);
    expect(find.text('一卷 第一章\n相同原文'), findsNWidgets(2));
    expect(find.textContaining('章内文字位置：3\n'), findsOneWidget);
    expect(find.textContaining('章内文字位置：30\n'), findsOneWidget);
    expect(find.textContaining('device-a=1'), findsOneWidget);
    expect(find.textContaining('device-b=1'), findsOneWidget);
    expect(find.textContaining('记录时间：'), findsNWidgets(2));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.writes, 0);
  });

  test('an explicitly deleted work is identified without inventing a candidate', () {
    final state = NovelSyncState().edit('edition/a', {'workId': 'w'}, 'a')
        .edit('work/w', null, 'a');
    expect(NovelConflicts.workDeleted(state, 'a'), isTrue);
    expect(NovelConflicts.workDeleted(state, 'another'), isFalse);
  });

  test('display and source dependencies stay local to their edition', () {
    var state = NovelSyncState().edit('edition/a', {'workId': 'work-a'}, 'a')
        .edit('edition/b', {'workId': 'work-b'}, 'a')
        .edit('selected/a', {'sourceId': 'one'}, 'a');
    state = state.merge(NovelSyncState().edit('work/work-a', {'title': 'A'}, 'a'))
        .merge(NovelSyncState().edit('work/work-a', {'title': 'B'}, 'b'))
        .merge(NovelSyncState().edit('selected/a', {'sourceId': 'two'}, 'b'));
    expect(NovelConflicts.displayKeys(state, 'a'), ['work/work-a']);
    expect(NovelConflicts.displayKeys(state, 'b'), isEmpty);
    expect(NovelConflicts.sourceKeys(state, 'a'), ['selected/a']);
    expect(NovelConflicts.sourceKeys(state, 'b'), isEmpty);
  });
}
