import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_locator.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_reader_page.dart';
import 'package:kazumi/novel/novel_reader_store.dart';
import 'package:kazumi/novel/novel_sync_state.dart';

const _book = NovelBook(sourceId: 'test-source', url: 'https://test/book', title: '测试小说');
const _one = NovelChapter(url: 'https://test/1', title: '第一章', volume: '第一卷', kind: '正文', number: 1);
const _two = NovelChapter(url: 'https://test/2', title: '第二章', volume: '第一卷', kind: '正文', number: 2);

class _ReaderStore extends ChangeNotifier implements NovelReaderStore {
  _ReaderStore(this.blocks, {this.initial, this.imageBytes});
  final Map<String, List<NovelBlock>> blocks;
  final NovelPosition? initial;
  final Uint8List? imageBytes;
  final List<NovelPosition> saved = [];
  final List<String> requested = [];
  final Map<String, NovelChapter> mappings = {};
  final List<NovelJson> marks = [];
  int mappingWrites = 0;
  bool failSave = false;
  bool failContentRefresh = false;
  Map<String, List<NovelBlock>>? refreshedBlocks;
  final List<bool> catalogRefreshes = [];
  final List<bool> contentRefreshes = [];
  NovelPosition? remotePosition;
  NovelSyncState _state = NovelSyncState();
  NovelJson prefs = {'fontSize': 20.0, 'lineHeight': 1.8, 'theme': 0,
    'mode': 'scroll', 'font': 'system', 'margin': 24.0, 'brightness': 0.0};
  @override NovelJson get preferences => Map.of(prefs);
  @override NovelSyncState get state => _state;
  @override String? get syncError => null;
  @override NovelPosition? position(String editionId) => remotePosition ?? (saved.isEmpty ? initial : saved.last);
  void receiveSequentialRemote(NovelPosition position) {
    _state = _state.edit('position/edition', position.toJson(), 'remote-device');
    remotePosition = position;
    notifyListeners();
  }
  String mappingKey(NovelPosition from, NovelBook target) =>
      '${from.editionId}/${from.sourceId}/${from.chapter.url}/${target.sourceId}/${target.url}';
  @override NovelChapter? mappedChapter(NovelPosition from, NovelBook target) =>
      mappings[mappingKey(from, target)];
  @override Future<void> confirmChapterMapping(NovelPosition from, NovelBook target, NovelChapter chapter) async {
    mappings[mappingKey(from, target)] = NovelChapter.fromJson(chapter.toJson());
    mappingWrites++;
  }
  @override Future<List<NovelChapter>> catalog(NovelBook book, {bool refresh = false}) async {
    catalogRefreshes.add(refresh);
    final available = refresh && refreshedBlocks != null ? refreshedBlocks! : blocks;
    return [_one, if (available.containsKey(_two.url)) _two];
  }
  @override Future<List<NovelBlock>> content(String sourceId, NovelChapter chapter, {bool refresh = false}) async {
    requested.add(chapter.url);
    contentRefreshes.add(refresh);
    if (refresh && failContentRefresh) throw StateError('simulated refresh network failure');
    return (refresh && refreshedBlocks != null ? refreshedBlocks! : blocks)[chapter.url]!;
  }
  @override Future<Uint8List> image(String sourceId, String url) async => imageBytes!;
  @override Future<void> savePosition(NovelPosition position) async {
    if (failSave) throw StateError('simulated disk write failure');
    saved.add(position);
    remotePosition = null;
    _state = _state.edit('position/edition', position.toJson(), 'test-device');
    notifyListeners();
  }
  @override Future<void> savePreferences(NovelJson value) async { prefs = Map.of(value); }
  @override Future<void> addBookmark(NovelPosition position, String note) async {}
  @override Future<void> deleteBookmark(String id) async {}
  @override List<NovelJson> bookmarks(String editionId) => marks;
  @override Future<void> resolve(String key, NovelRevision selected) async {
    _state = _state.resolve(key, selected, 'test-device');
    notifyListeners();
  }
  @override Future<void> syncAutomatically() async {}
}

NovelPosition _position(NovelChapter chapter, String text, int offset) => NovelLocator.capture(
  editionId: 'edition', sourceId: _book.sourceId, chapter: chapter,
  text: text, offset: offset, updatedAt: 1);

Future<void> _open(WidgetTester tester, _ReaderStore store, {double scale = 1, bool awaitsChoice = false}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(480, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async { await tester.pumpWidget(const SizedBox.shrink()); store.dispose(); });
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
    home: Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
        NovelReaderPage(service: store, editionId: 'edition', book: _book))),
      child: const Text('Open reader')))),
  ));
  await tester.tap(find.text('Open reader'));
  if (awaitsChoice) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  } else {
    await tester.pumpAndSettle();
  }
  await tester.pump(const Duration(milliseconds: 700));
}

ScrollController _scroll(WidgetTester tester) => tester.widget<ListView>(find.byType(ListView).first).controller!;

void main() {
  testWidgets('first open keeps the leading illustration visible and bookmarks its bytes', (tester) async {
    final bytes = await tester.runAsync(() async {
      final image = await createTestImage(width: 8, height: 8);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    final store = _ReaderStore({_one.url: const [
      NovelBlock.image('https://test/front.png'), NovelBlock.text('图片之后才是正文。'),
    ]}, imageBytes: bytes!);
    await _open(tester, store);
    expect(_scroll(tester).offset, 0);
    expect(store.saved.last.imageHash, sha256.convert(bytes).toString());
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('explicit restart after an unmatched restore includes the leading illustration', (tester) async {
    final bytes = await tester.runAsync(() async {
      final image = await createTestImage(width: 8, height: 8);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    final store = _ReaderStore({_one.url: const [
      NovelBlock.image('https://test/front.png'), NovelBlock.text('新书源完全不同的正文。'),
    ]}, initial: _position(_one, '原书源中已经消失的一段锚点文本。', 3), imageBytes: bytes!);
    await _open(tester, store, awaitsChoice: true);
    expect(find.text('从本章开始'), findsOneWidget);
    await tester.tap(find.text('从本章开始'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(_scroll(tester).offset, 0);
    expect(store.saved.last.imageHash, sha256.convert(bytes).toString());
    expect(tester.takeException(), isNull);
  });

  testWidgets('an identical illustration moved to another paragraph requires confirmation', (tester) async {
    final bytes = await tester.runAsync(() async {
      final image = await createTestImage(width: 8, height: 8);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    const text = '这一段文字原本位于插图之后，现在图片却移到了文字之后。';
    final previous = NovelPosition.fromJson({
      ..._position(_one, text, 0).toJson(),
      'imageHash': sha256.convert(bytes!).toString(),
    });
    final store = _ReaderStore({_one.url: const [
      NovelBlock.text(text), NovelBlock.image('https://test/moved.png'),
    ]}, initial: previous, imageBytes: bytes);
    await _open(tester, store, awaitsChoice: true);
    expect(find.text('正文或插图无法准确对应'), findsOneWidget);
    expect(store.saved, isEmpty, reason: 'An unverified image location must not replace the old position.');
    await tester.tap(find.text('从本章开始'));
    await tester.pumpAndSettle();
    expect(store.saved.last.textOffset, 0);
    expect(store.saved.last.imageHash, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['scroll', 'page']) {
  testWidgets('$mode window reflow and font changes preserve the exact saved text anchor', (tester) async {
    final text = String.fromCharCodes(List.generate(500, (i) => 0x4e00 + i));
    final store = _ReaderStore({_one.url: [NovelBlock.text(text)]}, initial: _position(_one, text, 53));
    store.prefs['mode'] = mode;
    await _open(tester, store);
    for (final width in [360.0, 520.0, 400.0, 480.0]) {
      tester.view.physicalSize = Size(width, 800);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
    }
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byType(Slider).first).onChanged!(28);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(store.saved, isNotEmpty);
    expect(store.saved.map((p) => p.textOffset).toSet(), {53});
    expect(tester.takeException(), isNull);
  });

  }

  testWidgets('system text scaling does not make a measured body line exceed its box', (tester) async {
    final store = _ReaderStore({_one.url: [NovelBlock.text(List.filled(80, 'A').join())]});
    await _open(tester, store, scale: 2);
    final lineFinder = find.byWidgetPredicate((w) => w is Text && w.maxLines == 1 &&
      w.style?.fontSize == 20 && (w.data?.isNotEmpty ?? false)).first;
    final line = tester.widget<Text>(lineFinder);
    final painter = TextPainter(text: TextSpan(text: line.data, style: line.style),
      textDirection: TextDirection.ltr, textScaler: const TextScaler.linear(2), maxLines: 1)..layout();
    expect(painter.width, lessThanOrEqualTo(tester.getSize(lineFinder).width + .01));
    painter.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving without moving does not overwrite a causally newer remote position', (tester) async {
    final text = List.generate(30, (i) => '第$i段：在线同步之后没有继续移动阅读位置。').join('\n');
    final store = _ReaderStore({_one.url: [NovelBlock.text(text)]}, initial: _position(_one, text, 53));
    await _open(tester, store);
    expect(store.saved.last.textOffset, 53);
    final writesBeforeRemote = store.saved.length;
    final remote = _position(_one, text, 9);
    store.receiveSequentialRemote(remote);
    await tester.pumpAndSettle();
    expect(store.state.revisions('position/edition'), hasLength(1));
    expect(store.position('edition')!.textOffset, 9);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NovelReaderPage), findsNothing);
    expect(store.saved, hasLength(writesBeforeRemote), reason: 'The local viewport did not move after its successful save; leaving must not publish old offset 53 over remote offset 9.');
    expect(store.position('edition')!.textOffset, 9);
  });

  testWidgets('a failed local write prevents leaving until a successful save', (tester) async {
    final store = _ReaderStore({_one.url: [NovelBlock.text(List.generate(80, (i) => '第$i段：正文保存失败时必须留在当前页面。').join('\n'))]});
    await _open(tester, store);
    store.failSave = true;
    final scroll = _scroll(tester);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NovelReaderPage), findsOneWidget);
    expect(find.textContaining('本地保存失败'), findsOneWidget);
    store.failSave = false;
    await tester.tap(find.text('重试保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NovelReaderPage), findsNothing);
    expect(find.text('Open reader'), findsOneWidget);
  });

  testWidgets('PageDown reaches the last partial viewport before changing chapter', (tester) async {
    final store = _ReaderStore({_one.url: List.generate(14, (i) => NovelBlock.text('段落$i')),
      _two.url: const [NovelBlock.text('第二章内容')]});
    await _open(tester, store);
    final controller = _scroll(tester);
    expect(controller.position.maxScrollExtent, greaterThan(0));
    expect(controller.position.maxScrollExtent, lessThan(controller.position.viewportDimension * .9));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(store.requested, [_one.url]);
    expect(controller.offset, closeTo(controller.position.maxScrollExtent, .01));
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await tester.pumpAndSettle();
    expect(store.requested.last, _two.url);
  });

  testWidgets('PageUp across a chapter boundary opens the previous chapter near its end', (tester) async {
    const secondText = '第二章开头';
    final store = _ReaderStore({_one.url: List.generate(50, (i) => NovelBlock.text('第一章段落$i')),
      _two.url: const [NovelBlock.text(secondText)]}, initial: _position(_two, secondText, 0));
    await _open(tester, store);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.pumpAndSettle();
    expect(store.requested.last, _one.url);
    expect(_scroll(tester).offset, greaterThan(0));
    expect(store.saved.last.chapter.url, _one.url);
    expect(store.saved.last.textOffset, greaterThan(0));
  });

  testWidgets('a confirmed cross-source chapter mapping is reused on reopening', (tester) async {
    const oldChapter = NovelChapter(url: 'https://old/chapter', title: '旧源拆分章',
      volume: '旧源卷', kind: '正文', number: 99);
    const text = '同一段正文在两个书源中具有不同的目录标题，但文本锚点唯一。';
    final original = NovelPosition.fromJson({
      ..._position(oldChapter, text, 8).toJson(), 'sourceId': 'old-source',
    });
    final store = _ReaderStore({_one.url: const [NovelBlock.text(text)]}, initial: original);
    await _open(tester, store, awaitsChoice: true);
    expect(find.text('无法唯一对应原进度，请选择章节'), findsOneWidget);
    await tester.tap(find.text(_one.title));
    await tester.pumpAndSettle();
    expect(store.mappingWrites, 1);
    expect(store.saved.last.textOffset, 8);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    store.saved.clear(); // Return to the original source position, preserving the mapping.
    await tester.tap(find.text('Open reader'));
    await tester.pumpAndSettle();
    expect(find.text('无法唯一对应原进度，请选择章节'), findsNothing);
    expect(store.mappingWrites, 1);
    expect(store.saved.last.chapter.url, _one.url);
    expect(store.saved.last.textOffset, 8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cross-source bookmarks reuse the same confirmed chapter mapping', (tester) async {
    const oldChapter = NovelChapter(url: 'https://old/bookmark-chapter', title: '旧书签章节',
      volume: '不同卷名', kind: '正文', number: 71);
    const text = '书签标记的目标段落可以通过已经确认的章节映射准确回到这里。';
    final bookmark = NovelPosition.fromJson({
      ..._position(oldChapter, text, 6).toJson(), 'sourceId': 'old-source',
    });
    final store = _ReaderStore({_one.url: const [NovelBlock.text('最初打开第一章。')],
      _two.url: const [NovelBlock.text(text)]});
    await store.confirmChapterMapping(bookmark, _book, _two);
    store.marks.add({'id': 'mark-one', 'note': '旧源书签', 'position': bookmark.toJson()});
    await _open(tester, store);
    await tester.tap(find.byTooltip('书签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旧源书签'));
    await tester.pumpAndSettle();
    expect(find.text('无法唯一对应原进度，请选择章节'), findsNothing);
    expect(store.mappingWrites, 1);
    expect(store.saved.last.chapter.url, _two.url);
    expect(store.saved.last.textOffset, 6);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a removed mapping target requires a new explicit chapter choice', (tester) async {
    const oldChapter = NovelChapter(url: 'https://old/chapter', title: '源章节',
      volume: '旧卷', kind: '正文', number: 99);
    const removed = NovelChapter(url: 'https://test/removed', title: '已删除章节',
      volume: '第一卷', kind: '正文', number: 3);
    const text = '目标目录改版后必须由用户重新确认对应章节，不能猜测其他章节。';
    final original = NovelPosition.fromJson({
      ..._position(oldChapter, text, 4).toJson(), 'sourceId': 'old-source',
    });
    final store = _ReaderStore({_one.url: const [NovelBlock.text(text)]}, initial: original);
    await store.confirmChapterMapping(original, _book, removed);
    await _open(tester, store, awaitsChoice: true);
    expect(find.text('先前确认的章节已从目录移除，请重新选择'), findsOneWidget);
    expect(store.saved, isEmpty);
    await tester.tap(find.text(_one.title));
    await tester.pumpAndSettle();
    expect(store.mappingWrites, 2);
    expect(store.mappedChapter(original, _book)!.url, _one.url);
    expect(store.saved.last.textOffset, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a mapped chapter with no anchor lets the reader select the correct split chapter', (tester) async {
    const oldChapter = NovelChapter(url: 'https://old/combined', title: '旧源合并章节',
      volume: '旧源卷', kind: '正文', number: 99);
    const text = '旧源的一章被新源拆成两章，原书签的唯一文本锚点实际在第二章。';
    final original = NovelPosition.fromJson({
      ..._position(oldChapter, text, 7).toJson(), 'sourceId': 'old-source',
    });
    final store = _ReaderStore({_one.url: const [NovelBlock.text('第一章完全没有旧书签的上下文。')],
      _two.url: const [NovelBlock.text(text)]}, initial: original);
    await store.confirmChapterMapping(original, _book, _one);
    await _open(tester, store, awaitsChoice: true);
    expect(find.text('正文或插图无法准确对应'), findsOneWidget);
    expect(store.saved, isEmpty);
    await tester.tap(find.text('重新选择章节'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('选择原位置对应的章节'), findsOneWidget);
    expect(store.saved, isEmpty);
    await tester.tap(find.text(_two.title));
    await tester.pumpAndSettle();
    expect(store.mappedChapter(original, _book)!.url, _two.url);
    expect(store.mappingWrites, 2);
    expect(store.saved.map((p) => p.chapter.url).toSet(), {_two.url});
    expect(store.saved.last.textOffset, 7);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh fetches new catalog and content while preserving the semantic location', (tester) async {
    final text = List.generate(15, (i) => '第$i段：目录更新后仍要恢复这段唯一正文的位置。').join('\n');
    const insertion = '新增的开头说明。\n';
    final store = _ReaderStore({_one.url: [NovelBlock.text(text)]}, initial: _position(_one, text, 53));
    store.refreshedBlocks = {_one.url: [NovelBlock.text(insertion + text)],
      _two.url: const [NovelBlock.text('连载新增第二章。')]};
    await _open(tester, store);
    final original = store.saved.last;
    await tester.tap(find.byTooltip('刷新目录与正文'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(store.catalogRefreshes, [false, true]);
    expect(store.contentRefreshes, [false, true]);
    expect(store.saved.last.textOffset, original.textOffset + NovelLocator.normalize(insertion).length);
    expect(store.saved.last.quote, original.quote);
    expect(store.saved.last.chapterDigest, NovelLocator.digest(insertion + text));
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    expect(find.text(_two.title), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed content refresh allows leaving without rewriting the saved location', (tester) async {
    final store = _ReaderStore({_one.url: const [NovelBlock.text('刷新失败不能困住读者，也不能重写已保存的位置。')]});
    await _open(tester, store);
    final writes = store.saved.length;
    store.failContentRefresh = true;
    await tester.tap(find.byTooltip('刷新目录与正文'));
    await tester.pumpAndSettle();
    expect(store.contentRefreshes, [false, true]);
    expect(find.textContaining('simulated refresh network failure'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NovelReaderPage), findsNothing);
    expect(store.saved, hasLength(writes));
  });

  testWidgets('dragging chapter progress saves the newly visible text anchor', (tester) async {
    final store = _ReaderStore({_one.url: List.generate(100, (i) => NovelBlock.text('第$i段可见阅读正文。'))});
    await _open(tester, store);
    expect(store.saved.last.textOffset, 0);
    await tester.tap(find.byTooltip('阅读进度'));
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('novel-chapter-progress'));
    final bounds = tester.getRect(slider);
    await tester.dragFrom(Offset(bounds.left + 24, bounds.center.dy),
      Offset(bounds.width * .6, 0));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(_scroll(tester).offset, greaterThan(_scroll(tester).position.maxScrollExtent * .5));
    expect(store.saved.last.textOffset, greaterThan(0));
    expect(store.saved.last.chapter.url, _one.url);
    await tester.tap(find.text('前往章节'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
