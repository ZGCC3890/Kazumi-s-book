import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/novel/novel_entry.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_reader_page.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _book = NovelBook(
  sourceId: 'fixture',
  url: 'https://test/book',
  title: '测试小说',
);
const _chapters = [
  NovelChapter(url: 'https://test/1', title: '第一章', volume: '第一卷', kind: '正文'),
  NovelChapter(url: 'https://test/2', title: '第二章', volume: '第一卷', kind: '正文'),
];

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _AnimeAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
    jsonEncode({
      'id': 42,
      'name': '测试番剧',
      'name_cn': '测试番剧',
      'rating': {'rank': 1, 'total': 1, 'score': 8.0},
      'images': <String, String>{},
    }),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
    );
  }
  @override
  void close({bool force = false}) {}
}

class _CollectRepository extends CollectCrudRepository {
  int writes = 0;
  @override
  Future<void> addCollectible(BangumiItem item, int type) async {
    writes++;
    await super.addCollectible(item, type);
  }
}

class _Service extends NovelService {
  _Service() : super(WebDav());
  bool shelved = false, failShelf = false;
  int? shelfAnimeId;
  NovelPosition? saved;
  final read = <String>{};
  Completer<void> shelfAttempt = Completer<void>();
  @override
  NovelBook? selectedBook(String editionId) => _book;
  @override
  Future<void> ensureDefaultRules() async =>
      throw StateError('Existing books must not depend on default rule installation');
  @override
  bool isShelved(String editionId) => shelved;
  @override
  List<int> animeIdsForEdition(String editionId) => [42];
  @override
  Future<int> recordReadChapters(String editionId, Set<String> chapters) async {
    read.addAll(chapters);
    return read.length;
  }

  @override
  Future<String> chapterReadIdentity(
    String editionId,
    NovelBook book,
    NovelChapter chapter,
    NovelPosition? restoredFrom,
  ) async => chapter.url;
  @override
  Future<void> addToShelf(String editionId, {int animeId = 0}) async {
    if (!shelfAttempt.isCompleted) shelfAttempt.complete();
    if (failShelf) throw StateError('fixture shelf write failed');
    shelved = true;
    shelfAnimeId = animeId;
  }

  @override
  NovelJson get preferences => {
    'fontSize': 20.0,
    'lineHeight': 1.8,
    'theme': 0,
    'mode': 'scroll',
    'font': 'system',
    'margin': 24.0,
    'brightness': 0.0,
  };
  @override
  NovelPosition? position(String editionId) => saved;
  @override
  Future<List<NovelChapter>> catalog(
    NovelBook book, {
    bool refresh = false,
  }) async => _chapters;
  @override
  Future<List<NovelBlock>> content(
    String source,
    NovelChapter chapter, {
    bool refresh = false,
  }) async => [NovelBlock.text('${chapter.title}的正文')];
  @override
  Future<void> savePosition(NovelPosition value) async {
    saved = value;
  }

  @override
  Future<void> retrySync() async {}
}

Future<void> _start(
  WidgetTester tester,
  _Service service,
  CollectController collect, {
  bool fromAnime = false,
  Size size = const Size(800, 600),
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final boot = bootstrapModule(
    createModule(
      register: (c) {
        c.addSingleton<CollectController>(() => collect);
      },
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
    boot.injector.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => fromAnime
                ? NovelEntry.open(context, BangumiItem.fromJson({
                    'id': 42, 'name': '测试番剧', 'name_cn': '测试番剧',
                    'rating': {'rank': 1, 'total': 1, 'score': 8.0},
                    'images': <String, String>{},
                  }), service)
                : NovelEntry.read(context, service, 'edition', animeId: 42),
            child: const Text('打开小说'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开小说'));
  await tester.pumpAndSettle();
  await tester.tapAt(size.center(Offset.zero));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('下一章'));
  await tester.pumpAndSettle();
}

Future<void> _accept(WidgetTester tester, Completer<void> completed) async {
  // Hive retains futures between tests. Start the entire leave/write chain in
  // the real async zone, including the dialog's result future.
  await tester.runAsync(() => tester.tap(find.byType(BackButton)));
  await tester.pumpAndSettle();
  expect(find.text('加入书架？'), findsOneWidget);
  await tester.runAsync(() async {
    await tester.tap(find.text('加入书架'));
    await completed.future;
  });
  await _settleLeave(tester);
}

Future<void> _settleLeave(WidgetTester tester) async {
  // The leave callback started in runAsync resumes there after the inset frame.
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.value());
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  late _AnimeAdapter animeAdapter;
  setUpAll(() async {
    paths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('book-shelf-flow-');
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
  });
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    await GStorage.collectibles.clear();
    await GStorage.collectChanges.clear();
    animeAdapter = _AnimeAdapter();
    DioFactory.bangumiDio.httpClientAdapter = animeAdapter;
  });
  tearDown(() {
    DioFactory.reset();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    await root.delete(recursive: true);
  });
  testWidgets('bound anime opens the selected source and resumes without searching', (tester) async {
    final (service, repo) = (await tester.runAsync(
      () async => (_Service(), _CollectRepository()),
    ))!;
    service.shelved = true;
    service.state = service.state.edit('anime/42', {
      'animeId': 42, 'editionIds': ['edition'], 'confirmed': true,
    }, 'test');
    await _start(tester, service, CollectController(repo), fromAnime: true);
    expect(find.byType(NovelSearchPage), findsNothing);
    expect(service.saved!.chapter.url, _chapters[1].url);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开小说'));
    await tester.pumpAndSettle();
    expect(find.byType(NovelReaderPage), findsOneWidget);
    expect(find.byType(NovelSearchPage), findsNothing);
    expect(find.text('第二章的正文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'accepting the exit offer shelves the novel without adding an anime collection',
    (tester) async {
      final (service, repo) = (await tester.runAsync(
        () async => (_Service(), _CollectRepository()),
      ))!;
      await _start(tester, service, CollectController(repo));
      await _accept(tester, service.shelfAttempt);
      expect(repo.getCollectType(42), 0);
      expect(repo.writes, 0);
      expect(GStorage.collectibles.isEmpty, true);
      expect(GStorage.collectChanges.isEmpty, true);
      expect(animeAdapter.requests, isEmpty);
      expect(service.shelved, true);
      expect(service.shelfAnimeId, 42);
      expect(find.byType(NovelReaderPage), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
  for (final size in [const Size(360, 800), const Size(1280, 800)]) {
    testWidgets('reader shelf button saves in place without changing anime status $size', (tester) async {
      final (service, repo) = (await tester.runAsync(
        () async => (_Service(), _CollectRepository()),
      ))!;
      await _start(tester, service, CollectController(repo), size: size, scale: 2);
      final position = service.saved!.toJson();
      final reader = tester.state(find.byType(NovelReaderPage));
      expect(find.byTooltip('加入书架').hitTestable(), findsOneWidget);
      expect(find.byTooltip('更换书源').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('加入书架'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('已在书架'), findsOneWidget);
      expect(tester.state(find.byType(NovelReaderPage)), same(reader));
      expect(service.saved!.toJson(), position);
      expect(service.shelfAnimeId, 42);
      expect(repo.writes, 0);
      expect(GStorage.collectibles, isEmpty);
      expect(animeAdapter.requests, isEmpty);
      await tester.runAsync(() => tester.tap(find.byType(BackButton)));
      await _settleLeave(tester);
      expect(find.text('加入书架？'), findsNothing);
      expect(find.byType(NovelReaderPage), findsNothing);
      expect(find.text('打开小说'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'declining the exit offer keeps progress without shelving or changing anime status',
    (tester) async {
      final (service, repo) = (await tester.runAsync(
        () async => (_Service(), _CollectRepository()),
      ))!;
      await _start(tester, service, CollectController(repo));
      await tester.runAsync(() => tester.tap(find.byType(BackButton)));
      await tester.pumpAndSettle();
      expect(find.text('加入书架？'), findsOneWidget);
      final saved = service.saved!.toJson();
      expect(service.saved!.chapter.url, _chapters[1].url);
      await tester.runAsync(() => tester.tap(find.text('暂不添加')));
      await _settleLeave(tester);
      expect(find.byType(NovelReaderPage), findsNothing);
      expect(find.text('打开小说'), findsOneWidget);
      expect(service.saved!.toJson(), saved);
      expect(service.shelved, false);
      expect(service.shelfAttempt.isCompleted, false);
      expect(repo.writes, 0);
      expect(GStorage.collectibles, isEmpty);
      expect(GStorage.collectChanges, isEmpty);
      expect(animeAdapter.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
  testWidgets(
    'shelving preserves an existing anime status and its sync change log',
    (tester) async {
      final (service, repo) = (await tester.runAsync(
        () async => (_Service(), _CollectRepository()),
      ))!;
      await tester.runAsync(() async {
        await repo.addCollectible(BangumiItem.fromJson({
          'id': 42, 'name': '测试番剧', 'name_cn': '测试番剧',
          'rating': {'rank': 1, 'score': 8.0, 'total': 1},
          'images': <String, String>{},
        }), 2);
        await GStorage.appendCollectChange(bangumiId: 42, action: 1, type: 2);
      });
      repo.writes = 0;
      final before = GStorage.collectibles.toMap();
      final changes = GStorage.collectChanges.values.map((e) => e.toString()).toList();
      await _start(tester, service, CollectController(repo));
      await _accept(tester, service.shelfAttempt);
      expect(repo.getCollectType(42), 2);
      expect(repo.writes, 0);
      expect(GStorage.collectibles.toMap(), before);
      expect(GStorage.collectChanges.values.map((e) => e.toString()).toList(), changes);
      expect(animeAdapter.requests, isEmpty);
      expect(service.shelved, true);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
  testWidgets(
    'shelf write failure keeps reading progress and allows exit retry',
    (tester) async {
      final (service, repo) = (await tester.runAsync(
        () async => (_Service()..failShelf = true, _CollectRepository()),
      ))!;
      await _start(tester, service, CollectController(repo));
      await _accept(tester, service.shelfAttempt);
      expect(repo.getCollectType(42), 0);
      expect(repo.writes, 0);
      expect(GStorage.collectChanges.isEmpty, true);
      expect(animeAdapter.requests, isEmpty);
      expect(service.shelved, false);
      expect(service.saved!.chapter.url, _chapters[1].url);
      expect(find.byType(NovelReaderPage), findsOneWidget);
      expect(find.textContaining('fixture shelf write failed'), findsOneWidget);
      service.failShelf = false;
      service.shelfAttempt = (await tester.runAsync(
        () async => Completer<void>(),
      ))!;
      await _accept(tester, service.shelfAttempt);
      expect(service.shelved, true);
      expect(find.byType(NovelReaderPage), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
