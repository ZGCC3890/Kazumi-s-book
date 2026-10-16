import 'package:flutter/material.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'novel_entry.dart';
import 'novel_rules_page.dart';
import 'novel_service.dart';
import 'novel_book_cover.dart';
import 'novel_anime_link.dart';

class NovelLibraryPage extends StatelessWidget {
  const NovelLibraryPage({super.key, required this.service, this.title});
  final NovelService service;
  final Widget? title;
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
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: title ?? const Text('书架'),
        actions: [
          IconButton(
            tooltip: '小说规则',
            icon: const Icon(Icons.rule_folder_outlined),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => NovelRulesPage(service: service),
              ),
            ),
          ),
          IconButton(
            tooltip: '同步小说',
            icon: const Icon(Icons.sync),
            onPressed: service.syncing
                ? null
                : () => _run(context, service.sync),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => NovelEntry.search(context, service, 0, ''),
        icon: const Icon(Icons.add),
        label: const Text('添加小说'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('WebDAV 自动同步阅读进度与书签'),
            subtitle: const Text('复用已有云盘配置。阅读时自动保存本地；有网络时自动同步。'),
            value: GStorage.getSetting(SettingsKeys.webDavEnableNovels),
            onChanged: (value) => _run(context, () async {
              if (value && !GStorage.getSetting(SettingsKeys.webDavEnable)) {
                throw StateError('请先在设置 → 多设备同步中配置并启用 WebDAV');
              }
              await GStorage.putSetting(SettingsKeys.webDavEnableNovels, value);
              if (value) await service.sync();
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
          if (service.state.conflicts.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.merge),
              title: const Text('有多设备修改需要选择'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => NovelEntry.conflicts(context, service),
            ),
          if (service.shelfEditions.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('点击“添加小说”搜索书源，也可以从番剧详情或追番卡片关联小说。'),
            ),
          if (service.state.conflicts.isEmpty)
            for (final edition in service.shelfEditions)
              Card(
                child: ListTile(
                  leading: NovelBookCover(
                    service: service,
                    book: service.selectedBook(edition.id),
                  ),
                  title: Text(service.work(edition.workId).title),
                  subtitle: Text(service.work(edition.workId).author),
                  onTap: () => _run(context, () async {
                    await NovelEntry.conflicts(context, service);
                    if (context.mounted && service.state.conflicts.isEmpty)
                      await NovelEntry.read(context, service, edition.id);
                  }),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (service.selectedBook(edition.id) != null)
                        NovelAnimeLink(
                          service: service,
                          book: service.selectedBook(edition.id)!,
                          editionId: edition.id,
                        ),
                      PopupMenuButton<String>(
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'source', child: Text('更换书源')),
                        ],
                        onSelected: (value) => NovelEntry.search(
                          context, service, 0,
                          service.work(edition.workId).title,
                          editionId: edition.id,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    ),
  );
}
