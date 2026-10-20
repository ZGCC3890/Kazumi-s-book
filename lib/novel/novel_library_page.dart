import 'package:flutter/material.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'novel_entry.dart';
import 'novel_rules_page.dart';
import 'novel_service.dart';
import 'novel_book_cover.dart';
import 'novel_anime_link.dart';
import 'novel_conflicts.dart';
import 'novel_cover_grid.dart';
import 'novel_models.dart';

class NovelLibraryPage extends StatelessWidget {
  const NovelLibraryPage({super.key, required this.service, this.title});
  final NovelService service;
  final Widget? title;

  Future<void> _remove(BuildContext context, NovelEdition edition) async {
    final confirmed = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('删除书籍'),
      content: const Text('将这本书移出书架，保留本地阅读进度与书签。手动同步后，其他设备的书架也会更新。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('删除')),
      ],
    ));
    if (confirmed == true && context.mounted) {
      await _run(context, () => service.removeFromShelf(edition.id));
    }
  }
  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (_, _) => Scaffold(
      appBar: SysAppBar(
        needTopOffset: false,
        toolbarHeight: 72,
        title: title ?? const Text('书架'),
        actions: [
          Padding(padding: const EdgeInsets.only(right: 8), child: MergeSemantics(child: Tooltip(
            message: '小说规则', child: StateActionButton.tonal(
            text: '规则',
            icon: Icons.rule_folder_outlined,
            onPressed: () => Navigator.of(context, rootNavigator: true).push<void>(
              MaterialPageRoute(
                builder: (_) => NovelRulesPage(service: service),
              ),
            ),
          )))),
          Padding(padding: const EdgeInsets.only(right: 8), child: MergeSemantics(child: Tooltip(
            message: '同步小说', child: StateActionButton.tonal(
            text: '同步',
            icon: Icons.sync_rounded,
            onPressed: service.syncing
                ? null
                : () => _run(context, service.sync),
          )))),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => NovelEntry.search(context, service, 0, ''),
        icon: const Icon(Icons.search),
        label: const Text('搜索小说'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('WebDAV 同步阅读进度与书签'),
            subtitle: const Text('启动、退出阅读器及关闭应用时同步；阅读时保存在本地，也可点击右上角手动同步。'),
            value: GStorage.getSetting(SettingsKeys.webDavEnableNovels),
            onChanged: (value) => _run(context, () async {
              if (value && !GStorage.getSetting(SettingsKeys.webDavEnable)) {
                throw StateError('请先在设置 → 多设备同步中配置并启用 WebDAV');
              }
              await GStorage.putSetting(SettingsKeys.webDavEnableNovels, value);
              service.refreshView();
            }),
          ),
          if (service.syncError != null)
            ListTile(
              leading: const Icon(Icons.cloud_off_outlined),
              title: const Text('云同步未完成，本地记录已保留'),
              subtitle: Text(service.syncError!),
            ),
          if (service.lastSync != null)
            ListTile(title: Text('上次同步：${service.lastSync!.toLocal()}')),
          if (service.syncNotice != null)
            ListTile(title: Text(service.syncNotice!)),
          if (service.state.conflicts.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.merge),
              title: const Text('有多设备修改需要选择'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => NovelEntry.conflicts(context, service),
            ),
          if (service.shelfEditions.isEmpty && service.state.conflicts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('点击“搜索小说”选择书源开始阅读，也可以从番剧详情或追番卡片打开小说。'),
            ),
          for (final key in service.state.conflicts)
            Card(child: NovelConflictTile(store: service, recordKey: key)),
          _books(context),
        ],
      ),
    ),
  );

  Widget _books(BuildContext context) {
    final editions = service.shelfEditions.where((edition) =>
        NovelConflicts.displayKeys(service.state, edition.id).isEmpty).toList();
    return NovelCoverGrid(itemCount: editions.length, actionHeight: 48,
      itemBuilder: (context, index, width) {
        final edition = editions[index];
        final deleted = NovelConflicts.workDeleted(service.state, edition.id);
        final sourceConflict = NovelConflicts.sourceKeys(service.state, edition.id).isNotEmpty;
        final book = sourceConflict ? null : service.selectedBook(edition.id);
        final name = deleted ? '作品信息已删除' : service.work(edition.workId).title;
        return Card(margin: EdgeInsets.zero, clipBehavior: Clip.antiAlias, child: Column(children: [
          Expanded(child: InkWell(
            onTap: () => _run(context, () => NovelEntry.read(context, service, edition.id)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (sourceConflict)
                SizedBox(height: width * 1.45, child: const Tooltip(
                  message: '这本书的书源有冲突，请点击选择', child: Icon(Icons.merge)))
              else
                NovelBookCover(service: service, book: book, width: width, height: width * 1.45),
              Padding(padding: const EdgeInsets.all(8), child: Text(name,
                style: Theme.of(context).textTheme.titleSmall,
                maxLines: 2, overflow: TextOverflow.ellipsis)),
            ]),
          )),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (book != null)
              NovelAnimeLink(service: service, book: book, editionId: edition.id),
            PopupMenuButton<String>(
              tooltip: '小说操作', useRootNavigator: true,
              itemBuilder: (_) => [
                if (!deleted) const PopupMenuItem(value: 'source', child: Text('更换书源')),
                const PopupMenuItem(value: 'remove', child: Text('删除书籍')),
              ],
              onSelected: (value) async {
                if (value == 'remove') {
                  await _remove(context, edition);
                } else {
                  await NovelEntry.search(context, service, 0, name, editionId: edition.id);
                }
              },
            ),
          ]),
        ]));
      });
  }
}
