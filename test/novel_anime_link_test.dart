import 'dart:async';
import 'package:dio/dio.dart';
import 'package:kazumi/novel/novel_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/novel/novel_anime_link.dart';
import 'package:kazumi/novel/novel_anime_resolver.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/sync/webdav.dart';

const _book = NovelBook(sourceId: 'a', url: 'https://test/a', title: '测试作品');
BangumiItem _anime(
  int id,
  String title, {
  int type = 2,
  List<String> aliases = const [],
}) => BangumiItem.fromJson({
  'id': id,
  'type': type,
  'name': title,
  'name_cn': title,
  'date': '2026-01-01',
  'rating': {'rank': 1, 'score': 8.0, 'total': 1},
  'images': <String, String>{},
  'infobox': [
    {
      'key': '别名',
      'value': aliases.map((v) => {'v': v}).toList(),
    },
  ],
});

class _Service extends NovelService {
  _Service(this.items) : super(WebDav());
  final List<BangumiItem> items;
  @override NovelAiSettings get aiSettings => const NovelAiSettings(enabled: true, token: 'test-token');
  @override Future<List<String>> suggestTitles(String title, {required bool toAnime,
    NovelAiSettings? settings, CancelToken? cancelToken}) async => ['动画译名'];
  Object? aiError;
  List<BangumiItem> aiMatches = [];
  @override Future<List<BangumiItem>> animeForTitle(String title) async {
    expect(title, '动画译名');
    if (aiError != null) throw aiError!;
    return aiMatches;
  }
  bool fail = false;
  int requests = 0, binds = 0;
  Completer<List<BangumiItem>>? pending;
  bool onlyWhenBound = false;
  List<int> ids = [];
  void setIds(List<int> next) {
    ids = next;
    notifyListeners();
  }

  @override
  List<int> animeIdsForBook(NovelBook book, {String? editionId}) => ids;
  @override
  Future<List<BangumiItem>> relatedAnime(
    NovelBook book, {
    String? editionId,
    bool refresh = false,
  }) async {
    requests++;
    if (fail && !refresh) {
      throw StateError('fixture association request failed');
    }
    if (pending != null) return pending!.future;
    if (onlyWhenBound && ids.isEmpty) return [];
    return items;
  }

  @override
  Future<String> bind({
    required int animeId,
    required NovelBook book,
    required String editionLabel,
    required String language,
    String? existingEditionId,
    String? existingWorkId,
  }) async {
    binds++;
    return 'unexpected';
  }
}

Future<void> _open(
  WidgetTester tester,
  _Service service,
  VoidCallback onRead, {
  ValueNotifier<NovelBook>? selection,
  bool showAi = false,
}) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });
  final module = createModule(
    register: (c) {
      Widget row(NovelBook book) => ListTile(
        title: Text(book.title),
        onTap: onRead,
        trailing: NovelAnimeLink(service: service, book: book, showAi: showAi),
      );
      c.route(
        '/',
        child: (_, _) => Scaffold(
          body: selection == null
              ? row(_book)
              : ValueListenableBuilder<NovelBook>(
                  valueListenable: selection,
                  builder: (_, book, _) => row(book),
                ),
        ),
      );
      c.route(
        '/info/',
        child: (_, state) {
          final anime = state.arguments as BangumiItem;
          return Scaffold(body: Text('anime:${anime.id}:${anime.nameCn}'));
        },
      );
    },
  );
  await tester.pumpWidget(
    ModularApp(
      module: module,
      initialRoute: '/',
      child: Builder(
        builder: (context) => MaterialApp.router(
          routerConfig: ModularApp.routerConfigOf(context),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('AI novel association confirms a name and opens the searched anime', (tester) async {
    final service = _Service([])..aiMatches = [_anime(91, '动画译名')];
    await _open(tester, service, () {}, showAi: true);
    await tester.tap(find.byTooltip('AI 关联番剧'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('动画译名'));
    await tester.pumpAndSettle();
    expect(find.text('anime:91:动画译名'), findsOneWidget);
    expect(service.binds, 0);
  });
  testWidgets('AI cancellation, no anime results and search errors remain explicit', (tester) async {
    final service = _Service([]);
    await _open(tester, service, () {}, showAi: true);
    await tester.tap(find.byTooltip('AI 关联番剧'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('AI 关联番剧'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('动画译名'));
    await tester.pumpAndSettle();
    expect(find.text('没有搜索到这个名称的番剧'), findsOneWidget);
    service.aiError = StateError('fixture search failed');
    await tester.tap(find.byTooltip('AI 关联番剧'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('动画译名'));
    await tester.pumpAndSettle();
    expect(find.textContaining('fixture search failed'), findsOneWidget);
  });
  group('novel to anime resolution', () {
    test('published novel names match verified anime aliases but not other Kaguya works', () {
      final anime = _anime(248175, '辉夜大小姐想让我告白～天才们的恋爱头脑战～', aliases: [
        '辉夜姬想让人告白～天才们的恋爱头脑战～',
      ]);
      for (final title in [
        '辉夜姬想让人告白(辉夜大小姐想让我告白)',
        '辉夜大小姐想让我告白小说版 ～秀知院学园的七大不可思议～',
        '辉夜姬想让人告白 小說版',
      ]) {
        expect(NovelAnimeResolver.matches(title, anime), isTrue, reason: title);
      }
      expect(NovelAnimeResolver.matches('辉夜魔王式!', anime), isFalse);
      expect(NovelAnimeResolver.matches('超时空辉夜姬', anime), isFalse);
      expect(NovelAnimeResolver.matches('御徒町辉夜姬骑士团', anime), isFalse);
      expect(NovelAnimeResolver.matches('辉夜大小姐想让我告白',
        _anime(135218, '辉夜大小姐想让我告白', type: 1)), isFalse);
    });
    test(
      'identical normalized titles share an in-flight search and success cache',
      () async {
        final response = Completer<BangumiSearchPage>();
        var searches = 0;
        final resolver = NovelAnimeResolver(
          search: (_, _) {
            searches++;
            return response.future;
          },
        );
        final a = resolver.forTitle('测试作品');
        final b = resolver.forTitle('测试作品！');
        response.complete(
          BangumiSearchPage(items: [_anime(1, '测试作品')], rawCount: 1),
        );
        expect((await a).single.id, 1);
        expect((await b).single.id, 1);
        expect((await resolver.forTitle('测试作品')).single.id, 1);
        expect(searches, 1);
      },
    );
    test(
      'all result pages are matched; multiple seasons remain separate destinations',
      () async {
        final offsets = <int>[];
        final resolver = NovelAnimeResolver(
          search: (_, offset) async {
            offsets.add(offset);
            return offset == 0
                ? BangumiSearchPage(items: [_anime(1, '测试作品')], rawCount: 20)
                : BangumiSearchPage(
                    items: [_anime(1, '测试作品'), _anime(2, '测试作品 第二季')],
                    rawCount: 2,
                  );
          },
        );
        expect((await resolver.forTitle('测试作品')).map((e) => e.id), [1, 2]);
        expect(offsets, [0, 20]);
      },
    );
    test(
      'unmatched summaries use full aliases and reuse detail lookups',
      () async {
        var details = 0;
        final resolver = NovelAnimeResolver(
          search: (_, _) async => BangumiSearchPage(
            items: [_anime(3, 'Japanese name')],
            rawCount: 1,
          ),
          details: (id) async {
            details++;
            return _anime(id, 'Japanese name', aliases: ['测试作品']);
          },
        );
        expect((await resolver.forTitle('测试作品')).single.id, 3);
        expect((await resolver.forIds([3, 3])).single.id, 3);
        expect(details, 1);
      },
    );
    test(
      'shared prefixes and non-anime records are not treated as associations',
      () async {
        final items = [_anime(1, '测试作品外传'), _anime(2, '测试作品', type: 1)];
        final resolver = NovelAnimeResolver(
          search: (_, _) async => BangumiSearchPage(items: items, rawCount: 2),
          details: (id) async => items.singleWhere((e) => e.id == id),
        );
        expect(await resolver.forTitle('测试作品'), isEmpty);
      },
    );
    test(
      'request failures stay errors and a later explicit retry can succeed',
      () async {
        var requests = 0;
        final resolver = NovelAnimeResolver(
          search: (_, _) async {
            if (++requests == 1) throw StateError('fixture search failure');
            return BangumiSearchPage(items: [_anime(1, '测试作品')], rawCount: 1);
          },
        );
        await expectLater(resolver.forTitle('测试作品'), throwsStateError);
        expect((await resolver.forTitle('测试作品', refresh: true)).single.id, 1);
        expect(requests, 2);
      },
    );
    test(
      'confirmed IDs do not require matching translated titles or a new search',
      () async {
        final resolver = NovelAnimeResolver(
          search: (_, _) => throw StateError('confirmed links must not search'),
          details: (id) async => _anime(id, 'Different translated title'),
        );
        expect((await resolver.forIds([8])).single.id, 8);
      },
    );
  });
  testWidgets(
    'anime button routes the full item without reading or binding the novel',
    (tester) async {
      var reads = 0;
      final service = _Service([_anime(7, '测试作品')]);
      await _open(tester, service, () => reads++);
      await tester.tap(find.byTooltip('查看番剧详情'));
      await tester.pumpAndSettle();
      expect(find.text('anime:7:测试作品'), findsOneWidget);
      expect(reads, 0);
      expect(service.binds, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('multiple linked anime require selecting the destination', (
    tester,
  ) async {
    final service = _Service([_anime(1, '测试作品'), _anime(2, '测试作品 第二季')]);
    await _open(tester, service, () {});
    await tester.tap(find.byTooltip('查看番剧详情'));
    await tester.pumpAndSettle();
    expect(find.text('选择番剧'), findsOneWidget);
    expect(find.textContaining('anime:'), findsNothing);
    await tester.tap(find.text('测试作品 第二季 · 2026'));
    await tester.pumpAndSettle();
    expect(find.text('anime:2:测试作品 第二季'), findsOneWidget);
    expect(service.binds, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unmatched novels have no jump button', (tester) async {
    await _open(tester, _Service([]), () {});
    expect(find.byTooltip('查看番剧详情'), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });
  testWidgets(
    'a synced association updates an already visible bookshelf button',
    (tester) async {
      final service = _Service([_anime(7, '测试作品')])..onlyWhenBound = true;
      await _open(tester, service, () {});
      expect(find.byTooltip('查看番剧详情'), findsNothing);
      service.setIds([7]);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('查看番剧详情'));
      await tester.pumpAndSettle();
      expect(find.text('anime:7:测试作品'), findsOneWidget);
    },
  );
  testWidgets(
    'a reused search row cannot jump to the previous novel while loading',
    (tester) async {
      final service = _Service([_anime(1, '测试作品')]);
      final selection = ValueNotifier(_book);
      addTearDown(selection.dispose);
      await _open(tester, service, () {}, selection: selection);
      expect(find.byTooltip('查看番剧详情'), findsOneWidget);
      service.pending = Completer<List<BangumiItem>>();
      selection.value = const NovelBook(
        sourceId: 'b',
        url: 'https://test/b',
        title: '另一小说',
      );
      await tester.pump();
      expect(find.byTooltip('查看番剧详情'), findsNothing);
      service.pending!.complete([_anime(2, '另一小说')]);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('查看番剧详情'));
      await tester.pumpAndSettle();
      expect(find.text('anime:2:另一小说'), findsOneWidget);
      expect(service.binds, 0);
    },
  );
  testWidgets(
    'pending or failed anime lookup does not block reading the novel row',
    (tester) async {
      var reads = 0;
      final service = _Service([_anime(1, '测试作品')]);
      final selection = ValueNotifier(_book);
      addTearDown(selection.dispose);
      await _open(tester, service, () => reads++, selection: selection);
      service.pending = Completer<List<BangumiItem>>();
      selection.value = const NovelBook(
        sourceId: 'b',
        url: 'https://test/b',
        title: '另一小说',
      );
      await tester.pump();
      await tester.tap(find.text('另一小说'));
      expect(reads, 1);
      service.pending!.completeError(StateError('fixture lookup failure'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      await tester.tap(find.text('另一小说'));
      expect(reads, 2);
      expect(service.binds, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('an association error is visible and its button retries', (
    tester,
  ) async {
    final service = _Service([_anime(7, '测试作品')])..fail = true;
    await _open(tester, service, () {});
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byTooltip('查看番剧详情'), findsNothing);
    await tester.tap(find.byIcon(Icons.error_outline));
    await tester.pumpAndSettle();
    expect(service.requests, 2);
    expect(find.byTooltip('查看番剧详情'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
