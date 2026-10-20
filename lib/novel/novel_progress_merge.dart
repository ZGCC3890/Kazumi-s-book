import 'novel_models.dart';
import 'novel_sync_state.dart';

/// Resolves progress only within one confirmed source and book.
class NovelProgressMerge {
  static Future<NovelSyncState> resolve(
    NovelSyncState state,
    String deviceId,
    Future<List<NovelChapter>> Function(NovelBook) catalog,
  ) async {
    var result = state;
    for (final key in state.conflicts.where((key) => key.startsWith('position/'))) {
      final revisions = state.revisions(key);
      if (revisions.any((revision) => revision.value == null)) continue;
      final positions = revisions.map((r) => NovelPosition.fromJson(r.value!)).toList();
      final first = positions.first;
      if (positions.any((p) => p.sourceId != first.sourceId || p.editionId != first.editionId)) continue;
      final sources = state.revisions('source/${first.editionId}/${first.sourceId}');
      if (sources.length != 1 || sources.single.value == null) continue;
      final book = NovelBook.fromJson(sources.single.value!['book'] as NovelJson);
      if (positions.any((p) => p.bookUrl != null && p.bookUrl != book.url)) continue;
      final sameChapter = positions.every((p) => p.chapter.url == first.chapter.url);
      final order = <String, int>{};
      if (!sameChapter) {
        final chapters = await catalog(book);
        for (var i = 0; i < chapters.length; i++) {
          order[chapters[i].url] = i;
        }
        if (positions.any((p) => !order.containsKey(p.chapter.url))) {
          throw StateError('进度中的章节已不在当前目录，请手动选择保留的进度');
        }
      }
      var selected = 0;
      for (var i = 1; i < positions.length; i++) {
        final a = positions[i], b = positions[selected];
        var comparison = sameChapter ? 0 : order[a.chapter.url]!.compareTo(order[b.chapter.url]!);
        if (comparison == 0) comparison = a.textOffset.compareTo(b.textOffset);
        if (comparison == 0) comparison = a.updatedAt.compareTo(b.updatedAt);
        if (comparison > 0) selected = i;
      }
      result = result.resolve(key, revisions[selected], deviceId,
        expectedToken: result.conflictToken(key));
    }
    return result;
  }
}
