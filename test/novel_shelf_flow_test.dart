import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
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
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async => ResponseBody.fromString(
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
  @override
  void close({bool force = false}) {}
}

class _CollectRepository extends CollectCrudRepository {
  bool fail = false;
  Completer<void> attempt = Completer<void>();
  @override
  Future<void> addCollectible(BangumiItem item, int type) async {
    if (!attempt.isCompleted) attempt.complete();
    if (fail) throw StateError('fixture collect write failed');
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
  Future<void> ensureDefaultRules() async {}
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
  Future<void> syncAutomatically() async {}
}

Future<void> _start(
  WidgetTester tester,
  _Service service,
  CollectController collect,
) async {
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
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                NovelEntry.read(context, service, 'edition', animeId: 42),
            child: const Text('打开小说'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开小说'));
  await tester.pumpAndSettle();
  await tester.tapAt(const Offset(400, 300));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('下一章'));
  await tester.pumpAndSettle();
}

Future<void> _accept(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
  expect(find.text('加入书架？'), findsOneWidget);
  await tester.tap(find.text('加入书架'));
}

Future<void> _finishWrites(WidgetTester tester, Completer<void> attempt) async {
  for (var i = 0; i < 100 && !attempt.isCompleted; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(
    attempt.isCompleted,
    true,
    reason: 'Expected storage operation; visible text: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(" / ")}',
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  setUpAll(() async {
    paths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('book-shelf-flow-');
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
  });
  setUp(() async {
    await GStorage.collectibles.clear();
    await GStorage.collectChanges.clear();
    DioFactory.bangumiDio.httpClientAdapter = _AnimeAdapter();
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
  testWidgets(
    'accepting the exit offer saves official watching collection then shelf',
    (tester) async {
      final service = _Service();
      final repo = _CollectRepository();
      await _start(tester, service, CollectController(repo));
      await _accept(tester);
      await _finishWrites(tester, service.shelfAttempt);
      expect(repo.getCollectType(42), 1);
      expect(GStorage.collectChanges.values.single.bangumiID, 42);
      expect(service.shelved, true);
      expect(service.shelfAnimeId, 42);
      expect(find.byType(NovelReaderPage), findsNothing);
    },
  );
  testWidgets(
    'collect write failure keeps the reader and shelf unchanged, then retries',
    (tester) async {
      final service = _Service();
      final repo = _CollectRepository()..fail = true;
      await _start(tester, service, CollectController(repo));
      await _accept(tester);
      await _finishWrites(tester, repo.attempt);
      expect(service.shelved, false);
      expect(repo.getCollectType(42), 0);
      expect(find.byType(NovelReaderPage), findsOneWidget);
      expect(
        find.textContaining('fixture collect write failed'),
        findsOneWidget,
      );
      repo.fail = false;
      await _accept(tester);
      await _finishWrites(tester, service.shelfAttempt);
      expect(repo.getCollectType(42), 1);
      expect(service.shelved, true);
    },
  );
  testWidgets(
    'shelf write failure keeps reading progress and allows exit retry',
    (tester) async {
      final service = _Service()..failShelf = true;
      final repo = _CollectRepository();
      await _start(tester, service, CollectController(repo));
      await _accept(tester);
      await _finishWrites(tester, service.shelfAttempt);
      expect(repo.getCollectType(42), 1);
      expect(service.shelved, false);
      expect(service.saved!.chapter.url, _chapters[1].url);
      expect(find.byType(NovelReaderPage), findsOneWidget);
      expect(find.textContaining('fixture shelf write failed'), findsOneWidget);
      service.failShelf = false;
      service.shelfAttempt = Completer<void>();
      await _accept(tester);
      await _finishWrites(tester, service.shelfAttempt);
      expect(service.shelved, true);
      expect(find.byType(NovelReaderPage), findsNothing);
    },
  );
}
