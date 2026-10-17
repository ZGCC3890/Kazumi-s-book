import 'dart:async';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/rule_add_dialog.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'novel_models.dart';
import 'novel_rule_import.dart';
import 'novel_service.dart';

class NovelRuleCatalogPage extends StatefulWidget {
  const NovelRuleCatalogPage({super.key, required this.service, required this.importer});
  final NovelService service;
  final NovelRuleImport importer;
  @override
  State<NovelRuleCatalogPage> createState() => _NovelRuleCatalogPageState();
}

class _NovelRuleCatalogPageState extends State<NovelRuleCatalogPage> {
  late String _url;
  List<NovelJson> _catalog = [];
  bool _loading = true;
  String? _installing, _error;

  @override
  void initState() {
    super.initState();
    _url = widget.service.ruleCatalogUrl ?? NovelService.defaultCatalog;
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; _catalog = []; });
    try {
      final entries = await widget.importer.catalog(_url);
      if (mounted) setState(() => _catalog = entries);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _install(NovelJson entry) async {
    setState(() { _installing = entry['id'] as String; _error = null; });
    try {
      final rule = await widget.importer.fromCatalog(_url, entry);
      await widget.service.importRules([rule]);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已安装 ${rule.name}')));
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _installing = null);
    }
  }

  Future<void> _settings() async {
    final result = await showDialog<(String, List<NovelJson>)>(
      context: context, barrierDismissible: false,
      builder: (_) => _CatalogSettings(service: widget.service,
        importer: widget.importer, url: _url),
    );
    if (result != null && mounted) setState(() {
      _url = result.$1;
      _catalog = result.$2;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
    title: const Text('小说规则仓库'),
    leading: BackButton(onPressed: () => Navigator.of(context).pop()),
    actions: [
      IconButton(tooltip: '刷新', onPressed: _loading || _installing != null ? null : _load,
        icon: const Icon(Icons.refresh)),
      IconButton(tooltip: '规则仓库设置', onPressed: _loading || _installing != null ? null : _settings,
        icon: const Icon(Icons.settings_outlined)),
    ],
    body: ListenableBuilder(listenable: widget.service, builder: (_, _) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const Text('选择书源即可安装，返回后就能搜索小说。'),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null) ...[
            Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_error!)),
            if (_catalog.isEmpty)
              TextButton.icon(onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh), label: const Text('重试')),
          ],
          for (final entry in _catalog)
            Card(child: ListTile(
              title: Text(entry['name'] as String),
              subtitle: Text(entry['description'] as String),
              trailing: FilledButton.tonal(
                onPressed: _installing != null ? null : () => _install(entry),
                child: Text(_installing == entry['id'] ? '正在安装' :
                  widget.service.rules.any((rule) => rule.id == entry['id']) ? '重新获取' : '安装'),
              ),
            )),
        ]),
      ),
    )),
  );
}

class _CatalogSettings extends StatefulWidget {
  const _CatalogSettings({required this.service, required this.importer, required this.url});
  final NovelService service;
  final NovelRuleImport importer;
  final String url;
  @override
  State<_CatalogSettings> createState() => _CatalogSettingsState();
}

class _CatalogSettingsState extends State<_CatalogSettings> {
  late final _text = TextEditingController(text: widget.url);
  bool _saving = false;
  String? _error;
  @override
  void dispose() { _text.dispose(); super.dispose(); }

  Future<void> _save() async {
    final url = _text.text.trim();
    setState(() { _saving = true; _error = null; });
    try {
      final entries = await widget.importer.catalog(url);
      if (!mounted) return;
      await widget.service.saveRuleCatalogUrl(url);
      if (mounted) Navigator.pop(context, (url, entries));
    } catch (error) {
      if (mounted) setState(() { _saving = false; _error = error.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(canPop: !_saving, child: RuleDialog(
    title: '规则仓库设置', icon: Icons.settings_outlined,
    content: TextField(controller: _text, enabled: !_saving,
      decoration: InputDecoration(labelText: '规则仓库地址', border: const OutlineInputBorder(),
        errorText: _error, errorMaxLines: 4)),
    actions: [
      TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? '正在验证' : '保存')),
    ],
  ));
}
