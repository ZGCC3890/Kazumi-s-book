import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_illustrations.dart';
import 'package:kazumi/novel/novel_models.dart';

NovelChapter chapter(String url, String title, [String volume = '第一卷']) =>
  NovelChapter(url: url, title: title, volume: volume, kind: '正文');
final body = chapter('body', '第一章');
final art = chapter('art', '插图');
final nextBody = chapter('next-body', '第二章', '第二卷');
final nextArt = chapter('next-art', '插圖', '第二卷');
Future<void> completed() => Future<void>.delayed(Duration.zero);

Future<Uint8List> pixels(WidgetTester tester) async => (await tester.runAsync(() async {
  final image = await createTestImage(width: 30, height: 50);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}))!;

Future<void> mount(WidgetTester tester, NovelIllustrations gallery, {bool enabled = true}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async { await tester.pumpWidget(const SizedBox()); gallery.dispose(); });
  await tester.pumpWidget(MaterialApp(home: Scaffold(
    appBar: AppBar(actions: [NovelIllustrationToggle(gallery: gallery, enabled: enabled)]),
    body: NovelIllustrationBar(gallery: gallery),
  )));
}

void main() {
  test('only explicit gallery titles in the current contiguous volume are loaded in source order', () async {
    final requests = <String>[];
    final gallery = NovelIllustrations((c, refresh) async {
      requests.add(c.url);
      return [const NovelBlock.text('说明'), NovelBlock.image('${c.url}/2'), NovelBlock.image('${c.url}/1')];
    }, (_) async => Uint8List(0));
    addTearDown(gallery.dispose);
    final catalog = [body, chapter('story', '没有插图的故事'), art,
      chapter('colors', ' 彩 页 2 '), nextBody, nextArt,
      chapter('repeated-volume', '插图', '第一卷')];
    gallery.select(catalog, 0);
    expect(gallery.available, isTrue);
    expect(gallery.visible, isFalse);
    expect(requests, isEmpty);
    gallery.toggle();
    await completed();
    expect(requests, ['art', 'colors']);
    expect(gallery.urls, ['art/2', 'art/1', 'colors/2', 'colors/1']);
    gallery.select(catalog, 1);
    gallery.toggle();
    gallery.toggle();
    expect(requests.length, 2);
    gallery.select(catalog, 4);
    await completed();
    expect(gallery.urls, ['next-art/2', 'next-art/1']);
    gallery.select([body], 0);
    expect(gallery.available, isFalse);
    expect(gallery.visible, isFalse);
  });

  test('catalog replacement, refresh and image retries invalidate only their owned cache', () async {
    final refreshed = <bool>[], images = <String>[];
    final gallery = NovelIllustrations((c, refresh) async {
      refreshed.add(refresh);
      return [NovelBlock.image(c.url)];
    }, (url) async { images.add(url); return Uint8List(1); });
    addTearDown(gallery.dispose);
    gallery.select([body, art], 0);
    gallery.toggle();
    await completed();
    final image = gallery.image('art');
    expect(identical(image, gallery.image('art')), isTrue);
    await image;
    gallery.retryImage('art');
    await gallery.image('art');
    expect(images, ['art', 'art']);
    gallery.select([body, art], 0, refresh: true);
    await completed();
    await gallery.image('art');
    expect(images.length, 3);
    expect(refreshed, [false, true]);
    gallery.select([body, chapter('replacement', '插画')], 0);
    await completed();
    expect(gallery.urls, ['replacement']);
  });

  test('closing during load keeps results cached without reopening the bar', () async {
    final pending = Completer<List<NovelBlock>>();
    var requests = 0;
    final gallery = NovelIllustrations((_, _) { requests++; return pending.future; }, (_) async => Uint8List(0));
    addTearDown(gallery.dispose);
    gallery.select([body, art], 0);
    gallery.toggle();
    gallery.toggle();
    pending.complete([const NovelBlock.image('image')]);
    await completed();
    expect(gallery.visible, isFalse);
    gallery.toggle();
    expect(gallery.urls, ['image']);
    expect(requests, 1);
  });

  test('recognized gallery headings include numbered and traditional titles only', () {
    final gallery = NovelIllustrations((_, _) async => [], (_) async => Uint8List(0));
    addTearDown(gallery.dispose);
    for (final title in ['插图', '插圖', '插画', '插畫二', '彩页002', '彩頁', 'イラスト', '挿絵']) {
      gallery.select([body, chapter(title, title)], 0);
      expect(gallery.available, isTrue, reason: title);
    }
    gallery.select([body, chapter('not-gallery', '第一章 插图画师的故事')], 0);
    expect(gallery.available, isFalse);
  });

  for (final failOld in [false, true]) {
    test('late volume result is ignored, failure=$failOld, and disposal ignores pending completion', () async {
      final first = Completer<List<NovelBlock>>(), second = Completer<List<NovelBlock>>();
      final gallery = NovelIllustrations((c, _) => c.url == 'art' ? first.future : second.future,
        (_) async => Uint8List(0));
      gallery.select([body, art, nextBody, nextArt], 0);
      gallery.toggle();
      gallery.toggle();
      gallery.toggle();
      gallery.select([body, art, nextBody, nextArt], 2);
      if (failOld) { first.completeError(StateError('old volume failure')); }
      else { first.complete([const NovelBlock.image('old')]); }
      await completed();
      expect(gallery.busy, isTrue);
      expect(gallery.error, isNull);
      expect(gallery.urls, isEmpty);
      gallery.dispose();
      second.complete([const NovelBlock.image('new')]);
      await completed();
      expect(gallery.urls, isEmpty);
    });
  }

  testWidgets('gallery absent and loading states, explicit error, refresh and empty chapter', (tester) async {
    var fail = true;
    final refreshes = <bool>[];
    final pending = Completer<List<NovelBlock>>();
    final gallery = NovelIllustrations((_, refresh) {
      refreshes.add(refresh);
      return fail ? pending.future : Future.value([]);
    }, (_) async => Uint8List(0));
    await mount(tester, gallery);
    expect(find.byType(IconButton), findsNothing);
    gallery.select([body, art], 0);
    await tester.pump();
    await tester.tap(find.byTooltip('显示插图栏'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.completeError(StateError('source unavailable'));
    await tester.pumpAndSettle();
    expect(find.textContaining('source unavailable'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重试插图章'));
    await tester.pumpAndSettle();
    expect(refreshes, [false, true]);
    expect(find.text('插图章未包含图片'), findsOneWidget);
    await tester.tap(find.byTooltip('收起插图栏'));
    await tester.pumpAndSettle();
    expect(find.text('本卷插图'), findsNothing);
    expect(find.byTooltip('显示插图栏'), findsOneWidget);
  });

  testWidgets('disabled toggle, ordered horizontal thumbnails and full-size viewer', (tester) async {
    final bytes = await pixels(tester);
    final gallery = NovelIllustrations((_, _) async => List.generate(9, (i) => NovelBlock.image('$i')),
      (_) async => bytes);
    gallery.select([body, art], 0);
    await mount(tester, gallery, enabled: false);
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    gallery.toggle();
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('本卷插图 1，点击放大'), findsOneWidget);
    await tester.drag(find.byKey(const ValueKey('novel-illustration-strip')), const Offset(-1100, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('本卷插图 9，点击放大'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('关闭插图'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(gallery.visible, isTrue);
    await tester.tap(find.byTooltip('收起插图栏'));
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('image transport failure has an explicit retry and pending image state', (tester) async {
    final bytes = await pixels(tester);
    var fail = true;
    final pending = Completer<Uint8List>();
    final gallery = NovelIllustrations((_, _) async => [const NovelBlock.image('image')],
      (_) => fail ? pending.future : Future.value(bytes));
    gallery.select([body, art], 0);
    await mount(tester, gallery);
    await tester.tap(find.byTooltip('显示插图栏'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Image), findsNothing);
    pending.completeError(StateError('HTTP 403'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Bad state: HTTP 403'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('加载失败，重试'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('本卷插图 1，点击放大'), findsOneWidget);
    await tester.tap(find.byTooltip('隐藏插图栏'));
    await tester.pumpAndSettle();
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('invalid image bytes report decoding failure and can be replaced by a retry', (tester) async {
    final valid = await pixels(tester);
    var bytes = Uint8List.fromList([1, 2, 3]);
    final gallery = NovelIllustrations((_, _) async => [const NovelBlock.image('image')], (_) async => bytes);
    gallery.select([body, art], 0);
    await mount(tester, gallery);
    await tester.tap(find.byTooltip('显示插图栏'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.text('加载失败，重试'), findsOneWidget);
    bytes = valid;
    await tester.tap(find.text('加载失败，重试'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.text('加载失败，重试'), findsNothing);
    expect(find.bySemanticsLabel('本卷插图 1，点击放大'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
