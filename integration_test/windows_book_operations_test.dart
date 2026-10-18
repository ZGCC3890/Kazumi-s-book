import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kazumi/main.dart' as app;
import 'package:kazumi/novel/novel_book_cover.dart';
import 'package:kazumi/novel/novel_reader_page.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/novel/novel_accounts.dart';
import 'package:kazumi/pages/player/player_item.dart';
import 'package:kazumi/pages/settings/settings_page.dart';
import 'package:kazumi/pages/video/video_page.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/bean/dialog/update_available_dialog.dart';
import 'package:kazumi/services/update/auto_updater.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/native_test_profile.dart';

Future<void> until(WidgetTester tester, bool Function() ready, String reason,
    {Duration timeout = const Duration(seconds: 2)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull, reason: reason);
  }
  if (!ready()) {
    debugPrintSynchronously('NATIVE_OPERATION_TIMEOUT: $reason');
    debugPrintSynchronously('NATIVE_VISIBLE_TEXT: ${find.byType(Text).evaluate()
        .map((element) => (element.widget as Text).data)
        .whereType<String>().take(60).join(' | ')}');
    await screenshot(tester, 'operation-timeout');
  }
  expect(ready(), isTrue, reason: reason);
}

Future<void> visible(WidgetTester tester, Finder finder,
        {Duration timeout = const Duration(seconds: 2)}) =>
    until(tester, () => finder.evaluate().isNotEmpty,
        finder.describeMatch(Plurality.zero), timeout: timeout);

Future<void> click(WidgetTester tester, Finder finder) async {
  await visible(tester, finder);
  debugPrintSynchronously('NATIVE_TAP: ${finder.describeMatch(Plurality.zero)}');
  await tester.ensureVisible(finder.last);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(finder.last);
  await tester.pump(const Duration(milliseconds: 450));
}

Future<void> text(WidgetTester tester, String value) =>
    click(tester, find.text(value));

Future<void> type(WidgetTester tester, Finder field, String value) async {
  // IntegrationTest keeps the real IME. showKeyboard caches focusedEditable,
  // so revisiting an unfocused field requires the same click as a user makes.
  await click(tester, field);
  await tester.enterText(field.last, value);
  expect(tester.widget<TextField>(field.last).controller!.text, value);
  await tester.pump();
}

Future<void> category(WidgetTester tester, String label, {double delta = 200}) async {
  final menu = find.descendant(of: find.byType(SettingsPage),
      matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(find.text(label), delta, scrollable: menu);
  await text(tester, label);
}

Future<void> back(WidgetTester tester) =>
    click(tester, find.byIcon(Icons.arrow_back));

Future<void> screenshot(WidgetTester tester, String name, {Finder? boundaryFinder}) async {
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    boundaryFinder ?? find.byType(RepaintBoundary).first,
  );
  final image = await boundary.toImage();
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('build/windows-ui/$name.png');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(png!.buffer.asUint8List());
  image.dispose();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets('native Windows main search, import, reader, bookmarks and shelf', (tester) async {
    expect(Platform.isWindows, isTrue);
    final artifacts = await Directory('build/windows-ui').absolute.create(recursive: true);
    final profile = await artifacts.createTemp('profile-');
    PathProviderPlatform.instance = NativeTestProfile(profile);
    expect((await getApplicationSupportDirectory()).path, '${profile.path}/support');
    debugPrintSynchronously('NATIVE_TEST_PROFILE: ${profile.path}');
    app.main();
    await visible(tester, find.text('暂不创建'), timeout: const Duration(seconds: 10));
    await text(tester, '暂不创建');
    for (final label in ['同意并继续', '继续', '开始使用', '仍然继续']) {
      await text(tester, label);
    }
    await visible(tester, find.text('热门番组'));
    await click(tester, find.byTooltip('搜索'));
    await visible(tester, find.text('番剧搜索'));
    await click(tester, find.byTooltip('搜索类型'));
    await text(tester, '小说');
    await click(tester, find.byTooltip('小说规则'));
    await Clipboard.setData(const ClipboardData(
      text: 'http://127.0.0.1:8765/novels/rules.json',
    ));
    await text(tester, '添加规则');
    await text(tester, '从剪贴板导入');
    await text(tester, '导入规则');
    await text(tester, 'Fixture Source A');
    await visible(tester, find.text('打开书源网站 / 注册'));
    await screenshot(tester, 'source-account-manager', boundaryFinder: find.ancestor(
      of: find.byType(AlertDialog), matching: find.byType(RepaintBoundary)).first);
    await text(tester, '取消');
    await visible(tester, find.text('Fixture Source A'));
    final accountHttp = Dio();
    await Clipboard.setData(const ClipboardData(text: 'http://127.0.0.1:8765/account/rule.json'));
    await text(tester, '添加规则');
    await text(tester, '从剪贴板导入');
    await text(tester, '导入规则');
    await text(tester, 'Fixture Account');
    await type(tester, find.widgetWithText(TextField, '书源用户名'), 'fixture-reader');
    await type(tester, find.widgetWithText(TextField, '密码'), 'fixture-password');
    await text(tester, '登录并验证');
    await visible(tester, find.text('Fixture Source A'));
    final accountService = inject<NovelService>();
    final stored = await const NovelCredentialStore().read(accountService.rule('fixture-l'));
    expect(stored!.password, 'fixture-password');
    final encryptedFiles = await Directory('${profile.path}/support').list(recursive: true).where((file) =>
      file is File && file.path.contains('flutter_secure_storage')).cast<File>().toList();
    expect(encryptedFiles, isNotEmpty);
    for (final file in encryptedFiles) {
      expect(latin1.decode(await file.readAsBytes()), isNot(contains('fixture-password')));
    }
    await accountHttp.get('http://127.0.0.1:8765/account/expire');
    expect((await accountService.adapter('fixture-l').search('Fixture')).single.title, '葬送的芙莉莲');
    expect((await accountHttp.get('http://127.0.0.1:8765/account/state')).data['logins'], 2);
    await text(tester, 'Fixture Account');
    expect(tester.widget<TextField>(find.widgetWithText(TextField, '密码')).controller!.text, 'fixture-password');
    await text(tester, '验证当前会话');
    await visible(tester, find.text('当前登录会话验证成功'));
    await text(tester, '清除登录');
    expect(await const NovelCredentialStore().read(accountService.rule('fixture-l')), isNull);
    await text(tester, '取消');
    await accountService.removeRule('fixture-l');
    accountHttp.close();
    await back(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('小说搜索'), findsOneWidget);
    await type(tester, find.byType(TextField).first, 'Fixture');
    await screenshot(tester, 'novel-query-before-submit');
    await click(tester, find.byTooltip('搜索'));
    await visible(tester, find.text('葬送的芙莉莲').first);
    await screenshot(tester, 'novel-query-after-submit');
    final sourceCard = find.ancestor(of: find.text('Fixture Source A'),
        matching: find.byType(Material)).first;
    await click(tester, find.descendant(of: sourceCard, matching: find.text('阅读')));
    await visible(tester, find.byType(NovelReaderPage));
    final reader = tester.widget<NovelReaderPage>(find.byType(NovelReaderPage));
    final novels = inject<NovelService>();
    await until(tester, () => novels.position(reader.editionId) != null,
        'Real reader must save its initial position');
    expect(find.byTooltip('阅读设置'), findsNothing);
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.dragFrom(Offset(16, size.height * .8), const Offset(0, -450));
    await until(tester, () => novels.position(reader.editionId)!.textOffset > 0,
        'Dragging the native Windows reader margin must advance the stored anchor');
    final beforeKey = novels.position(reader.editionId)!.textOffset;
    final scrollFinder = find.descendant(of: find.byType(NovelReaderPage), matching: find.byType(CustomScrollView));
    final scroll = tester.widget<CustomScrollView>(scrollFinder).controller!;
    await tester.fling(scrollFinder, const Offset(0, -240), 1500);
    await tester.pump();
    final released = scroll.offset;
    await tester.pump(const Duration(milliseconds: 100));
    expect(scroll.offset, greaterThan(released), reason: 'Native reader must continue moving after touch release');
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await until(tester, () => novels.position(reader.editionId)!.textOffset > beforeKey,
        'Native Windows PageDown must advance reading');
    await tester.tapAt(size.center(Offset.zero));
    await tester.pump(const Duration(milliseconds: 700));
    final galleryAnchor = novels.position(reader.editionId)!.textOffset;
    await click(tester, find.byTooltip('显示插图栏'));
    await visible(tester, find.bySemanticsLabel('本卷插图 1，点击放大'));
    await screenshot(tester, 'reader-gallery-strip');
    await tester.drag(find.byKey(const ValueKey('novel-illustration-strip')), const Offset(-1200, 0));
    await click(tester, find.bySemanticsLabel('本卷插图 8，点击放大'));
    await visible(tester, find.byType(InteractiveViewer));
    await screenshot(tester, 'reader-gallery-zoom');
    await click(tester, find.byTooltip('关闭插图'));
    await click(tester, find.byTooltip('隐藏插图栏'));
    expect(novels.position(reader.editionId)!.textOffset, galleryAnchor);
    await click(tester, find.byTooltip('添加书签'));
    await type(tester, find.byType(TextField).last, 'WindowsBookmark');
    await text(tester, '保存');
    await until(tester, () => novels.bookmarks(reader.editionId)
        .any((mark) => mark['note'] == 'WindowsBookmark'), 'Native bookmark must persist');
    await text(tester, '目录');
    await text(tester, 'Chapter 2');
    await until(tester, () => novels.position(reader.editionId)!.chapter.title == 'Chapter 2',
        'Directory selection must save chapter two');
    await screenshot(tester, 'reader-chapter-two');
    await back(tester);
    await text(tester, '加入书架');
    await visible(tester, find.text('小说搜索'));
    await back(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await click(tester, find.descendant(of: find.byType(NavigationRail),
        matching: find.byIcon(Icons.favorite_border)));
    await text(tester, '书架');
    await visible(tester, find.text('葬送的芙莉莲'));
    expect(novels.isShelved(reader.editionId), isTrue);
    expect(novels.selectedBook(reader.editionId)!.cover,
        'http://127.0.0.1:8765/cover.png');
    final cover = find.descendant(of: find.byType(NovelBookCover),
        matching: find.byType(RawImage));
    await until(tester, () => cover.evaluate().any(
        (element) => (element.widget as RawImage).image != null),
        'The source cover must be decoded before recording the bookshelf');
    await screenshot(tester, 'bookshelf');
    await text(tester, '葬送的芙莉莲');
    await visible(tester, find.byType(NovelReaderPage));
    await until(tester, () => novels.position(reader.editionId)!.chapter.title == 'Chapter 2',
        'Bookshelf must resume chapter two');
    await screenshot(tester, 'reader-resumed');
    await click(tester, find.textContaining('Chapter 2 opening'));
    await back(tester);
    await click(tester, find.byTooltip('小说操作'));
    await text(tester, '删除书籍');
    await text(tester, '取消');
    expect(novels.isShelved(reader.editionId), isTrue);
    await click(tester, find.byTooltip('小说操作'));
    await text(tester, '删除书籍');
    await text(tester, '删除');
    expect(novels.isShelved(reader.editionId), isFalse);
    expect(novels.position(reader.editionId)!.chapter.title, 'Chapter 2');
    expect(novels.bookmarks(reader.editionId).any((mark) => mark['note'] == 'WindowsBookmark'), isTrue);
    await screenshot(tester, 'bookshelf-removed-progress-kept');
    await click(tester, find.descendant(of: find.byType(NavigationRail),
        matching: find.byIcon(Icons.settings_outlined)));
    await click(tester, find.byTooltip('全部设置'));
    await category(tester, 'AI 作品关联');
    await visible(tester, find.text('API Token'));
    expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '启用 AI 作品关联')).value, false);
    await screenshot(tester, 'ai-association-settings');
    await category(tester, '同步设置');
    await text(tester, '设置 WebDAV');
    await text(tester, '连接你的云盘');
    for (final entry in {
      '服务器地址': 'http://127.0.0.1:8765/dav',
      '用户名': 'fixture',
      '密码或应用授权码': 'fixture',
    }.entries) {
      final field = find.byWidgetPredicate((widget) => widget is TextField &&
          widget.decoration?.labelText == entry.key);
      await visible(tester, field);
      await tester.ensureVisible(field);
      await tester.pump(const Duration(milliseconds: 200));
      await type(tester, field, entry.value);
    }
    await text(tester, '保存并测试');
    await visible(tester, find.text('连接成功，配置已保存'));
    await text(tester, '返回同步设置');
    await text(tester, '启用 WebDAV');
    await text(tester, '小说阅读进度与书签');
    await visible(tester, find.text('已启用小说手动同步'));
    await text(tester, '立即同步小说');
    await visible(tester, find.text('小说阅读进度与书签已同步'));
    final davHttp = HttpClient();
    try {
      final request = await davHttp.getUrl(Uri.parse('http://127.0.0.1:8765/fixture-state'));
      final response = await request.close();
      expect(response.statusCode, 200);
      final fixture = jsonDecode(await utf8.decoder.bind(response).join()) as Map<String, dynamic>;
      final files = fixture['files'] as Map<String, dynamic>;
      final heads = files.keys.where((name) => RegExp(
          r'^/dav/kazumiSync/novels/[0-9a-f]{32}-[0-9a-f]{64}\.json$').hasMatch(name));
      expect(heads, hasLength(1));
      expect(files.keys.any((name) => name.contains('/v1/')), isFalse);
      expect(jsonDecode(files[heads.single] as String), jsonDecode(novels.state.encode()));
    } finally {
      davHttp.close(force: true);
    }
    await screenshot(tester, 'webdav-novel-sync');
    final updateRequests = <String>[];
    final updater = DioFactory.downloadDio;
    const zipName = 'Kazumis-book-Windows-999.0.0.zip';
    final release = InterceptorsWrapper(onRequest: (options, handler) {
      updateRequests.add(options.uri.toString());
      if (options.uri.toString() == ApiEndpoints.latestApp) {
        handler.resolve(Response<String>(requestOptions: options, statusCode: 200,
          data: jsonEncode({
            'tag_name': '999.0.0', 'body': 'Owned Windows update fixture',
            'html_url': '${ApiEndpoints.sourceUrl}/releases/tag/999.0.0',
            'published_at': '2026-10-17T00:00:00Z',
            'assets': [{
              'name': zipName,
              'browser_download_url': 'http://127.0.0.1:8765/$zipName',
              'digest': 'sha256:${List.filled(64, '0').join()}',
            }],
          })));
      } else {
        handler.next(options);
      }
    });
    updater.interceptors.add(release);
    try {
      await category(tester, '关于');
      await text(tester, '检查更新');
      await visible(tester, find.byType(UpdateAvailableDialog));
      final update = tester.widget<UpdateAvailableDialog>(find.byType(UpdateAvailableDialog)).updateInfo;
      expect(update.availableInstallationTypes, [InstallationType.windowsPortable]);
      expect(update.recommendedInstallationType, InstallationType.windowsPortable);
      expect(getUpdateAssetForType(update.assets, update.recommendedInstallationType)?['name'], zipName);
      await screenshot(tester, 'windows-zip-update');
      await text(tester, '稍后');
      expect(find.byType(UpdateAvailableDialog), findsNothing);
      expect(updateRequests, [ApiEndpoints.latestApp]);
    } finally {
      updater.interceptors.remove(release);
    }
    await category(tester, '规则管理', delta: -200);
    final http = HttpClient();
    final request = await http.getUrl(Uri.parse('http://127.0.0.1:8765/video-rule.json'));
    final response = await request.close();
    expect(response.statusCode, 200);
    final ruleJson = await utf8.decoder.bind(response).join();
    http.close();
    await Clipboard.setData(ClipboardData(text: ruleJson));
    await text(tester, '添加规则');
    await text(tester, '从剪贴板导入');
    await text(tester, '导入规则');
    await visible(tester, find.text('Fixture Video'));
    for (var step = 0; step < 3 && find.byType(SettingsPage).evaluate().isNotEmpty; step++) {
      await back(tester);
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.byType(SettingsPage), findsNothing);
    await click(tester, find.descendant(of: find.byType(NavigationRail),
        matching: find.byIcon(Icons.home_outlined)));
    await click(tester, find.byTooltip('搜索'));
    await type(tester, find.byType(TextField).first, 'Frieren');
    await click(tester, find.byTooltip('搜索'));
    await visible(tester, find.textContaining('芙莉莲'),
        timeout: const Duration(seconds: 15));
    await screenshot(tester, 'anime-search');
    await text(tester, '葬送的芙莉莲');
    await text(tester, '吐槽');
    await visible(tester, find.byWidgetPredicate((widget) => widget is Semantics &&
        widget.properties.identifier == 'bangumi-comment'),
        timeout: const Duration(seconds: 15));
    await screenshot(tester, 'anime-comments');
    await text(tester, '开始观看');
    await visible(tester, find.text('Fixture Video'));
    await text(tester, '葬送的芙莉莲');
    await visible(tester, find.byType(VideoPage));
    final video = tester.widget<VideoPage>(find.byType(VideoPage));
    final player = video.playerController;
    // A fresh Windows runner creates WebView2 before it can request the source.
    // Measure that loading phase separately from actual native playback.
    final sourceStartup = Stopwatch()..start();
    await until(tester, () => !video.videoPageController.loading,
        'Windows WebView must finish resolving the video source',
        timeout: const Duration(seconds: 20));
    expect(video.videoPageController.errorMessage, isNull);
    debugPrintSynchronously('NATIVE_VIDEO_SOURCE_READY_MS: ${sourceStartup.elapsedMilliseconds}');
    await until(tester, () => player.playback.playing &&
        player.playback.currentPosition > const Duration(seconds: 1),
        'Native Windows media must actually play the owned video',
        timeout: const Duration(seconds: 10));
    await until(tester, () => find.byType(SnackBar).evaluate().isEmpty,
        'The initial player status message must leave the controls',
        timeout: const Duration(seconds: 3));
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(() => mouse.removePointer());
    await mouse.moveTo(tester.getCenter(find.byType(PlayerItem)));
    await until(tester, () => find.byTooltip('暂停').hitTestable().evaluate().isNotEmpty,
        'Desktop hover must expose the pause control');
    await mouse.moveTo(tester.getCenter(find.byTooltip('暂停')));
    await tester.pump(const Duration(milliseconds: 100));
    await screenshot(tester, 'video-playing');
    await click(tester, find.byTooltip('暂停'));
    await until(tester, () => !player.playback.playing, 'Pause must stop native playback');
    await screenshot(tester, 'video-paused');
    await click(tester, find.byTooltip('播放'));
    await until(tester, () => player.playback.playing, 'Play must resume native playback');
    await click(tester, find.byTooltip('下一集'));
    await until(tester, () => video.videoPageController.playingEpisode?.episode == 2 &&
        player.playback.playing && player.playback.currentPosition > const Duration(seconds: 1),
        'Next episode must load and actually play episode two',
        timeout: const Duration(seconds: 10));
    await screenshot(tester, 'video-second-episode');
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 8)));
}
