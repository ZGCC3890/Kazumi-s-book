import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_progress_merge.dart';
import 'package:kazumi/novel/novel_sync_state.dart';

const book = NovelBook(sourceId: 'a', url: 'https://a/book', title: 'Book');
const early = NovelChapter(url: 'https://a/5', title: '第五章', volume: '第一卷', kind: '正文', number: 5);
const later = NovelChapter(url: 'https://a/7', title: '第七章', volume: '第一卷', kind: '正文', number: 7);
const nextVolume = NovelChapter(url: 'https://a/v2/1', title: '第一章', volume: '第二卷', kind: '正文', number: 1);
NovelJson position(NovelChapter chapter, {int offset = 0, int time = 1,
    String source = 'a', String? url, String edition = 'e'}) => NovelPosition(
  editionId: edition, sourceId: source, chapter: chapter, textOffset: offset,
  quote: '', prefix: '', suffix: '', chapterDigest: 'digest', updatedAt: time,
  bookUrl: url,
).toJson();
NovelSyncState conflict(NovelJson? a, NovelJson? b) => NovelSyncState()
  .edit('source/e/a', {'book': book.toJson()}, 'base')
  .edit('position/e', a, 'one')
  .merge(NovelSyncState().edit('position/e', b, 'two'));

void main() {
  var catalogCalls = 0;
  Future<List<NovelChapter>> catalog(NovelBook value) async {
    expect(value.url, book.url);
    catalogCalls++;
    return [early, later, nextVolume];
  }
  setUp(() => catalogCalls = 0);
  test('later chapter wins even when earlier progress has a newer timestamp', () async {
    final input = conflict(position(early, time: 99), position(later, time: 1));
    final output = await NovelProgressMerge.resolve(input, 'local', catalog);
    expect(output.value('position/e')!['chapter'], later.toJson());
    expect(output.covers(input), isTrue);
    expect(output.conflicts, isEmpty);
    expect(catalogCalls, 1);
    expect((await NovelProgressMerge.resolve(output, 'local', catalog)).encode(), output.encode());
  });
  test('actual catalog order compares chapters across volumes', () async {
    final input = conflict(position(nextVolume), position(later, time: 99));
    expect((await NovelProgressMerge.resolve(input, 'local', catalog))
      .value('position/e')!['chapter'], nextVolume.toJson());
  });
  test('same chapter uses offset, then timestamp, without fetching catalog', () async {
    for (final pair in [(12, 5, 1, 99, 12, 1), (5, 12, 99, 1, 12, 1),
        (12, 12, 1, 99, 12, 99), (12, 12, 99, 1, 12, 99), (12, 12, 1, 1, 12, 1)]) {
      final input = conflict(position(early, offset: pair.$1, time: pair.$3),
        position(early, offset: pair.$2, time: pair.$4));
      final output = await NovelProgressMerge.resolve(input, 'local', catalog);
      expect(output.value('position/e')!['textOffset'], pair.$5);
      expect(output.value('position/e')!['updatedAt'], pair.$6);
    }
    expect(catalogCalls, 0);
  });
  for (final kind in ['source', 'book', 'edition', 'deletion', 'missing-source', 'source-conflict', 'deleted-source']) {
    test('$kind remains available for user selection', () async {
      var input = conflict(position(early, url: book.url), switch (kind) {
        'source' => position(later, source: 'b'),
        'book' => position(later, url: 'https://a/another-book'),
        'edition' => position(later, edition: 'other'),
        'deletion' => null,
        _ => position(later),
      });
      if (kind == 'missing-source') input = NovelSyncState({...input.entities}..remove('source/e/a'));
      if (kind == 'source-conflict') input = input.merge(NovelSyncState().edit('source/e/a', {'book': book.toJson()}, 'other'));
      if (kind == 'deleted-source') input = input.edit('source/e/a', null, 'base');
      final output = await NovelProgressMerge.resolve(input, 'local', catalog);
      expect(output.encode(), input.encode());
      expect(catalogCalls, 0);
    });
  }
  test('missing chapter reports the real cause and keeps candidates', () async {
    const removed = NovelChapter(url: 'https://a/removed', title: '旧章', volume: '', kind: '正文');
    final input = conflict(position(early), position(removed));
    await expectLater(NovelProgressMerge.resolve(input, 'local', catalog),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('章节已不在当前目录'))));
    expect(input.revisions('position/e'), hasLength(2));
  });
  test('catalog failure is not hidden and unrelated conflicts are untouched', () async {
    final input = conflict(position(early), position(later));
    await expectLater(NovelProgressMerge.resolve(input, 'local', (_) async => throw StateError('offline')),
      throwsStateError);
    final other = NovelSyncState().edit('shelf/e', {'editionId': 'e'}, 'one')
      .merge(NovelSyncState().edit('shelf/e', null, 'two'));
    expect((await NovelProgressMerge.resolve(other, 'local', catalog)).encode(), other.encode());
  });
}
