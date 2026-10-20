import 'dart:async';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_locator.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_reader_page.dart';
import 'package:kazumi/novel/novel_reader_image.dart';
import 'package:kazumi/novel/novel_reader_toolbar.dart';
import 'package:kazumi/novel/novel_reader_store.dart';
import 'package:kazumi/novel/novel_sync_state.dart';

const _book = NovelBook(sourceId: 'test-source', url: 'https://test/book', title: '测试小说');
const _one = NovelChapter(url: 'https://test/1', title: '第一章', volume: '第一卷', kind: '正文', number: 1);
const _two = NovelChapter(url: 'https://test/2', title: '第二章', volume: '第一卷', kind: '正文', number: 2);

class _ReaderStore extends ChangeNotifier implements NovelReaderStore {
  _ReaderStore(this.blocks, {this.initial, this.imageBytes, this.imageLoader});
  final Map<String, List<NovelBlock>> blocks;
  final NovelPosition? initial;
  final Uint8List? imageBytes;
  final Future<Uint8List> Function(String)? imageLoader;
  final List<NovelPosition> saved = [];
  final List<String> requested = [];
  final List<String> contentSources = [];
  final Set<String> failedCatalogSources = {};
  List<NovelChapter>? chapters;
  final List<String> imageRequests = [];
  final Map<String, NovelChapter> mappings = {};
  final List<NovelJson> marks = [];
  final List<String> deletedBookmarks = [];
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
  String? pendingSyncError;
  int syncRetries = 0;
  @override String? get syncError => pendingSyncError;
  @override NovelPosition? position(String editionId) {
    if (remotePosition != null) return remotePosition;
    final key = 'position/$editionId';
    if (_state.revisions(key).isNotEmpty) {
      final value = _state.value(key);
      return value == null ? null : NovelPosition.fromJson(value);
    }
    return saved.isEmpty ? initial : saved.last;
  }
  final readIdentities = <String, String>{};
  @override Future<String> chapterReadIdentity(String editionId, NovelBook book,
      NovelChapter chapter, NovelPosition? restoredFrom) async {
    final current = '${book.sourceId}/${chapter.url}';
    return readIdentities.putIfAbsent(current, () => restoredFrom == null
      ? current : readIdentities['${restoredFrom.sourceId}/${restoredFrom.chapter.url}'] ??
          '${restoredFrom.sourceId}/${restoredFrom.chapter.url}');
  }
  void receiveSequentialRemote(NovelPosition position) {
    _state = _state.edit('position/edition', position.toJson(), 'remote-device');
    remotePosition = position;
    notifyListeners();
  }
  String mappingKey(NovelPosition from, NovelBook target) =>
      '${from.editionId}/${from.sourceId}/${from.chapter.url}/${target.sourceId}/${target.url}';
  @override String chapterMappingKey(NovelPosition from, NovelBook target) =>
      'chapterMap/${mappingKey(from, target)}';
  @override List<String> chapterMappingWriteKeys(NovelPosition from, NovelBook target,
      NovelChapter chapter) => [chapterMappingKey(from, target)];
  @override NovelChapter? mappedChapter(NovelPosition from, NovelBook target) {
    final key = chapterMappingKey(from, target);
    if (_state.revisions(key).isNotEmpty) {
      final value = _state.value(key);
      return value == null ? null : NovelChapter.fromJson(value['chapter'] as NovelJson);
    }
    return mappings[mappingKey(from, target)];
  }
  @override Future<void> confirmChapterMapping(NovelPosition from, NovelBook target, NovelChapter chapter) async {
    mappings[mappingKey(from, target)] = NovelChapter.fromJson(chapter.toJson());
    mappingWrites++;
  }
  @override Future<List<NovelChapter>> catalog(NovelBook book, {bool refresh = false}) async {
    catalogRefreshes.add(refresh);
    if (failedCatalogSources.contains(book.sourceId)) throw StateError('source catalog unavailable');
    if (chapters != null) return chapters!;
    final available = refresh && refreshedBlocks != null ? refreshedBlocks! : blocks;
    return [_one, if (available.containsKey(_two.url)) _two];
  }
  @override Future<List<NovelBlock>> content(String sourceId, NovelChapter chapter, {bool refresh = false}) async {
    requested.add(chapter.url);
    contentSources.add(sourceId);
    contentRefreshes.add(refresh);
    if (refresh && failContentRefresh) throw StateError('simulated refresh network failure');
    return (refresh && refreshedBlocks != null ? refreshedBlocks! : blocks)[chapter.url]!;
  }
  @override Future<Uint8List> image(String sourceId, String url) async {
    imageRequests.add(url);
    if (imageLoader != null) return imageLoader!(url);
    return imageBytes!;
  }
  @override Future<void> savePosition(NovelPosition position) async {
    if (failSave) throw StateError('simulated disk write failure');
    saved.add(position);
    remotePosition = null;
    _state = _state.edit('position/edition', position.toJson(), 'test-device');
    notifyListeners();
  }
  @override Future<void> savePreferences(NovelJson value) async { prefs = Map.of(value); }
  @override Future<void> addBookmark(NovelPosition position, String note) async {
    marks.add({'id': 'added', 'note': note, 'position': position.toJson()});
  }
  @override Future<void> deleteBookmark(String id) async {
    deletedBookmarks.add(id);
    marks.removeWhere((mark) => mark['id'] == id);
    notifyListeners();
  }
  @override List<NovelJson> bookmarks(String editionId) => marks;
  @override Future<void> resolve(String key, NovelRevision selected, {required String expectedToken}) async {
    _state = _state.resolve(key, selected, 'test-device', expectedToken: expectedToken);
    notifyListeners();
  }
  @override Future<void> retrySync() async {
    syncRetries++;
    pendingSyncError = null;
    notifyListeners();
  }
}

NovelPosition _position(NovelChapter chapter, String text, int offset) => NovelLocator.capture(
  editionId: 'edition', sourceId: _book.sourceId, chapter: chapter,
  text: text, offset: offset, updatedAt: 1);

Future<void> _open(WidgetTester tester, _ReaderStore store, {double scale = 1, bool awaitsChoice = false,
  bool showControls = true, Size size = const Size(480, 800),
  PreferredSizeWidget? shelfAppBar,
  List<NavigatorObserver> observers = const [],
  ValueNotifier<ThemeMode>? themeMode,
  Future<NovelBook?> Function(BuildContext, NovelBook)? onChangeSource,
  void Function(Future<bool> Function()? save)? registerSave,
  Future<void> Function(Set<String>)? onLeave}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async { await tester.pumpWidget(const SizedBox.shrink()); store.dispose(); });
  final mode = themeMode ?? ValueNotifier(ThemeMode.system);
  if (themeMode == null) addTearDown(mode.dispose);
  await tester.pumpWidget(ValueListenableBuilder<ThemeMode>(
    valueListenable: mode,
    builder: (_, value, child) => MaterialApp(
    navigatorObservers: observers,
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
    darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.blue, brightness: Brightness.dark).copyWith(surface: Colors.black)),
    themeMode: value,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
    home: Builder(builder: (context) => Scaffold(appBar: shelfAppBar, body: TextButton(
      onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
        NovelReaderPage(service: store, editionId: 'edition', book: _book,
          registerSave: registerSave,
          onLeave: onLeave, onChangeSource: onChangeSource))),
      child: const Text('Open reader')))),
  )));
  await tester.tap(find.text('Open reader'));
  if (awaitsChoice) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  } else {
    await tester.pumpAndSettle();
  }
  await tester.pump(const Duration(milliseconds: 700));
  if (showControls && !awaitsChoice) await _showControls(tester);
}

Future<void> _showControls(WidgetTester tester) async {
  if (find.byType(BackButton).evaluate().isNotEmpty) return;
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  final scrollMode = find.byType(CustomScrollView).evaluate().isNotEmpty;
  await tester.tapAt(Offset(scrollMode ? 4 : size.width / 2, size.height / 2));
  await tester.pumpAndSettle();
}

ScrollController _scroll(WidgetTester tester) => tester.widget<CustomScrollView>(find.byType(CustomScrollView).first).controller!;

Future<Uint8List> _readerPixels(WidgetTester tester, {int width = 8}) async =>
    (await tester.runAsync(() async {
      final image = await createTestImage(width: width, height: 8);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;

class _PopObserver extends NavigatorObserver {
  _PopObserver(this.onPop);
  final VoidCallback onPop;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => onPop();
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  testWidgets('desktop reader drags, closes, toggles fullscreen and restores window without changing progress', (tester) async {
    const channel = MethodChannel('window_manager');
    var fullscreen = false;
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'isFullScreen') return fullscreen;
      if (call.method == 'setFullScreen') fullscreen = (call.arguments as Map)['isFullScreen'] as bool;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final store = _ReaderStore({_one.url: [NovelBlock.text('桌面窗口保持阅读位置。' * 300)]});
    Future<bool> Function()? save;
    await _open(tester, store, size: const Size(1280, 800), registerSave: (value) => save = value);
    expect(save, isNotNull);
    expect(await save!(), isTrue);
    final before = store.saved.last.toJson();
    await tester.drag(find.text('测试小说'), const Offset(40, 10));
    expect(calls, contains('startDragging'));
    await tester.tap(find.byTooltip('切换全屏（F11）'));
    await tester.pumpAndSettle();
    expect(fullscreen, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(fullscreen, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(fullscreen, isTrue);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(calls, contains('close'));
    expect(store.saved.last.toJson(), before);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(fullscreen, isFalse);
    expect(save, isNull);
    expect(store.saved.last.bookUrl, _book.url);
  });
  for (final mode in ['scroll', 'page']) {
    for (final size in [const Size(360, 800), const Size(1280, 800)]) {
      testWidgets('reader source button cancels without moving $mode $size', (tester) async {
        final store = _ReaderStore({_one.url: [NovelBlock.text('取消换源保持当前文字。' * 300)]});
        store.prefs['mode'] = mode;
        final choice = Completer<NovelBook?>();
        var requests = 0;
        await _open(tester, store, size: size, scale: 2,
          onChangeSource: (_, book) { requests++; expect(book, same(_book)); return choice.future; });
        final button = find.byWidgetPredicate((widget) =>
          widget is IconButton && widget.tooltip == '更换书源');
        expect(button.hitTestable(), findsOneWidget);
        expect(tester.getCenter(button).dx, greaterThan(size.width / 2));
        final state = tester.state(find.byType(NovelReaderPage));
        final position = store.position('edition');
        await tester.tap(button);
        await tester.pump();
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        expect(requests, 1);
        choice.complete(null);
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(NovelReaderPage)), same(state));
        expect(store.position('edition')!.toJson(), position!.toJson());
        expect(store.catalogRefreshes, [false]);
        expect(tester.widget<IconButton>(button).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('reader changes source in place and preserves its current anchor', (tester) async {
    final text = List.generate(80, (i) => '段落$i：跨书源继续阅读的正文。').join();
    final store = _ReaderStore({_one.url: [NovelBlock.text(text)]});
    const target = NovelBook(sourceId: 'second', url: 'https://second/book', title: '另一书源译名');
    final selectedFrom = <NovelBook>[];
    await _open(tester, store, onChangeSource: (_, current) async {
      selectedFrom.add(current);
      return selectedFrom.length == 1 ? target : null;
    });
    final readerState = tester.state(find.byType(NovelReaderPage));
    _scroll(tester).jumpTo(900);
    await tester.pump();
    final before = store.saved.last;
    // The click must flush the unsaved position before source selection.
    await tester.tap(find.byTooltip('更换书源'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.state(find.byType(NovelReaderPage)), same(readerState));
    expect(store.position('edition')!.sourceId, 'second');
    expect(store.position('edition')!.textOffset, greaterThan(before.textOffset));
    final restored = store.position('edition')!;
    expect(restored.quote, contains('跨书源'));
    expect(store.contentSources, [_book.sourceId, 'second']);
    expect(find.text(target.title), findsOneWidget);
    await tester.tap(find.byTooltip('更换书源'));
    await tester.pumpAndSettle();
    expect(selectedFrom, [_book, target]);
    expect(store.position('edition')!.toJson(), restored.toJson());
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NovelReaderPage), findsNothing);
    expect(find.text('Open reader'), findsOneWidget);
  });

  testWidgets('reader does not change source until the current position is saved', (tester) async {
    final store = _ReaderStore({_one.url: [NovelBlock.text('保存失败不能丢失阅读进度。' * 300)]});
    var selections = 0;
    await _open(tester, store, onChangeSource: (_, _) async { selections++; return null; });
    store.failSave = true;
    _scroll(tester).jumpTo(800);
    await tester.pump();
    await tester.tap(find.byTooltip('更换书源'));
    await tester.pumpAndSettle();
    expect(selections, 0);
    expect(find.textContaining('simulated disk write failure'), findsOneWidget);
    store.failSave = false;
    await tester.tap(find.byTooltip('更换书源'));
    await tester.pumpAndSettle();
    expect(selections, 1);
    expect(store.saved.last.textOffset, greaterThan(0));
  });

  testWidgets('reader reports source selection errors and allows retry', (tester) async {
    final store = _ReaderStore({_one.url: [NovelBlock.text('正文。' * 100)]});
    var attempts = 0;
    await _open(tester, store, onChangeSource: (_, _) async {
      if (++attempts == 1) throw StateError('source selection failed');
      return null;
    });
    await tester.tap(find.byTooltip('更换书源'));
    await tester.pumpAndSettle();
    expect(find.textContaining('source selection failed'), findsOneWidget);
    expect(find.text(_book.title), findsOneWidget);
    await tester.tap(find.byTooltip('更换书源'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(store.catalogRefreshes, [false]);
  });

  testWidgets('failed chapter loading still exposes reader source selection', (tester) async {
    final store = _ReaderStore({_one.url: [NovelBlock.text('新书源正文。')]});
    store.failedCatalogSources.add(_book.sourceId);
    const target = NovelBook(sourceId: 'available', url: 'https://available/book', title: '可用书源');
    await _open(tester, store, showControls: false, onChangeSource: (_, _) async => target);
    expect(find.textContaining('source catalog unavailable'), findsOneWidget);
    expect(find.byTooltip('更换书源').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('更换书源'));
    await tester.pumpAndSettle();
    expect(store.position('edition')!.sourceId, target.sourceId);
    expect(find.textContaining('新书源正文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final fails in [false, true]) {
    testWidgets('source selection completion after reader disposal is ignored: $fails', (tester) async {
      final store = _ReaderStore({_one.url: [NovelBlock.text('正文。')]});
      final choice = Completer<NovelBook?>();
      await _open(tester, store, onChangeSource: (_, _) => choice.future);
      await tester.tap(find.byTooltip('更换书源'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      if (fails) { choice.completeError(StateError('late source failure')); }
      else { choice.complete(_book); }
      await tester.pumpAndSettle();
      expect(store.catalogRefreshes, [false]);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('scrolling within a line keeps the body and saved anchor unchanged', (tester) async {
    final store = _ReaderStore({_one.url: List.generate(500,
      (i) => NovelBlock.text('段落$i：${List.filled(8, '长章节滚动性能和惯性验证。').join()}'))});
    await _open(tester, store);
    final controller = _scroll(tester);
    final body = tester.widget<ScrollView>(find.byWidgetPredicate(
      (w) => w is ScrollView && w.controller == controller));
    final writes = store.saved.length;
    final clock = Stopwatch()..start();
    for (var i = 1; i <= 20; i++) {
      controller.jumpTo(i.toDouble());
      await tester.pump(const Duration(milliseconds: 8));
    }
    clock.stop();
    debugPrint('READER 500 paragraphs / 20 scroll frames: ${clock.elapsedMilliseconds}ms');
    expect(tester.widget<ScrollView>(find.byWidgetPredicate(
      (w) => w is ScrollView && w.controller == controller)), same(body));
    await tester.pump(const Duration(milliseconds: 700));
    expect(store.saved.length, writes);
  });

  for (final mode in ['scroll', 'page']) {
    for (final size in [const Size(412, 915), const Size(1280, 800)]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('toolbar overlay $mode $size scale $scale keeps text fixed', (tester) async {
          const bars = FakeViewPadding(top: 24, bottom: 24);
          tester.view.padding = bars;
          tester.view.viewPadding = bars;
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
              final visible = call.arguments == 'SystemUiMode.edgeToEdge';
              await Future<void>.value();
              tester.view.padding = visible ? bars : const FakeViewPadding();
              tester.view.viewPadding = visible ? bars : const FakeViewPadding();
            }
            return null;
          });
          final store = _ReaderStore({_one.url: List.generate(300,
            (i) => NovelBlock.text('段落$i：工具栏开关不能改变正文位置或阅读进度。'))});
          store.prefs['mode'] = mode;
          await _open(tester, store, size: size, scale: scale, showControls: false);
          final body = find.byType(mode == 'scroll' ? CustomScrollView : PageView);
          Object controller() => mode == 'scroll' ? _scroll(tester)
              : tester.widget<PageView>(body).controller!;
          double position() => mode == 'scroll' ? _scroll(tester).offset
              : tester.widget<PageView>(body).controller!.page!;
          if (mode == 'scroll') {
            _scroll(tester).jumpTo(173.5);
          } else {
            tester.widget<PageView>(body).controller!.jumpToPage(2);
          }
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 700));
          final originalController = controller();
          final originalPosition = position();
          final viewport = tester.getRect(body);
          final line = find.descendant(of: body, matching: find.byType(Text))
              .evaluate().firstWhere((element) {
            final center = tester.getCenter(find.byWidget(element.widget));
            return (element.widget as Text).data!.startsWith('段落') &&
                center.dy > size.height * .35 && center.dy < size.height * .65;
          }).widget as Text;
          final text = find.descendant(of: body, matching: find.text(line.data!));
          final textBounds = tester.getRect(text);
          final writes = store.saved.length;
          final anchor = store.saved.last.textOffset;
          for (var toggle = 0; toggle < 6; toggle++) {
            await tester.tapAt(viewport.center);
            for (var frame = 0; frame < 12; frame++) {
              await tester.pump(const Duration(milliseconds: 16));
              expect(tester.getRect(body), viewport, reason: 'viewport at toggle $toggle frame $frame');
              expect(controller(), same(originalController));
              expect(position(), originalPosition);
              expect(tester.getRect(text), textBounds);
            }
            expect(find.byTooltip('阅读设置'), toggle.isEven ? findsOneWidget : findsNothing);
          }
          await tester.pump(const Duration(milliseconds: 700));
          expect(store.saved.length, writes);
          expect(store.saved.last.textOffset, anchor);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  for (final mode in ['scroll', 'page']) {
    testWidgets('$mode keyboard and chapter controls work over the reading body', (tester) async {
      final content = List.generate(150, (i) => NovelBlock.text('第$i段：覆盖式工具栏与键盘翻页操作。'));
      final store = _ReaderStore({_one.url: content, _two.url: content});
      store.prefs['mode'] = mode;
      await _open(tester, store, showControls: false);
      double position() => mode == 'scroll' ? _scroll(tester).offset
          : tester.widget<PageView>(find.byType(PageView)).controller!.page!;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(position(), greaterThan(0));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(position(), closeTo(0, .01));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(position(), greaterThan(0));
      await _showControls(tester);
      await tester.tap(find.byTooltip('下一章'));
      await tester.pumpAndSettle();
      expect(store.saved.last.chapter.url, _two.url);
      await tester.tap(find.byTooltip('上一章'));
      await tester.pumpAndSettle();
      expect(store.saved.last.chapter.url, _one.url);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reader toolbar slides quickly and reverses without moving text', (tester) async {
    final store = _ReaderStore({_one.url: List.generate(150,
      (i) => NovelBlock.text('第$i段：工具栏动画不能重新排版正文。'))});
    await _open(tester, store, showControls: false);
    final body = find.byType(CustomScrollView);
    final viewport = tester.getRect(body);
    final controller = _scroll(tester);
    await tester.tapAt(viewport.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.getTopLeft(find.byType(AppBar)).dy, inExclusiveRange(-kToolbarHeight, 0));
    expect(tester.getRect(body), viewport);
    await tester.pump(NovelReaderToolbar.duration);
    expect(tester.getTopLeft(find.byType(AppBar)).dy, 0);
    final bottom = tester.getCenter(find.text('目录')).dy;
    await tester.tapAt(viewport.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.getTopLeft(find.byType(AppBar)).dy, inExclusiveRange(-kToolbarHeight, 0));
    expect(tester.getCenter(find.text('目录')).dy, greaterThan(bottom));
    await tester.tapAt(viewport.center);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(AppBar)).dy, 0);
    expect(_scroll(tester), same(controller));
    expect(tester.getRect(body), viewport);
    await tester.tapAt(viewport.center);
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('目录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening the reader catalog reveals the current chapter each time', (tester) async {
    final chapters = List.generate(100, (i) => NovelChapter(url: 'chapter-$i',
      title: '第$i章', volume: '本卷', kind: '正文', number: i));
    final store = _ReaderStore({for (final chapter in chapters)
      chapter.url: const [NovelBlock.text('章节正文')]}, initial: _position(chapters[70], '章节正文', 0));
    store.chapters = chapters;
    await _open(tester, store);
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, chapters[70].title).hitTestable(), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, chapters[71].title));
    await tester.pumpAndSettle();
    expect(store.saved.last.chapter.url, chapters[71].url);
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    final selected = find.widgetWithText(ListTile, chapters[71].title);
    expect(selected.hitTestable(), findsOneWidget);
    expect(tester.widget<ListTile>(selected).selected, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(store.saved.last.chapter.url, chapters[71].url);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid illustration bytes can be retried without reopening the chapter', (tester) async {
    var bytes = Uint8List.fromList([1, 2, 3]);
    final store = _ReaderStore({_one.url: const [NovelBlock.image('image')]},
      imageLoader: (_) async => bytes);
    await _open(tester, store);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.text('插图加载失败，重试'), findsOneWidget);
    bytes = await _readerPixels(tester);
    await tester.tap(find.text('插图加载失败，重试'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.text('插图加载失败，重试'), findsNothing);
    expect(find.bySemanticsLabel('小说插图，点击放大'), findsOneWidget);
    expect(store.requested, [_one.url]);
    expect(store.imageRequests, ['image', 'image']);
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['scroll', 'page']) {
    testWidgets('$mode illustrations appear independently and retry only the failed image', (tester) async {
      final bytes = await _readerPixels(tester);
      final pending = {'first': Completer<Uint8List>(), 'second': Completer<Uint8List>()};
      final store = _ReaderStore({_one.url: const [NovelBlock.image('first'), NovelBlock.image('second')]},
        imageLoader: (url) => pending[url]!.future);
      store.prefs['mode'] = mode;
      await _open(tester, store, showControls: false);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(Image), findsNothing);
      final body = find.byType(mode == 'scroll' ? CustomScrollView : PageView);
      final viewport = tester.getRect(body);
      void go(int image) {
        if (mode == 'scroll') {
          _scroll(tester).jumpTo(image * viewport.height * .88);
        } else {
          tester.widget<PageView>(body).controller!.jumpToPage(image);
        }
      }
      go(1);
      await tester.pumpAndSettle();
      expect(store.imageRequests, containsAll(['first', 'second']));
      pending['second']!.complete(bytes);
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(pending['first']!.isCompleted, isFalse);
      expect(tester.getRect(body), viewport);
      pending['first']!.completeError(StateError('fixture image failure'));
      go(0);
      await tester.pumpAndSettle();
      expect(find.text('插图加载失败，重试'), findsOneWidget);
      pending['first'] = Completer<Uint8List>();
      await tester.tap(find.text('插图加载失败，重试'));
      await tester.pump();
      expect(find.text('插图加载失败，重试'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      pending['first']!.complete(bytes);
      await tester.pumpAndSettle();
      expect(store.imageRequests.where((url) => url == 'first'), hasLength(2));
      expect(store.imageRequests.where((url) => url == 'second'), hasLength(1));
      expect(tester.getRect(body), viewport);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('same-source image progress opens its placeholder before bytes arrive', (tester) async {
    final pending = Completer<Uint8List>();
    final original = NovelPosition.fromJson({..._position(_one, '', 0).toJson(), 'imageUrl': 'second'});
    final store = _ReaderStore({_one.url: const [NovelBlock.image('first'), NovelBlock.image('second')]},
      initial: original, imageLoader: (_) => pending.future);
    await _open(tester, store, showControls: false);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(_scroll(tester).offset, greaterThan(0));
    expect(store.saved.last.imageUrl, 'second');
    expect(store.saved.last.imageHash, isNull);
    final offset = _scroll(tester).offset;
    pending.complete(await _readerPixels(tester));
    await tester.pumpAndSettle();
    expect(_scroll(tester).offset, offset);
    expect(store.saved.last.imageHash, isNotNull);
    expect(NovelPosition.fromJson(store.saved.last.toJson()).imageUrl, 'second');
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy illustration bookmarks resolve while images remain individually visible', (tester) async {
    final first = await _readerPixels(tester), second = await _readerPixels(tester, width: 12);
    final pending = {'first': Completer<Uint8List>(), 'second': Completer<Uint8List>()};
    final original = NovelPosition.fromJson({..._position(_one, '', 0).toJson(),
      'imageHash': sha256.convert(second).toString()});
    final store = _ReaderStore({_one.url: const [NovelBlock.image('first'), NovelBlock.image('second')]},
      initial: original, imageLoader: (url) => pending[url]!.future);
    await _open(tester, store, showControls: false);
    expect(find.byType(NovelReaderImage), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(store.saved, isEmpty);
    pending['second']!.complete(second);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(store.saved, isEmpty);
    pending['first']!.completeError(StateError('fixture first image failed'));
    await tester.pumpAndSettle();
    expect(find.text('重试定位'), findsOneWidget);
    pending['first'] = Completer<Uint8List>();
    await tester.tap(find.text('重试定位'));
    await tester.pump();
    pending['first']!.complete(first);
    await tester.pumpAndSettle();
    expect(_scroll(tester).offset, greaterThan(0));
    expect(store.saved.last.imageUrl, 'second');
    expect(store.saved.last.imageHash, original.imageHash);
    expect(store.imageRequests.where((url) => url == 'second'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final leave in [false, true]) {
    testWidgets('late illustration completion cannot change the reader after ${leave ? 'exit' : 'a chapter change'}', (tester) async {
      final bytes = await _readerPixels(tester);
      final pending = Completer<Uint8List>();
      final original = NovelPosition.fromJson({..._position(_one, '', 0).toJson(),
        'imageHash': sha256.convert(bytes).toString()});
      final store = _ReaderStore({_one.url: const [NovelBlock.image('first')],
        _two.url: const [NovelBlock.text('第二章正文')]},
        initial: original, imageLoader: (_) => pending.future);
      await _open(tester, store);
      await tester.tap(find.byTooltip(leave ? 'Back' : '下一章'));
      await tester.pumpAndSettle();
      final writes = store.saved.length;
      pending.complete(bytes);
      await tester.pumpAndSettle();
      expect(store.saved.length, writes);
      if (!leave) expect(store.saved.last.chapter.url, _two.url);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reading ahead cancels pending illustration restoration without a late jump', (tester) async {
    final bytes = await _readerPixels(tester);
    final pending = Completer<Uint8List>();
    final text = List.generate(100, (i) => '第$i段，等待插图时也能继续阅读。').join();
    final original = NovelPosition.fromJson({..._position(_one, text, 0).toJson(),
      'imageHash': sha256.convert(bytes).toString()});
    final store = _ReaderStore({_one.url: [const NovelBlock.image('image'), NovelBlock.text(text)]},
      initial: original, imageLoader: (_) => pending.future);
    await _open(tester, store, showControls: false);
    _scroll(tester).jumpTo(1100);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    final location = store.saved.last.textOffset;
    final offset = _scroll(tester).offset;
    expect(location, greaterThan(0));
    pending.complete(bytes);
    await tester.pumpAndSettle();
    expect(_scroll(tester).offset, offset);
    expect(store.saved.last.textOffset, location);
    expect(store.saved.last.imageHash, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sync notice and retry overlay the body without moving it', (tester) async {
    final store = _ReaderStore({_one.url: List.generate(100,
      (i) => NovelBlock.text('第$i段：同步提示不改变阅读布局。'))});
    await _open(tester, store, showControls: false);
    final body = find.byType(CustomScrollView);
    final viewport = tester.getRect(body);
    final controller = _scroll(tester);
    store.pendingSyncError = 'fixture sync failure';
    store.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('云同步未完成：fixture sync failure'), findsOneWidget);
    expect(tester.getRect(body), viewport);
    await _showControls(tester);
    expect(tester.getRect(body), viewport);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(store.syncRetries, 1);
    expect(find.text('云同步未完成：fixture sync failure'), findsNothing);
    expect(tester.getRect(body), viewport);
    expect(_scroll(tester), same(controller));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a fling keeps moving after release and persists its final anchor', (tester) async {
    final store = _ReaderStore({_one.url: List.generate(500,
      (i) => NovelBlock.text('第$i段：平滑惯性滚动与最后位置保存。'))});
    await _open(tester, store, showControls: false);
    final controller = _scroll(tester);
    await tester.fling(find.byType(CustomScrollView), const Offset(0, -320), 1800);
    await tester.pump();
    var previous = controller.offset;
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(microseconds: 8333));
      expect(controller.offset, greaterThan(previous));
      previous = controller.offset;
    }
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    final atRest = store.saved.last;
    expect(atRest.textOffset, greaterThan(0));
    await tester.pump(const Duration(seconds: 1));
    expect(store.saved.last, same(atRest));
  });

  for (final controlsVisible in [false, true]) {
    testWidgets('reader restores system insets before revealing the shelf (controls: $controlsVisible)', (tester) async {
      const bars = FakeViewPadding(top: 24, bottom: 24);
      tester.view.padding = bars;
      tester.view.viewPadding = bars;
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      final restore = Completer<void>();
      var exiting = false;
      final pops = <double>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          final visible = call.arguments == 'SystemUiMode.edgeToEdge';
          if (exiting && visible) await restore.future;
          await Future<void>.value();
          tester.view.padding = visible ? bars : const FakeViewPadding();
          tester.view.viewPadding = visible ? bars : const FakeViewPadding();
        }
        return null;
      });
      addTearDown(() {
        if (!restore.isCompleted) restore.complete();
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      final store = _ReaderStore({_one.url: const [NovelBlock.text('退出阅读后书架工具栏的位置应保持稳定。')]});
      await _open(tester, store, showControls: controlsVisible,
        shelfAppBar: AppBar(title: const Text('书架'), actions: const [Icon(Icons.search)]),
        observers: [_PopObserver(() => pops.add(tester.view.padding.top))]);
      exiting = true;
      if (controlsVisible) {
        await tester.tap(find.byType(BackButton));
      } else {
        await tester.binding.handlePopRoute();
      }
      await tester.pump();
      expect(pops, isEmpty, reason: 'The shelf must remain covered while system bars are being restored.');
      restore.complete();
      final toolbarPositions = <double>{};
      for (var frame = 0; frame < 60 && find.byType(NovelReaderPage).evaluate().isNotEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final search = find.byIcon(Icons.search);
        if (search.evaluate().isNotEmpty) toolbarPositions.add(tester.getCenter(search).dy);
      }
      expect(pops, [24]);
      expect(find.byType(NovelReaderPage), findsNothing);
      expect(toolbarPositions, {24 + kToolbarHeight / 2});
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('unrelated book and bookmark conflicts do not stop reading or settings', (tester) async {
    final store = _ReaderStore({_one.url: const [NovelBlock.text('正常正文继续阅读。')]});
    store._state = NovelSyncState().edit('position/other', {'title': 'A'}, 'a')
        .merge(NovelSyncState().edit('position/other', {'title': 'B'}, 'b'));
    const key = 'bookmark/other';
    store._state = store.state.merge(NovelSyncState().edit(key,
        {'position': {'editionId': 'other'}}, 'a'))
        .merge(NovelSyncState().edit(key, null, 'b'));
    await _open(tester, store);
    expect(store.saved, isNotEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    expect(find.text('阅读设置'), findsOneWidget);
    expect(store.state.conflicts, containsAll(['position/other', key]));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader rejects a progress choice when a third candidate arrives', (tester) async {
    const text = '同一篇正文的三个不同续读位置。';
    final store = _ReaderStore({_one.url: const [NovelBlock.text(text)]});
    final first = _position(_one, text, 1);
    final second = _position(_two, text, 2);
    store._state = NovelSyncState().edit('position/edition', first.toJson(), 'a')
        .merge(NovelSyncState().edit('position/edition', second.toJson(), 'b'));
    await _open(tester, store, showControls: false);
    await tester.tap(find.text('选择进度'));
    await tester.pumpAndSettle();
    store._state = store.state.merge(NovelSyncState().edit('position/edition',
        _position(_one, text, 3).toJson(), 'c'));
    store.notifyListeners();
    await tester.tap(find.widgetWithText(ListTile, '第一卷 第一章\n${first.quote}'));
    await tester.pumpAndSettle();
    expect(store.state.revisions('position/edition'), hasLength(3));
    expect(find.text('Bad state: 冲突已发生变化，请重新选择'), findsOneWidget);
    expect(store.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-book bookmark conflict is visible without stopping current reading', (tester) async {
    const text = '阅读进度和书签是两种独立的数据。';
    final store = _ReaderStore({_one.url: const [NovelBlock.text(text)]});
    const key = 'bookmark/conflicting';
    store._state = NovelSyncState().edit(key, {
      'id': 'conflicting', 'note': '待选择书签',
      'position': _position(_one, text, 3).toJson(),
    }, 'a').merge(NovelSyncState().edit(key, null, 'b'));
    final token = store.state.conflictToken(key);
    await _open(tester, store);
    expect(store.saved, isNotEmpty);
    await tester.tap(find.byTooltip('书签'));
    await tester.pumpAndSettle();
    expect(find.text('书签有冲突'), findsOneWidget);
    expect(find.text('还没有书签'), findsNothing);
    await tester.tap(find.text('书签有冲突'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.state.conflictToken(key), token);
    await tester.tap(find.text('书签有冲突'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留删除'));
    await tester.pumpAndSettle();
    expect(store.state.value(key), isNull);
    expect(find.text('还没有书签'), findsOneWidget);
    expect(store.state.value('position/edition'), isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mapping conflict cancellation keeps original position; explicit choice resumes', (tester) async {
    const text = '跨源章节对应必须确认，不能自动取其中一个。';
    final original = _position(_one, text, 3);
    final store = _ReaderStore({_one.url: const [NovelBlock.text(text)],
      _two.url: const [NovelBlock.text(text)]}, initial: original);
    final key = store.chapterMappingKey(original, _book);
    store._state = NovelSyncState().edit(key, {'chapter': _one.toJson()}, 'a')
        .merge(NovelSyncState().edit(key, {'chapter': _two.toJson()}, 'b'));
    final before = store.state.encode();
    await _open(tester, store, awaitsChoice: true);
    expect(find.text('选择要保留的章节对应'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.state.encode(), before);
    expect(store.saved, isEmpty);
    expect(find.text('Bad state: 章节对应尚未选择，原进度已保留。'), findsOneWidget);
    await tester.tap(find.text('重新加载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('第一卷 第一章'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(store.state.revisions(key), hasLength(1));
    expect(store.saved.last.chapter.url, _one.url);
    expect(tester.takeException(), isNull);
  });

  for (final readingMode in ['scroll', 'page']) {
    testWidgets('$readingMode reader follows app theme without moving progress', (tester) async {
      final mode = ValueNotifier(ThemeMode.light);
      addTearDown(mode.dispose);
      final store = _ReaderStore({_one.url: List.generate(160,
        (i) => NovelBlock.text('第$i段：配色跟随应用设置，切换明暗不改变阅读位置。'))});
      store.prefs['mode'] = readingMode;
      store.prefs['theme'] = 1;
      await _open(tester, store, themeMode: mode, showControls: false);
      final body = find.byType(readingMode == 'scroll' ? CustomScrollView : PageView);
      await tester.drag(body, Offset(readingMode == 'scroll' ? 0 : -400,
        readingMode == 'scroll' ? -400 : 0));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      final offset = store.saved.last.textOffset;
      expect(offset, greaterThan(0));
      Object controller() => readingMode == 'scroll'
        ? _scroll(tester) : tester.widget<PageView>(body).controller!;
      double viewportPosition() => readingMode == 'scroll'
        ? _scroll(tester).offset : tester.widget<PageView>(body).controller!.page!;
      Color? background() => tester.widget<Scaffold>(find.descendant(
        of: find.byType(NovelReaderPage), matching: find.byType(Scaffold))).backgroundColor;
      Text paragraph() => tester.widgetList<Text>(find.descendant(
        of: body, matching: find.byType(Text))).firstWhere((text) =>
          text.style?.fontSize == 20 && text.data!.isNotEmpty);
      final originalController = controller();
      final originalViewport = viewportPosition();
      expect(background(), const Color(0xffdce9d5));
      expect(paragraph().style!.color, const Color(0xff253323));
      mode.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Changing the reader theme');
      final scheme = Theme.of(tester.element(find.byType(NovelReaderPage))).colorScheme;
      expect(background(), scheme.surface);
      expect(paragraph().style!.color, scheme.onSurface);
      expect(controller(), same(originalController));
      expect(viewportPosition(), originalViewport);
      expect(store.saved.last.textOffset, offset);
      await _showControls(tester);
      expect(tester.takeException(), isNull, reason: 'Showing reader controls');
      final toolbar = Theme.of(tester.element(find.byTooltip('阅读设置')));
      expect(toolbar.brightness, Brightness.dark);
      expect(toolbar.colorScheme.primary, scheme.primary);
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Opening reader settings');
      expect(Theme.of(tester.element(find.text('阅读设置'))).brightness, Brightness.dark);
      expect(find.text('夜间'), findsNothing);
      mode.value = ThemeMode.light;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'Changing the theme beneath settings');
      expect(Theme.of(tester.element(find.text('阅读设置'))).brightness, Brightness.light);
      Navigator.of(tester.element(find.text('阅读设置'))).pop();
      await tester.pumpAndSettle();
      expect(background(), const Color(0xffdce9d5));
      expect(paragraph().style!.color, const Color(0xff253323));
      expect(store.prefs['theme'], 1);
      expect(store.saved.last.textOffset, offset);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('reader follows system brightness with legacy night preference', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final store = _ReaderStore({_one.url: const [NovelBlock.text('跟随系统的阅读正文')]});
    store.prefs['theme'] = 3;
    await _open(tester, store);
    final scaffold = find.descendant(of: find.byType(NovelReaderPage), matching: find.byType(Scaffold));
    expect(tester.widget<Scaffold>(scaffold).backgroundColor, Colors.black);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(tester.widget<Scaffold>(scaffold).backgroundColor, const Color(0xfffaf9f6));
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '纸白')).selected, isTrue);
    expect(find.text('夜间'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet margins scroll on both sides and center toggles hidden controls', (tester) async {
    final store = _ReaderStore({_one.url: List.generate(160,
      (i) => NovelBlock.text('第$i段：平板两侧留白也可以正常滑动正文。'))});
    await _open(tester, store, size: const Size(1440, 900), showControls: false);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byTooltip('阅读设置'), findsNothing);
    expect(find.textContaining('1/1'), findsNothing);
    await tester.dragFrom(const Offset(40, 650), const Offset(0, -300));
    await tester.pumpAndSettle();
    final left = _scroll(tester).offset;
    expect(left, greaterThan(0));
    await tester.dragFrom(const Offset(1400, 650), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(_scroll(tester).offset, greaterThan(left));
    await tester.tapAt(const Offset(720, 450));
    await tester.pumpAndSettle();
    expect(find.byTooltip('阅读设置'), findsOneWidget);
    await tester.tapAt(const Offset(720, 450));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('exit reports only successfully opened distinct chapters', (tester) async {
    Set<String>? read;
    final store = _ReaderStore({_one.url: const [NovelBlock.text('第一章正文')],
      _two.url: const [NovelBlock.text('第二章正文')]});
    await _open(tester, store, onLeave: (chapters) async { read = chapters; });
    await tester.tap(find.byTooltip('下一章'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(read, {'${_book.sourceId}/${_one.url}', '${_book.sourceId}/${_two.url}'});
    expect(find.byType(NovelReaderPage), findsNothing);
  });
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

  testWidgets('unmatched paragraphs resume automatically at the chapter leading illustration', (tester) async {
    final bytes = await tester.runAsync(() async {
      final image = await createTestImage(width: 8, height: 8);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    final store = _ReaderStore({_one.url: const [
      NovelBlock.image('https://test/front.png'), NovelBlock.text('新书源完全不同的正文。'),
    ]}, initial: _position(_one, '原书源中已经消失的一段锚点文本。', 3), imageBytes: bytes!);
    await _open(tester, store);
    expect(find.byType(AlertDialog), findsNothing);
    expect(_scroll(tester).offset, 0);
    expect(store.saved.last.imageHash, sha256.convert(bytes).toString());
    expect(tester.takeException(), isNull);
  });

  testWidgets('an illustration without a matching paragraph resumes at chapter start', (tester) async {
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
    await _open(tester, store);
    expect(find.byType(AlertDialog), findsNothing);
    expect(store.saved.last.textOffset, 0);
    expect(store.saved.last.imageHash, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['scroll', 'page']) {
  testWidgets('$mode window reflow and font changes preserve the exact saved text anchor', (tester) async {
    final text = String.fromCharCodes(List.generate(1200, (i) => 0x4e00 + i));
    final store = _ReaderStore({_one.url: [NovelBlock.text(text)]}, initial: _position(_one, text, 53));
    store.prefs['mode'] = mode;
    await _open(tester, store);
    for (final width in [360.0, 520.0, 400.0, 480.0]) {
      tester.view.physicalSize = Size(width, 800);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      expect(store.saved.map((p) => p.textOffset).toSet(), {53}, reason: 'Reflow at width $width');
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

  for (final mode in ['scroll', 'page']) {
    for (final width in [411.0, 1008.0]) {
      for (final scale in [1.0, 1.35, 2.0]) {
        testWidgets('$mode rendered glyphs fit width $width at scale $scale', (tester) async {
          final store = _ReaderStore({_one.url: [NovelBlock.text(
            List.filled(12, '甲乙丙丁中文换行，ABCDE punctuation！混合文字。').join())]});
          store.prefs['mode'] = mode;
          await _open(tester, store, scale: scale, size: Size(width, 900));
          final lines = find.byWidgetPredicate((w) => w is Text && w.maxLines == 1 &&
            w.style?.fontSize == 20 && (w.data?.isNotEmpty ?? false));
          expect(lines, findsWidgets);
          for (final element in lines.evaluate()) {
            final rich = find.descendant(of: find.byWidget(element.widget), matching: find.byType(RichText));
            final paragraph = tester.renderObject<RenderParagraph>(rich);
            final painter = TextPainter(text: paragraph.text, textDirection: paragraph.textDirection,
              textScaler: paragraph.textScaler)..layout();
            expect(painter.computeLineMetrics().single.width, lessThanOrEqualTo(paragraph.size.width + .01),
              reason: 'The laid-out line and the actual rendered font must use identical metrics.');
            painter.dispose();
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

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
    final store = _ReaderStore({_one.url: List.generate(20, (i) => NovelBlock.text('段落$i')),
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
    await _showControls(tester);
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

  testWidgets('saving a bookmark waits for the input dialog to close', (tester) async {
    final store = _ReaderStore({_one.url: const [NovelBlock.text('正文中添加书签。')]});
    await _open(tester, store);
    await tester.tap(find.byTooltip('添加书签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '想要重读的段落');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.marks.single['note'], '想要重读的段落');
    expect(store.marks.single['position']['chapter']['url'], _one.url);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary bookmarks cancel, save an empty note and delete to an empty list', (tester) async {
    final store = _ReaderStore({_one.url: const [NovelBlock.text('普通书签操作保持阅读位置。')]});
    await _open(tester, store);
    final position = store.saved.last.toJson();
    await tester.tap(find.byTooltip('添加书签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '取消时不保存');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.marks, isEmpty);
    expect(store.deletedBookmarks, isEmpty);

    await tester.tap(find.byTooltip('书签'));
    await tester.pumpAndSettle();
    expect(find.text('还没有书签'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加书签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(store.marks.single['note'], isEmpty);
    expect(store.marks.single['position'], position);
    final id = store.marks.single['id'] as String;

    await tester.tap(find.byTooltip('书签'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, _one.title), findsOneWidget);
    expect(find.text('还没有书签'), findsNothing);
    await tester.tap(find.byTooltip('删除书签'));
    await tester.pumpAndSettle();
    expect(store.deletedBookmarks, [id]);
    expect(store.marks, isEmpty);
    expect(find.text('我的书签'), findsOneWidget);
    expect(find.text('还没有书签'), findsOneWidget);
    expect(find.byTooltip('删除书签'), findsNothing);
    expect(store.saved.last.toJson(), position);
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

  testWidgets('a mapped chapter with no paragraph anchor opens directly and keeps catalog navigation', (tester) async {
    const oldChapter = NovelChapter(url: 'https://old/combined', title: '旧源合并章节',
      volume: '旧源卷', kind: '正文', number: 99);
    const text = '旧源的一章被新源拆成两章，原书签的唯一文本锚点实际在第二章。';
    final original = NovelPosition.fromJson({
      ..._position(oldChapter, text, 7).toJson(), 'sourceId': 'old-source',
    });
    final store = _ReaderStore({_one.url: const [NovelBlock.text('第一章完全没有旧书签的上下文。')],
      _two.url: const [NovelBlock.text(text)]}, initial: original);
    await store.confirmChapterMapping(original, _book, _one);
    await _open(tester, store);
    expect(find.byType(AlertDialog), findsNothing);
    expect(store.saved.last.chapter.url, _one.url);
    expect(store.saved.last.textOffset, 0);
    expect(store.readIdentities['${_book.sourceId}/${_one.url}'],
      'old-source/${oldChapter.url}');
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_two.title));
    await tester.pumpAndSettle();
    expect(store.mappedChapter(original, _book)!.url, _one.url);
    expect(store.mappingWrites, 1);
    expect(store.saved.last.chapter.url, _two.url);
    expect(store.saved.last.textOffset, 0);
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

  testWidgets('reader controls reflow without losing position and restore orientation on exit', (tester) async {
    final platformCalls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final text = String.fromCharCodes(List.generate(800, (i) => 0x4e00 + i));
    final store = _ReaderStore({_one.url: [NovelBlock.text(text)]},
        initial: _position(_one, text, 53));
    await _open(tester, store);
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    for (var index = 0; index < 4; index++) {
      final slider = find.byType(Slider).at(index);
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      final bounds = tester.getRect(slider);
      await tester.tapAt(bounds.center.translate(bounds.width * .2, 0));
      await tester.pumpAndSettle();
    }
    expect(store.prefs['fontSize'], greaterThan(20));
    expect(store.prefs['lineHeight'], greaterThan(1.8));
    expect(store.prefs['margin'], greaterThan(24));
    expect(store.prefs['brightness'], greaterThan(0));
    final font = find.byType(DropdownButton<String>);
    await tester.ensureVisible(font);
    await tester.pumpAndSettle();
    await tester.tap(font);
    await tester.pumpAndSettle();
    await tester.tap(find.text('衬线字体').last);
    await tester.pumpAndSettle();
    expect(store.prefs['font'], 'serif');
    for (final label in ['左右翻页', '滚动', '竖屏', '横屏', '跟随系统', '竖屏']) {
      final control = find.text(label);
      await tester.ensureVisible(control);
      await tester.pumpAndSettle();
      await tester.tap(control);
      await tester.pumpAndSettle();
    }
    final orientations = platformCalls.where((c) =>
        c.method == 'SystemChrome.setPreferredOrientations').map((c) => c.arguments).toList();
    expect(orientations, [
      ['DeviceOrientation.portraitUp'],
      ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'],
      <String>[],
      ['DeviceOrientation.portraitUp'],
    ]);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(store.saved.map((position) => position.textOffset).toSet(), {53});
    final dimming = find.byWidgetPredicate((widget) => widget is DecoratedBox &&
        widget.position == DecorationPosition.foreground &&
        widget.decoration is BoxDecoration &&
        (widget.decoration as BoxDecoration).color?.a == store.prefs['brightness']);
    expect(dimming, findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(NovelReaderPage), findsNothing);
    expect(dimming, findsNothing);
    expect(platformCalls.where((c) => c.method == 'SystemChrome.setPreferredOrientations').last.arguments,
        isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['scroll', 'page']) {
  for (final size in [const Size(480, 800), const Size(1280, 800)]) {
  testWidgets('$mode gallery opening and hiding preserves the exact reading anchor at $size', (tester) async {
    final bytes = await tester.runAsync(() async {
      final image = await createTestImage(width: 32, height: 48);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    const art = NovelChapter(url: 'art', title: '插图', volume: '第一卷', kind: '插图');
    const other = NovelChapter(url: 'other', title: '第三章', volume: '第二卷', kind: '正文');
    final text = String.fromCharCodes(List.generate(1200, (i) => 0x4e00 + i));
    final store = _ReaderStore({_one.url: [NovelBlock.text(text)],
      art.url: const [NovelBlock.image('image')], other.url: [NovelBlock.text(text)]},
      initial: _position(_one, text, 53), imageBytes: bytes!);
    store.chapters = [_one, art, other];
    store.prefs['mode'] = mode;
    await _open(tester, store, size: size, scale: 2);
    expect(store.requested, [_one.url]);
    final body = find.byType(mode == 'scroll' ? CustomScrollView : PageView);
    final viewport = tester.getRect(body);
    Object controller() => mode == 'scroll' ? _scroll(tester)
        : tester.widget<PageView>(body).controller!;
    final originalController = controller();
    await tester.tap(find.byTooltip('显示插图栏'));
    await tester.pumpAndSettle();
    expect(tester.getRect(body), viewport);
    expect(controller(), same(originalController));
    await tester.tapAt(viewport.center);
    await tester.pumpAndSettle();
    expect(find.byTooltip('阅读设置'), findsNothing);
    expect(tester.getRect(body), viewport);
    expect(controller(), same(originalController));
    await tester.tapAt(viewport.center);
    await tester.pumpAndSettle();
    expect(find.byTooltip('阅读设置'), findsOneWidget);
    expect(tester.getRect(body), viewport);
    expect(controller(), same(originalController));
    await tester.tap(find.bySemanticsLabel('本卷插图 1，点击放大'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭插图'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('隐藏插图栏'));
    await tester.pumpAndSettle();
    expect(tester.getRect(body), viewport);
    expect(controller(), same(originalController));
    await tester.tap(find.byTooltip('显示插图栏'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(store.saved.map((p) => p.textOffset).toSet(), {53});
    expect(store.requested, [_one.url, art.url]);
    expect(store.imageRequests, ['image']);
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(other.title));
    await tester.pumpAndSettle();
    expect(find.byTooltip('显示插图栏'), findsNothing);
    expect(find.byTooltip('隐藏插图栏'), findsNothing);
    expect(find.text('本卷插图'), findsNothing);
    expect(store.saved.last.chapter.url, other.url);
    expect(store.saved.last.textOffset, 0);
    expect(tester.takeException(), isNull);
  });
  }
  }

  testWidgets('illustration pinch zoom closes without changing the reading anchor', (tester) async {
    final bytes = await tester.runAsync(() async {
      final image = await createTestImage(width: 256, height: 256);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    final store = _ReaderStore({_one.url: const [
      NovelBlock.image('https://test/front.png'),
      NovelBlock.text('插图后的正文保持原来的阅读位置。'),
    ]}, imageBytes: bytes!);
    await _open(tester, store, showControls: false);
    final before = store.saved.last.toJson();
    final offset = _scroll(tester).offset;
    await tester.tap(find.bySemanticsLabel('小说插图，点击放大'));
    await tester.pumpAndSettle();
    final viewer = find.byType(InteractiveViewer);
    expect(viewer, findsOneWidget);
    double zoom() => tester.widget<Transform>(find.descendant(
      of: viewer, matching: find.byType(Transform),
    ).first).transform.getMaxScaleOnAxis();
    expect(zoom(), 1);
    final center = tester.getCenter(viewer);
    final left = await tester.startGesture(center - const Offset(40, 0), pointer: 1);
    final right = await tester.startGesture(center + const Offset(40, 0), pointer: 2);
    await tester.pump();
    await left.moveTo(center - const Offset(60, 0));
    await right.moveTo(center + const Offset(60, 0));
    await tester.pump();
    await left.moveTo(center - const Offset(120, 0));
    await right.moveTo(center + const Offset(120, 0));
    await tester.pump();
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(zoom(), greaterThan(1.5));
    await tester.tap(find.byTooltip('关闭插图'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.byType(NovelReaderPage), findsOneWidget);
    expect(_scroll(tester).offset, offset);
    expect(store.saved.last.toJson(), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('page taps and swipes save progress and taps cross both chapter boundaries', (tester) async {
    final text = String.fromCharCodes(List.generate(1600, (i) => 0x4e00 + i));
    final store = _ReaderStore({
      _one.url: [NovelBlock.text(text)],
      _two.url: [NovelBlock.text('第二章开头。$text')],
    });
    store.prefs['mode'] = 'page';
    await _open(tester, store, showControls: false);
    PageView pages() => tester.widget<PageView>(find.byType(PageView));
    Future<void> settle() async {
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
    }
    final count = pages().childrenDelegate.estimatedChildCount!;
    expect(count, greaterThan(2));
    final bounds = tester.getRect(find.byType(PageView));
    final left = Offset(bounds.left + 30, bounds.center.dy);
    final right = Offset(bounds.right - 30, bounds.center.dy);
    await tester.tapAt(right);
    await settle();
    expect(pages().controller!.page, 1);
    final pageOneOffset = store.saved.last.textOffset;
    expect(pageOneOffset, greaterThan(0));
    await tester.drag(find.byType(PageView), Offset(-bounds.width * .7, 0));
    await settle();
    expect(pages().controller!.page, 2);
    expect(store.saved.last.textOffset, greaterThan(pageOneOffset));
    await tester.drag(find.byType(PageView), Offset(bounds.width * .7, 0));
    await settle();
    expect(pages().controller!.page, 1);
    expect(store.saved.last.textOffset, pageOneOffset);
    await tester.tapAt(left);
    await settle();
    expect(pages().controller!.page, 0);
    expect(store.saved.last.textOffset, 0);
    for (var page = 1; page < count; page++) {
      await tester.tapAt(right);
      await settle();
      expect(store.saved.last.chapter.url, _one.url);
      expect(pages().controller!.page, page);
    }
    final lastOffset = store.saved.last.textOffset;
    await tester.tapAt(right);
    await settle();
    expect(store.saved.last.chapter.url, _two.url);
    expect(store.saved.last.textOffset, 0);
    expect(pages().controller!.page, 0);
    await tester.tapAt(left);
    await settle();
    expect(store.saved.last.chapter.url, _one.url);
    expect(pages().controller!.page, count - 1);
    expect(store.saved.last.textOffset, lastOffset);
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['scroll', 'page']) {
    testWidgets('$mode whole-book slider opens and saves the selected chapter', (tester) async {
      final store = _ReaderStore({
        _one.url: const [NovelBlock.text('第一章原文。')],
        _two.url: const [NovelBlock.text('第二章选中的正文。')],
      });
      store.prefs['mode'] = mode;
      await _open(tester, store);
      await tester.tap(find.byTooltip('阅读进度'));
      await tester.pumpAndSettle();
      final slider = find.byKey(const ValueKey('novel-book-progress'));
      final bounds = tester.getRect(slider);
      await tester.dragFrom(Offset(bounds.left + 24, bounds.center.dy),
          Offset(bounds.width - 48, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, 1);
      expect(store.saved.last.chapter.url, _one.url);
      await tester.tap(find.text('前往章节'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byKey(const ValueKey('novel-book-progress')), findsNothing);
      expect(find.text('第二章选中的正文。'), findsOneWidget);
      expect(store.saved.last.chapter.url, _two.url);
      expect(store.saved.last.textOffset, 0);
      expect(store.requested.last, _two.url);
      expect(tester.takeException(), isNull);
    });
  }

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
