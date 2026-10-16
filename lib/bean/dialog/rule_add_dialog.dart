import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';

enum RuleAddSource { catalog, clipboard, file, create }

Future<RuleAddSource?> showRuleAddDialog(
  BuildContext context, {
  String sourceLabel = '番剧',
  bool allowCreate = true,
}) => KazumiDialog.show<RuleAddSource>(
  context: context,
  builder: (context) {
    final colors = Theme.of(context).colorScheme;
    return RuleDialog(
      title: '添加规则',
      icon: Icons.add_circle_outline_rounded,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('选择一种方式，添加新的$sourceLabel来源。'),
          const SizedBox(height: 20),
          for (final option in [
            (RuleAddSource.catalog, Icons.travel_explore_rounded,
              '浏览规则仓库', '发现并安装社区规则'),
            (RuleAddSource.clipboard, Icons.content_paste_rounded,
              '从剪贴板导入', '粘贴规则链接或 JSON'),
            (RuleAddSource.file, Icons.file_open_outlined,
              '从文件导入', '读取本地 JSON 规则文件'),
            if (allowCreate)
              (RuleAddSource.create, Icons.edit_note_rounded,
                '新建规则', '从模板开始编写'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Material(
                color: option.$1 == RuleAddSource.catalog
                    ? colors.secondaryContainer : colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(
                  option.$1 == RuleAddSource.catalog ? 20 : 12),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  minVerticalPadding: 14,
                  leading: Icon(option.$2, color: colors.onSurfaceVariant),
                  title: Text(option.$3),
                  subtitle: Text(option.$4),
                  trailing: const Icon(Icons.arrow_forward_rounded, size: 20),
                  onTap: () => Navigator.of(context).pop(option.$1),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消')),
      ],
    );
  },
);

class RuleDialog extends StatelessWidget {
  const RuleDialog({
    super.key,
    required this.title,
    required this.icon,
    required this.content,
    required this.actions,
  });
  final String title;
  final IconData icon;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      constraints: const BoxConstraints(maxWidth: 560),
      insetPadding: const EdgeInsets.all(24),
      scrollable: true,
      icon: Icon(icon, color: colors.secondary, size: 32),
      title: Text(title),
      content: SizedBox(width: 480, child: content),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      actionsOverflowButtonSpacing: 8,
      actions: actions,
    );
  }
}
