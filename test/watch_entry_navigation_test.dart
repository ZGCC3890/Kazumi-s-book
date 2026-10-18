import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_rule.dart';
import 'package:kazumi/novel/novel_search_results.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/info/source_sheet.dart';
import 'package:kazumi/pages/info/watch_entry.dart';
import 'package:kazumi/pages/menu/menu.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Novels extends NovelService {
  _Novels(this.anime) : super(WebDav());
  final BangumiItem anime;
  @override
  List<NovelRule> get rules => [NovelRule.decode(File('novel_rules/linovel.json').readAsStringSync())];
  @override
  Future<List<BangumiItem>> relatedAnime(NovelBook book, {String? editionId, bool refresh = false}) async => [anime];
}

// Only the external source query is controlled. WatchEntry, SourceSheet,
// PluginSearchService and the menu's nested RouterOutlet are production code.
class _Source extends Plugin {
  _Source()
      : super(
          api: '1', type: 'anime', name: '受控视频源', version: '1',
          muliSources: true, useWebview: false, useNativePlayer: true,
          usePost: false, useLegacyParser: false, adBlocker: false,
          userAgent: '', baseUrl: 'https://example.invalid',
          searchURL: '', searchList: '', searchName: '', searchResult: '',
          chapterRoads: '', chapterResult: '', referer: '',
        );
  final queries = <String>[];
  @override
  Future<PluginSearchResponse> queryBangumi(String keyword,
      {bool shouldRethrow = false, RuleCancelToken? cancelToken}) async {
    queries.add(keyword);
    return PluginSearchResponse(pluginName: name, data: [
      SearchItem(name: '已找到的播放结果', src: 'https://example.invalid/anime'),
    ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  setUpAll(() async {
    paths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('watch-entry-nav-');
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    await root.delete(recursive: true);
  });

  for (final size in [const Size(480, 900), const Size(1280, 900)]) {
    for (final novelCard in [false, true]) {
    testWidgets('quick playback source system back preserves collection at $size (novel: $novelCard)',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final source = _Source();
      final plugins = PluginsController()..pluginList.add(source);
      final item = BangumiItem.fromJson({
        'id': 42, 'type': 2, 'name': 'Test anime', 'name_cn': '测试番剧',
        'rating': {'rank': 1, 'score': 8.0, 'total': 1},
        'images': <String, String>{},
      });
      final novels = _Novels(item);
      addTearDown(novels.dispose);
      final action = novelCard ? '看番' : '快速播放';
      final module = createModule(register: (c) {
        c.addSingleton<PluginsController>(() => plugins);
        c.addSingleton<CollectController>(
            () => CollectController(CollectCrudRepository()));
        c.route('/tab/',
            child: (context, state) => ScaffoldMenu(location: state.uri.path),
            children: (sub) {
          for (final name in ['popular', 'timeline', 'my']) {
            sub.route('/$name/',
                child: (_, _) => Center(child: Text('page:$name')));
          }
          sub.route('/collect/', child: (context, _) => Column(children: [
            const Text('collection host'),
            if (novelCard) Expanded(child: ListView(children: [
              NovelSearchGrid(service: novels,
                books: const [NovelBook(sourceId: 'linovel', url: 'https://test/book', title: '关联小说')],
                onRead: (_) => fail('看番 must not open the reader')),
            ])) else
            TextButton(
              onPressed: () => WatchEntry.open(context, item),
              child: const Text('快速播放'),
            ),
          ]));
        });
      });
      await tester.pumpWidget(ModularApp(
        module: module,
        initialRoute: '/tab/collect/',
        navigatorKey: rootNavigatorKey,
        navigatorObservers: [rootRouteObserver],
        child: Builder(builder: (context) => MaterialApp.router(
          scaffoldMessengerKey: rootScaffoldMessengerKey,
          routerConfig: ModularApp.routerConfigOf(context),
        )),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.byType(SourceSheet), findsOneWidget);
      expect(find.text('已找到的播放结果'), findsOneWidget);
      expect(source.queries, ['测试番剧']);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SourceSheet), findsNothing);
      expect(find.text('page:popular'), findsNothing);
      expect(find.text('collection host'), findsOneWidget);
      if (size.width < size.height) {
        expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 2);
      } else {
        expect(tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex, 2);
      }
      // The underlying collection route remains usable after closing the sheet.
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.byType(SourceSheet), findsOneWidget);
      expect(source.queries, ['测试番剧', '测试番剧']);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('collection host'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, timeout: const Timeout(Duration(seconds: 45)));
    }
  }
}
