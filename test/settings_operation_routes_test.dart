import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/theme_provider.dart';
import 'package:kazumi/core_module.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/about/about_page.dart';
import 'package:kazumi/pages/logs/logs_page.dart';
import 'package:kazumi/pages/settings/danmaku/danmaku_settings.dart';
import 'package:kazumi/pages/settings/decoder_settings.dart';
import 'package:kazumi/pages/settings/download_settings.dart';
import 'package:kazumi/pages/settings/interface_settings.dart';
import 'package:kazumi/pages/settings/keyboard_settings.dart';
import 'package:kazumi/pages/settings/player_settings.dart';
import 'package:kazumi/pages/settings/proxy/proxy_editor_page.dart';
import 'package:kazumi/pages/settings/proxy/proxy_settings_page.dart';
import 'package:kazumi/pages/settings/settings_module.dart';
import 'package:kazumi/pages/settings/settings_page.dart';
import 'package:kazumi/pages/settings/storage_settings.dart';
import 'package:kazumi/pages/settings/sync/bangumi_sync_page.dart';
import 'package:kazumi/pages/settings/sync/webdav_server_page.dart';
import 'package:kazumi/pages/settings/sync/webdav_sync_page.dart';
import 'package:kazumi/pages/settings/theme_settings_page.dart';
import 'package:kazumi/pages/settings/update_settings.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/bean/dialog/update_available_dialog.dart';

class _ReleaseResponse implements HttpClientAdapter {
  _ReleaseResponse(this.status, this.version);
  final int status;
  final String version;
  final requests = <Uri>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options.uri);
    return ResponseBody.fromString(jsonEncode({
      'tag_name': version,
      'body': 'Owned update fixture',
      'html_url': 'https://github.com/ZGCC3890/Kazumi-s-book/releases/tag/$version',
      'published_at': '2026-10-17T00:00:00Z',
      'assets': <dynamic>[],
    }), status, headers: {Headers.contentTypeHeader: ['application/json']});
  }
  @override
  void close({bool force = false}) {}
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getDownloadsPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

// Only the launching host is a fixture. Every settings route, controller,
// root service registration and the scoped ThemeProvider are production ones.
Future<void> _open(WidgetTester tester, {bool wide = false}) async {
  tester.view.physicalSize = wide ? const Size(1280, 900) : const Size(480, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Hive.box<dynamic>('setting').flush());
  });
  final module = createModule(register: (c) {
    c.module(coreModule);
    c.module(settingsModule);
    c.route('/', child: (context, state) => Scaffold(
      body: Center(child: FilledButton(
        onPressed: () => context.pushNamed('/settings/'),
        child: const Text('打开设置入口'),
      )),
    ));
  });
  await tester.pumpWidget(ModularApp(
    module: module,
    initialRoute: '/',
    navigatorKey: rootNavigatorKey,
    navigatorObservers: [KazumiDialog.observer, rootRouteObserver],
    provide: (scope) => scope.addChangeNotifier<ThemeProvider>(ThemeProvider.new),
    child: Builder(builder: (context) => MaterialApp.router(
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      routerConfig: ModularApp.routerConfigOf(context),
    )),
  ));
  await _settle(tester);
  await _tap(tester, '打开设置入口');
  expect(find.byType(SettingsPage), findsOneWidget);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  // File reads (logs/cache/download directory) need the real event loop;
  // this does not replace their results or swallow a widget exception.
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
  await tester.pumpAndSettle(const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
  expect(tester.takeException(), isNull);
}

Future<void> _tap(WidgetTester tester, String text) async {
  final target = find.text(text).last;
  await tester.ensureVisible(target);
  await _settle(tester);
  // Click-created Hive writes must not belong to a disposed FakeAsync zone.
  await tester.runAsync(() => tester.tap(target));
  await _settle(tester);
}

Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton).last);
  await _settle(tester);
}

Finder _field(String label) => find.byWidgetPredicate((widget) =>
    widget is TextField && widget.decoration?.labelText == label);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previousPaths;
  setUpAll(() async {
    previousPaths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('book-settings-routes-');
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
    final logs = Directory('${root.path}/logs');
    await logs.create();
    await File('${logs.path}/kazumi_logs.log').writeAsString('settings-route-log-sentinel\n');
  });
  setUp(() async {
    await GStorage.putSetting(SettingsKeys.webDavURL, '');
    await GStorage.putSetting(SettingsKeys.webDavEnable, false);
    await GStorage.putSetting(SettingsKeys.webDavEnableNovels, false);
    await GStorage.putSetting(SettingsKeys.webDavEnableHistory, false);
    await GStorage.putSetting(SettingsKeys.webDavEnableCollect, false);
    await GStorage.putSetting(SettingsKeys.webDavEnableDanmakuShield, false);
    await GStorage.putSetting(SettingsKeys.bangumiAccessToken, '');
    await GStorage.putSetting(SettingsKeys.proxyUrl, '');
    await GStorage.putSetting(SettingsKeys.autoUpdate, false);
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = previousPaths;
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    expect(root.uri.pathSegments.where((p) => p.isNotEmpty).last,
        startsWith('book-settings-routes-'));
    await root.delete(recursive: true);
  });

  final categories = <String, Type>{
    '播放设置': PlayerSettingsPage,
    '弹幕设置': DanmakuSettingsPage,
    '操作设置': KeyboardSettingsPage,
    '下载设置': DownloadSettingsPage,
    '外观设置': ThemeSettingsPage,
    '界面设置': InterfaceSettingsPage,
    '网络设置': ProxySettingsPage,
    '更新设置': UpdateSettingsPage,
    '存储与日志': StorageSettingsPage,
    '关于': AboutPage,
  };
  for (final category in categories.entries) {
    testWidgets('production settings entry opens ${category.key} and returns', (tester) async {
      await _open(tester);
      await _tap(tester, category.key);
      expect(find.byType(category.value), findsOneWidget);
      await _back(tester);
      expect(find.byType(SettingsIndexPage), findsOneWidget);
      expect(find.byType(category.value), findsNothing);
    }, timeout: const Timeout(Duration(seconds: 45)));
  }

  testWidgets('production player route opens decoder and returns to player', (tester) async {
    await _open(tester);
    await _tap(tester, '播放设置');
    await _tap(tester, '硬件解码器');
    expect(find.byType(DecoderSettings), findsOneWidget);
    await _back(tester);
    expect(find.byType(PlayerSettingsPage), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('production sync routes reach Bangumi and WebDAV editor without connecting', (tester) async {
    await _open(tester);
    await _tap(tester, '同步设置');
    await _tap(tester, '连接 Bangumi');
    expect(find.byType(BangumiSyncPage), findsOneWidget);
    await _back(tester);
    await _tap(tester, '设置 WebDAV');
    expect(find.byType(WebDavSyncPage), findsOneWidget);
    await _tap(tester, '连接你的云盘');
    expect(find.byType(WebDavServerPage), findsOneWidget);
    await tester.enterText(_field('服务器地址'), 'invalid-address');
    await _tap(tester, '保存并测试');
    expect(find.text('请输入完整的 http:// 或 https:// 地址'), findsOneWidget);
    expect(GStorage.getSetting(SettingsKeys.webDavURL), isEmpty);
    await tester.enterText(_field('服务器地址'), 'https://example.invalid/dav');
    await _back(tester);
    expect(find.byType(WebDavSyncPage), findsOneWidget);
    expect(GStorage.getSetting(SettingsKeys.webDavURL), isEmpty,
        reason: 'Leaving an unsubmitted editor must not save credentials.');
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('production proxy editor validates input and discards unsubmitted edits', (tester) async {
    await _open(tester);
    await _tap(tester, '网络设置');
    await _tap(tester, '代理配置');
    expect(find.byType(ProxyEditorPage), findsOneWidget);
    await tester.enterText(_field('代理地址'), 'invalid');
    await _tap(tester, '保存并测试');
    expect(find.text('格式错误，请使用 http://host:port 格式'), findsOneWidget);
    await tester.enterText(_field('代理地址'), 'http://127.0.0.1:7890');
    await _back(tester);
    expect(find.byType(ProxySettingsPage), findsOneWidget);
    expect(GStorage.getSetting(SettingsKeys.proxyUrl), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('production update toggle persists through route reentry', (tester) async {
    await _open(tester);
    await _tap(tester, '更新设置');
    await _tap(tester, '应用更新');
    await tester.runAsync(() => Hive.box<dynamic>('setting').flush());
    expect(GStorage.getSetting(SettingsKeys.autoUpdate), isTrue);
    await _back(tester);
    await _tap(tester, '更新设置');
    expect(tester.widgetList<Switch>(find.byType(Switch)).first.value, isTrue);
  }, timeout: const Timeout(Duration(seconds: 45)));

  for (final response in [
    (200, ApiEndpoints.version, '当前已经是最新版本！'),
    (404, '0.0.0', "Kazumi's book 仓库尚未发布正式版本"),
    (500, '0.0.0', '检查更新失败'),
  ]) {
    testWidgets('production about update reports HTTP ${response.$1} as ${response.$3}', (tester) async {
      final adapter = _ReleaseResponse(response.$1, response.$2);
      DioFactory.downloadDio.httpClientAdapter = adapter;
      addTearDown(DioFactory.reset);
      await _open(tester);
      await _tap(tester, '关于');
      await _tap(tester, '检查更新');
      expect(find.text(response.$3), findsOneWidget);
      expect(find.byType(UpdateAvailableDialog), findsNothing);
      expect(adapter.requests.map((uri) => uri.toString()), [
        'https://api.github.com/repos/ZGCC3890/Kazumi-s-book/releases/latest',
      ]);
    }, timeout: const Timeout(Duration(seconds: 45)));
  }

  testWidgets('production about update can defer a new release without downloading', (tester) async {
    final adapter = _ReleaseResponse(200, '999.0.0');
    DioFactory.downloadDio.httpClientAdapter = adapter;
    addTearDown(DioFactory.reset);
    await _open(tester);
    await _tap(tester, '关于');
    await _tap(tester, '检查更新');
    expect(find.byType(UpdateAvailableDialog), findsOneWidget);
    expect(find.textContaining('999.0.0'), findsWidgets);
    await _tap(tester, '稍后');
    expect(find.byType(UpdateAvailableDialog), findsNothing);
    expect(find.text('检查更新'), findsOneWidget);
    expect(adapter.requests, hasLength(1), reason: 'Deferring must never download an installer.');
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('production sync summary recognizes novels alone and disabling does not change other content', (tester) async {
    await tester.runAsync(() async {
      await GStorage.putSetting(SettingsKeys.webDavURL, 'https://example.invalid/dav');
      await GStorage.putSetting(SettingsKeys.webDavEnable, true);
      await GStorage.putSetting(SettingsKeys.webDavEnableNovels, true);
    });
    await _open(tester);
    await _tap(tester, '同步设置');
    expect(find.text('已开启'), findsOneWidget);
    expect(find.text('待选择内容'), findsNothing);
    await _tap(tester, '管理多设备同步');
    await _tap(tester, '小说阅读进度与书签');
    expect(find.text('小说同步已关闭'), findsOneWidget);
    expect(GStorage.getSetting(SettingsKeys.webDavEnableNovels), isFalse);
    expect(GStorage.getSetting(SettingsKeys.webDavEnable), isTrue);
    expect(GStorage.getSetting(SettingsKeys.webDavEnableHistory), isFalse);
    expect(GStorage.getSetting(SettingsKeys.webDavEnableCollect), isFalse);
    expect(GStorage.getSetting(SettingsKeys.webDavEnableDanmakuShield), isFalse);
    await _back(tester);
    expect(find.text('待选择内容'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('production about license route covers shell and returns to about', (tester) async {
    await _open(tester);
    await _tap(tester, '关于');
    await _tap(tester, '第三方许可证');
    expect(find.byType(LicensePage), findsOneWidget);
    await _back(tester);
    expect(find.byType(AboutPage), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('production storage route reads the actual temporary log file', (tester) async {
    await _open(tester);
    await _tap(tester, '存储与日志');
    await tester.runAsync(() => tester.tap(find.text('错误日志')));
    await tester.pump(const Duration(milliseconds: 300));
    final content = find.textContaining('settings-route-log-sentinel');
    // Path lookup, exists and readAsString are separate real I/O turns.
    // Advancing only the fake animation clock starves later file reads.
    for (var turn = 0; turn < 100 && content.evaluate().isEmpty; turn++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(LogsPage), findsOneWidget);
    expect(content, findsWidgets);
    expect(tester.takeException(), isNull);
    await _back(tester);
    expect(find.byType(StorageSettingsPage), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 45)));

  testWidgets('tablet settings keeps its shell through nested proxy return and category switch', (tester) async {
    await _open(tester, wide: true);
    await _tap(tester, '网络设置');
    await _tap(tester, '代理配置');
    expect(find.byType(ProxyEditorPage), findsOneWidget);
    // The wide shell has its own exit button as well as the editor's back
    // button. Test the leaf control, rather than the outer shell's exit.
    final editorBack = find.descendant(of: find.byType(ProxyEditorPage),
        matching: find.byType(BackButton));
    expect(editorBack, findsOneWidget);
    await tester.tap(editorBack);
    await _settle(tester);
    expect(find.byType(ProxySettingsPage), findsOneWidget);
    await _tap(tester, '外观设置');
    expect(find.byType(ThemeSettingsPage), findsOneWidget);
    expect(find.byType(SettingsPage), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 45)));
}
