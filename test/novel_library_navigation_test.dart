import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/novel/novel_book_cover.dart';
import 'package:kazumi/novel/novel_library_page.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/pages/menu/menu.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _book = NovelBook(
  sourceId: 'source-a',
  url: 'https://source/book/1',
  title: '已入架的小说',
  cover: 'https://source/covers/1.png',
);

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Library extends NovelService {
  _Library(this.bytes) : super(WebDav());
  final Uint8List bytes;
  final images = <(String, String)>[];
  @override
  List<NovelEdition> get shelfEditions => [
    const NovelEdition('e', 'w', '中文', 'zh'),
  ];
  @override
  NovelWork work(String id) => const NovelWork('w', '已入架的小说', '作者');
  @override
  NovelBook? selectedBook(String id) => _book;
  @override
  Future<Uint8List> image(String source, String url) async {
    images.add((source, url));
    return bytes;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  late Uint8List cover;
  setUpAll(() async {
    final image = await createTestImage(width: 8, height: 8);
    cover = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    paths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('book-library-nav-');
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
    testWidgets(
      'bookshelf is the next peer after anime tracking at $size and displays source cover',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        final service = _Library(cover);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          service.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final module = createModule(
          register: (c) {
            c.route(
              '/tab/',
              child: (context, state) => ScaffoldMenu(location: state.uri.path),
              children: (sub) {
                for (final name in ['popular', 'timeline', 'collect', 'my']) {
                  sub.route(
                    '/$name/',
                    child: (_, _) => Center(child: Text('page:$name')),
                  );
                }
                sub.route(
                  '/novels/',
                  child: (_, _) => NovelLibraryPage(service: service),
                );
              },
            );
          },
        );
        await tester.pumpWidget(
          ModularApp(
            module: module,
            initialRoute: '/tab/collect/',
            child: Builder(
              builder: (context) => MaterialApp.router(
                routerConfig: ModularApp.routerConfigOf(context),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('page:collect'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.menu_book_outlined));
        await tester.pumpAndSettle();
        expect(find.byType(NovelLibraryPage), findsOneWidget);
        expect(find.text('已入架的小说'), findsOneWidget);
        expect(service.images, [('source-a', 'https://source/covers/1.png')]);
        expect(find.byType(Image), findsOneWidget);
        if (size.width < size.height) {
          final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
          expect(nav.selectedIndex, 3);
          expect((nav.destinations[2] as NavigationDestination).label, '追番');
          expect((nav.destinations[3] as NavigationDestination).label, '书架');
        } else {
          final nav = tester.widget<NavigationRail>(
            find.byType(NavigationRail),
          );
          expect(nav.selectedIndex, 3);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('source cover is retained across unrelated library rebuilds', (
    tester,
  ) async {
    final service = _Library(cover);
    addTearDown(service.dispose);
    for (var i = 0; i < 2; i++) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NovelBookCover(service: service, book: _book),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }
    expect(service.images, hasLength(1));
    expect(find.bySemanticsLabel('已入架的小说封面'), findsOneWidget);
  });
}
