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
  bool failSave = false;
  NovelSyncState _state = NovelSyncState();
  NovelJson prefs = {'fontSize': 20.0, 'lineHeight': 1.8, 'theme': 0,
    'mode': 'scroll', 'font': 'system', 'margin': 24.0, 'brightness': 0.0};
  @override NovelJson get preferences => Map.of(prefs);
  @override NovelSyncState get state => _state;
  @override String? get syncError => null;
  @override NovelPosition? position(String editionId) => saved.isEmpty ? initial : saved.last;
  @override Future<List<NovelChapter>> catalog(NovelBook book, {bool refresh = false}) async =>
      [_one, if (blocks.containsKey(_two.url)) _two];
  @override Future<List<NovelBlock>> content(String sourceId, NovelChapter chapter, {bool refresh = false}) async {
    requested.add(chapter.url);
    return blocks[chapter.url]!;
  }
  @override Future<Uint8List> image(String sourceId, String url) async => imageBytes!;
  @override Future<void> savePosition(NovelPosition position) async {
    if (failSave) throw StateError('simulated disk write failure');
    saved.add(position);
    _state = _state.edit('position/edition', position.toJson(), 'test-device');
    notifyListeners();
  }
  @override Future<void> savePreferences(NovelJson value) async { prefs = Map.of(value); }
  @override Future<void> addBookmark(NovelPosition position, String note) async {}
  @override Future<void> deleteBookmark(String id) async {}
  @override List<NovelJson> bookmarks(String editionId) => [];
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

  testWidgets('a failed local write prevents leaving until a successful save', (tester) async {
    final store = _ReaderStore({_one.url: const [NovelBlock.text('正文保存失败时必须留在当前页面。')]});
    await _open(tester, store);
    store.failSave = true;
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
}
