import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:kazumi/bean/settings/theme_provider.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/pages/settings/sync/webdav_sync_page.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/danmaku_shield_sync_service.dart';
import 'package:kazumi/services/sync/webdav.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override Future<String?> getApplicationSupportPath() async => path;
}
class _Shield extends Fake implements DanmakuShieldSyncService {}
class _Novels extends NovelService {
  _Novels() : super(WebDav());
  int calls = 0;
  bool fail = false;
  Completer<void>? pending;
  @override Future<void> sync() async {
    calls++;
    if (pending != null) await pending!.future;
    if (fail) throw StateError('fixture WebDAV unavailable');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  setUpAll(() async {
    paths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('novel-manual-sync-');
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
  });
  setUp(() async {
    await GStorage.putSetting(SettingsKeys.webDavURL, 'https://dav.test/books/');
    await GStorage.putSetting(SettingsKeys.webDavEnable, true);
    await GStorage.putSetting(SettingsKeys.webDavEnableNovels, false);
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    await root.delete(recursive: true);
  });

  testWidgets('novel sync setting enables manual actions, with busy, success, notice, error and retry states', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final novels = _Novels();
    final module = createModule(register: (c) {
      c.addSingleton<NovelService>(() => novels);
      c.route('/', child: (_, _) => WebDavSyncPage(danmakuShieldSync: _Shield()));
    });
    await tester.pumpWidget(ModularApp(module: module, initialRoute: '/',
      provide: (scope) => scope.addChangeNotifier<ThemeProvider>(ThemeProvider.new),
      child: Builder(builder: (context) => MaterialApp.router(routerConfig: ModularApp.routerConfigOf(context)))));
    await tester.pumpAndSettle();
    Future<void> tap(String label) async {
      final target = find.text(label);
      await tester.ensureVisible(target);
      await tester.pump();
      // Settings use real Hive IO; their write futures must run on the real event loop.
      await tester.runAsync(() async {
        await tester.tap(target);
        await Hive.box<dynamic>('setting').flush();
      });
      await tester.pump(const Duration(milliseconds: 250));
    }
    Future<void> feedback(String message) async {
      await tester.scrollUntilVisible(find.text(message), 200,
        scrollable: find.byType(Scrollable).first);
      expect(find.text(message), findsOneWidget);
    }
    await tap('立即同步小说');
    expect(novels.calls, 0);
    await tap('小说阅读进度与书签');
    expect(GStorage.getSetting(SettingsKeys.webDavEnableNovels), isTrue);
    expect(novels.calls, 0);
    await feedback('已启用小说手动同步');
    novels.pending = Completer<void>();
    await tap('立即同步小说');
    await tap('立即同步小说');
    expect(novels.calls, 1);
    novels.pending!.complete();
    await tester.pumpAndSettle();
    await feedback('小说阅读进度与书签已同步');
    novels.pending = null;
    novels.syncNotice = '旧版数据已合并';
    await tap('立即同步小说');
    await feedback('小说阅读进度与书签已同步。旧版数据已合并');
    novels.fail = true;
    await tap('立即同步小说');
    await feedback('未能完成，请检查网络或服务器配置后重试。');
    novels.fail = false;
    novels.syncNotice = null;
    await tap('立即同步小说');
    await feedback('小说阅读进度与书签已同步');
    await tap('小说阅读进度与书签');
    expect(GStorage.getSetting(SettingsKeys.webDavEnableNovels), isFalse);
    await feedback('小说同步已关闭');
    await tap('立即同步小说');
    expect(novels.calls, 4);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Hive.box<dynamic>('setting').flush());
    expect(tester.takeException(), isNull);
  });
}
