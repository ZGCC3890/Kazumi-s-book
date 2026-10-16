import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'novel_locator.dart';
import 'novel_search_query.dart';

typedef NovelAnimeSearch =
    Future<BangumiSearchPage> Function(String title, int offset);
typedef NovelAnimeDetails = Future<BangumiItem> Function(int id);

class NovelAnimeResolver {
  NovelAnimeResolver({NovelAnimeSearch? search, NovelAnimeDetails? details})
    : _search = search ?? _searchAnime,
      _details = details ?? _getAnime;

  final NovelAnimeSearch _search;
  final NovelAnimeDetails _details;
  final _queue = AsyncSerialQueue();
  final _titles = <String, List<BangumiItem>>{};
  final _pendingTitles = <String, Future<List<BangumiItem>>>{};
  final _items = <int, BangumiItem>{};
  final _pendingItems = <int, Future<BangumiItem>>{};

  static String titleKey(String title) =>
      NovelLocator.normalize(novelQueryFromAnime(title));

  static bool matches(String title, BangumiItem anime) =>
      anime.type == 2 &&
      [anime.name, anime.nameCn, ...anime.alias]
          .where((name) => name.isNotEmpty)
          .any((name) => titleKey(name) == titleKey(title));

  static Future<BangumiSearchPage> _searchAnime(
    String title,
    int offset,
  ) async {
    final page = await BangumiApi.bangumiSearch(
      title,
      offset: offset,
      includeWithoutChineseName: true,
    );
    if (page == null) throw StateError('番剧关联搜索未返回数据');
    return page;
  }

  static Future<BangumiItem> _getAnime(int id) async {
    final anime = await BangumiApi.getBangumiInfoByID(id);
    if (anime == null) throw StateError('无法获取关联番剧详情（$id）');
    return anime;
  }

  Future<BangumiItem> _item(int id) async {
    if (_items.containsKey(id)) return _items[id]!;
    if (_pendingItems.containsKey(id)) return _pendingItems[id]!;
    final request = _details(id);
    _pendingItems[id] = request;
    try {
      return _items[id] = await request;
    } finally {
      _pendingItems.remove(id);
    }
  }

  Future<List<BangumiItem>> forIds(
    List<int> ids, {
    bool refresh = false,
  }) async {
    if (refresh) {
      for (final id in ids) {
        _items.remove(id);
      }
    }
    return Future.wait(ids.toSet().map(_item));
  }

  Future<List<BangumiItem>> forTitle(
    String title, {
    bool refresh = false,
  }) async {
    final key = titleKey(title);
    if (refresh) _titles.remove(key);
    if (_titles.containsKey(key)) return _titles[key]!;
    if (_pendingTitles.containsKey(key)) return _pendingTitles[key]!;
    final request = _queue.run(() async {
      final matchesById = <int, BangumiItem>{};
      var offset = 0;
      BangumiSearchPage page;
      do {
        page = await _search(novelQueryFromAnime(title), offset);
        for (final summary in page.items) {
          final anime = matches(title, summary)
              ? summary
              : await _item(summary.id);
          if (matches(title, anime)) matchesById[anime.id] = anime;
        }
        offset += page.rawCount;
      } while (page.rawCount == 20);
      return matchesById.values.toList();
    });
    _pendingTitles[key] = request;
    try {
      return _titles[key] = await request;
    } finally {
      _pendingTitles.remove(key);
    }
  }
}
