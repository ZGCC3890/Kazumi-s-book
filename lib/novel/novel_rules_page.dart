import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/request/clients/plugin_site_client.dart';
import 'package:kazumi/bean/dialog/rule_add_dialog.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/utils/encoding.dart';
import 'novel_rule.dart';
import 'novel_rule_catalog_page.dart';
import 'novel_rule_import.dart';
import 'novel_rule_import_dialog.dart';
import 'novel_service.dart';
import 'novel_account_dialog.dart';
import 'novel_ai_page.dart';

Future<String> _readRuleText(String url) =>
    PluginSiteClient.instance.requestText(url, method: 'GET');

class NovelRulesPage extends StatefulWidget {
  const NovelRulesPage({super.key, required this.service, this.readText = _readRuleText});
  final NovelService service;
  final Future<String> Function(String url) readText;
  static const defaultCatalog = NovelService.defaultCatalog;
  @override
  State<NovelRulesPage> createState() => _NovelRulesPageState();
}

class _NovelRulesPageState extends State<NovelRulesPage> {
  final _search = TextEditingController();
  late final _importer = NovelRuleImport(widget.readText);
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) _error = error.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _feedback(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _add() async {
    final source = await showRuleAddDialog(context, sourceLabel: '小说', allowCreate: false);
    if (!mounted || source == null) return;
    switch (source) {
      case RuleAddSource.catalog:
        await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) =>
          NovelRuleCatalogPage(service: widget.service, importer: _importer)));
      case RuleAddSource.clipboard:
        var input = '';
        await _run(() async {
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          input = data?.text ?? '';
        });
        if (!mounted || _error != null) return;
        final count = await showDialog<int>(context: context, barrierDismissible: false,
          builder: (_) => NovelRuleImportDialog(service: widget.service,
            importer: _importer, initialValue: input));
        if (count != null && mounted) _feedback('已导入 $count 条小说规则');
      case RuleAddSource.file:
        await _file();
      case RuleAddSource.create:
        throw StateError('小说规则不提供模板编辑器');
    }
  }

  Future<void> _file() => _run(() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null || !mounted) return;
    final rules = await _importer.parse(utf8.decode(result.files.single.bytes!));
    await widget.service.importRules(rules);
    if (mounted) _feedback('已导入 ${rules.length} 条小说规则');
  });

  Future<void> _remove(NovelRule rule) async {
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => RuleDialog(
      title: '删除这条规则？', icon: Icons.delete_outline_rounded,
      content: Text('${rule.name}\n删除后将不再使用这个来源搜索小说，可以稍后重新导入。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('保留')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
      ],
    ));
    if (confirmed != true || !mounted) return;
    await _run(() => widget.service.removeRule(rule.id));
  }
  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
    title: const Text('小说规则'),
    leading: BackButton(onPressed: () => Navigator.of(context).pop()),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _busy ? null : _add,
      icon: const Icon(Icons.add),
      label: const Text('添加规则'),
    ),
    body: ListenableBuilder(
      listenable: widget.service,
      builder: (_, _) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000), child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('我的规则', style: TextStyle(fontSize: 22)),
          const SizedBox(height: 8),
          const Text('默认书源自动获取。在这里管理已安装的小说来源，或添加更多规则。'),
          ListTile(leading: const Icon(Icons.auto_awesome_outlined), title: const Text('AI 作品关联'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => NovelAiPage(service: widget.service)))),
          const SizedBox(height: 16),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '搜索已安装规则',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(_error!),
            ),
          if (widget.service.rules.isEmpty)
            const ListTile(title: Text('还没有小说规则，点击“添加规则”开始')),
          for (final rule in widget.service.rules.where((rule) =>
              rule.name.toLowerCase().contains(_search.text.trim().toLowerCase())))
            Card(child: ListTile(
              title: Text(rule.name),
              subtitle: Text(Uri.parse(rule.json['searchUrl'] as String).host),
              leading: const Icon(Icons.menu_book_outlined),
              onTap: _busy ? null : () => showNovelAccount(context, widget.service, rule.id),
              trailing: PopupMenuButton<String>(
                tooltip: '管理${rule.name}',
                enabled: !_busy,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'account', child: Text('书源账号与网站')),
                  PopupMenuItem(value: 'copy', child: Text('复制规则链接')),
                  PopupMenuItem(value: 'delete', child: Text('删除规则')),
                ],
                onSelected: (action) async {
                  if (action == 'delete') {
                    await _remove(rule);
                  } else if (action == 'account') {
                    await showNovelAccount(context, widget.service, rule.id);
                  } else {
                    await _run(() async {
                      await Clipboard.setData(ClipboardData(text: jsonToKazumiBase64(rule.encode())));
                      if (mounted) _feedback('已复制规则链接');
                    });
                  }
                },
              ),
            )),
        ],
      ),
      ),
      ),
    ),
  );
}
