import 'package:flutter/material.dart';
import 'novel_models.dart';
import 'novel_reader_store.dart';
import 'novel_sync_state.dart';

/// Conflict decisions are scoped to the records an operation actually uses.
class NovelConflicts {
  static bool has(NovelSyncState state, String key) =>
      state.revisions(key).length > 1;

  static List<String> bookmarkKeys(NovelSyncState state, String editionId) =>
      state.conflicts.where((key) => key.startsWith('bookmark/') &&
          state.revisions(key).any((revision) =>
              (revision.value?['position'] as NovelJson?)?['editionId'] == editionId))
          .toList();

  static List<String> displayKeys(NovelSyncState state, String editionId,
      {bool includeShelf = true}) {
    final keys = <String>['edition/$editionId', if (includeShelf) 'shelf/$editionId'];
    for (final revision in state.revisions('edition/$editionId')) {
      final workId = revision.value?['workId'];
      if (workId != null) keys.add('work/$workId');
    }
    return keys.where((key) => has(state, key)).toList();
  }

  static List<String> sourceKeys(NovelSyncState state, String editionId) {
    final selected = 'selected/$editionId';
    final keys = <String>[selected];
    for (final revision in state.revisions(selected)) {
      final source = revision.value?['sourceId'];
      if (source != null) keys.add('source/$editionId/$source');
    }
    return keys.where((key) => has(state, key)).toList();
  }

  static bool workDeleted(NovelSyncState state, String editionId) {
    final edition = state.revisions('edition/$editionId');
    if (edition.length != 1 || edition.single.value == null) return false;
    final work = state.revisions('work/${edition.single.value!['workId']}');
    return work.length == 1 && work.single.value == null;
  }

  static String label(String key) => switch (key.split('/').first) {
    'position' => '阅读进度',
    'bookmark' => '书签',
    'selected' => '当前书源',
    'source' => '书源绑定',
    'chapterMap' => '章节对应',
    'edition' => '小说信息',
    'work' => '作品信息',
    'shelf' => '书架状态',
    'anime' => '番剧关联',
    _ => '阅读数据',
  };

  static String describe(String key, NovelJson? value) {
    if (value == null) return '保留删除';
    final position = key.startsWith('bookmark/')
        ? value['position'] as NovelJson : value;
    final chapter = position['chapter'] as NovelJson?;
    if (chapter != null) {
      final note = value['note'] as String?;
      return [
        if (note != null && note.isNotEmpty) note,
        '${chapter['volume']} ${chapter['title']}'.trim(),
        if (position['quote'] is String) position['quote'] as String,
      ].join('\n');
    }
    final book = value['book'] as NovelJson?;
    if (book != null) return '${book['title']}\n${book['sourceId']}';
    if (value['title'] is String) return value['title'] as String;
    if (key.startsWith('selected/')) return '使用书源 ${value['sourceId']}';
    if (key.startsWith('shelf/')) return '保留在书架';
    if (key.startsWith('anime/')) return '保留番剧 ${value['animeId']} 的小说关联';
    if (key.startsWith('edition/')) return '保留小说信息：${value['label']}';
    return value.toString();
  }

  static String details(String key, NovelRevision revision) {
    final value = revision.value;
    final position = key.startsWith('bookmark/')
        ? (value?['position'] as NovelJson?) : value;
    final updatedAt = position?['updatedAt'];
    final clocks = revision.clock.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return [
      if (position?['sourceId'] != null) '书源：${position!['sourceId']}',
      if (position?['textOffset'] != null) '章内文字位置：${position!['textOffset']}',
      if (updatedAt is int)
        '记录时间：${DateTime.fromMillisecondsSinceEpoch(updatedAt).toLocal()}',
      '设备因果修订：${clocks.map((entry) => '${entry.key}=${entry.value}').join('，')}',
    ].join('\n');
  }

  static Future<bool> choose(
    BuildContext context, NovelReaderStore store, String key,
  ) async {
    if (!has(store.state, key)) return true;
    final owner = ModalRoute.of(context);
    final revisions = store.state.revisions(key);
    final token = store.state.conflictToken(key);
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('选择要保留的${label(key)}'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('设备上的修改发生冲突。只会解决这一条记录。'),
              for (var i = 0; i < revisions.length; i++)
                ListTile(
                  title: Text(describe(key, revisions[i].value)),
                  subtitle: Text(details(key, revisions[i])),
                  onTap: () => Navigator.pop(ctx, i),
                ),
            ]),
          ),
        ),
        actions: [TextButton(
          onPressed: () => Navigator.pop(ctx), child: const Text('取消'),
        )],
      ),
    );
    if (selected == null || !context.mounted || owner?.isActive == false) {
      return false;
    }
    try {
      await store.resolve(key, revisions[selected], expectedToken: token);
      return context.mounted && owner?.isActive != false;
    } catch (error) {
      if (context.mounted && owner?.isActive != false) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
      return false;
    }
  }

  static Future<bool> ensure(
    BuildContext context, NovelReaderStore store,
    Iterable<String> Function() relevantKeys,
  ) async {
    while (context.mounted && ModalRoute.of(context)?.isActive != false) {
      final unresolved = relevantKeys()
          .where((key) => has(store.state, key)).toList();
      if (unresolved.isEmpty) return true;
      if (!await choose(context, store, unresolved.first)) return false;
    }
    return false;
  }
}

class NovelConflictTile extends StatelessWidget {
  const NovelConflictTile({super.key, required this.store, required this.recordKey});
  final NovelReaderStore store;
  final String recordKey;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.merge),
    title: Text('${NovelConflicts.label(recordKey)}有冲突'),
    subtitle: Text(store.state.revisions(recordKey)
        .map((revision) => NovelConflicts.describe(recordKey, revision.value))
        .join(' / ')),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => NovelConflicts.choose(context, store, recordKey),
  );
}
