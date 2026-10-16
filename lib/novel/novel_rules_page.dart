import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/request/clients/plugin_site_client.dart';
import 'novel_models.dart';
import 'novel_rule.dart';
import 'novel_service.dart';

class NovelRulesPage extends StatefulWidget {
  const NovelRulesPage({super.key, required this.service});
  final NovelService service;
  static const defaultCatalog =
      'https://raw.githubusercontent.com/ZGCC3890/'
      'Kazumi-s-book/feature/novel-reader/novel_rules/catalog.json';
  @override
  State<NovelRulesPage> createState() => _NovelRulesPageState();
}

class _NovelRulesPageState extends State<NovelRulesPage> {
  late final TextEditingController _catalogUrl;
  String? _loadedCatalogUrl;
  List<NovelJson> _catalog = [];
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _catalogUrl = TextEditingController(
      text: widget.service.ruleCatalogUrl ?? NovelRulesPage.defaultCatalog,
    );
  }

  @override
  void dispose() {
    _catalogUrl.dispose();
    super.dispose();
  }

  Future<String> _get(String url) =>
      PluginSiteClient.instance.requestText(url, method: 'GET');
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

  Future<void> _loadCatalog() => _run(() async {
    final url = _catalogUrl.text.trim();
    final j = jsonDecode(await _get(url)) as NovelJson;
    if (j['version'] != 1) throw const FormatException('不支持的规则索引版本');
    _catalog = List<NovelJson>.from(j['rules'] as List);
    _loadedCatalogUrl = url;
    await widget.service.saveRuleCatalogUrl(url);
  });
  Future<void> _paste() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入小说规则'),
        content: SizedBox(
          width: 600,
          child: TextField(
            controller: controller,
            minLines: 3,
            maxLines: 12,
            decoration: const InputDecoration(hintText: '粘贴规则 JSON 或规则文件 URL'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (raw == null || raw.isEmpty) return;
    await _run(
      () async => widget.service.importRule(
        raw.startsWith('https://') || raw.startsWith('http://')
            ? await _get(raw)
            : raw,
      ),
    );
  }

  Future<void> _file() => _run(() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result != null)
      await widget.service.importRule(utf8.decode(result.files.single.bytes!));
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('小说规则'),
      actions: [
        IconButton(
          tooltip: '从文件导入',
          onPressed: _busy ? null : _file,
          icon: const Icon(Icons.file_open_outlined),
        ),
        IconButton(
          tooltip: '粘贴 JSON 或 URL',
          onPressed: _busy ? null : _paste,
          icon: const Icon(Icons.add_link),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: widget.service,
      builder: (_, _) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('小说规则与番剧规则分开管理。仓库内 novel_rules/ 的规则更新后，可在这里重新导入。'),
          const SizedBox(height: 16),
          TextField(
            controller: _catalogUrl,
            decoration: const InputDecoration(
              labelText: '规则索引 URL',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _loadCatalog,
            icon: const Icon(Icons.cloud_download_outlined),
            label: const Text('获取规则列表'),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(_error!),
            ),
          for (final entry in _catalog)
            ListTile(
              title: Text(entry['name'] as String),
              subtitle: Text(entry['description'] as String),
              trailing: FilledButton.tonal(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        final url = Uri.parse(
                          _loadedCatalogUrl!,
                        ).resolve(entry['file'] as String).toString();
                        final raw = await _get(url);
                        if (NovelRule.decode(raw).id != entry['id']) {
                          throw const FormatException('规则文件 id 与索引条目不一致');
                        }
                        await widget.service.importRule(raw);
                      }),
                child: Text(
                  widget.service.rules.any((r) => r.id == entry['id'])
                      ? '更新'
                      : '导入',
                ),
              ),
            ),
          const Divider(height: 32),
          const Text('已安装规则'),
          if (widget.service.rules.isEmpty)
            const ListTile(title: Text('还没有小说规则，请从列表或文件导入')),
          for (final rule in widget.service.rules)
            ListTile(
              title: Text(rule.name),
              subtitle: Text('${rule.id} · ${rule.json['encoding']}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '复制规则 JSON',
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: rule.encode())),
                    icon: const Icon(Icons.copy_outlined),
                  ),
                  IconButton(
                    tooltip: '删除规则',
                    onPressed: () =>
                        _run(() => widget.service.removeRule(rule.id)),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
