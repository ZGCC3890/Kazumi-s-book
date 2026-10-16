import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/rule_add_dialog.dart';
import 'novel_rule_import.dart';
import 'novel_service.dart';

class NovelRuleImportDialog extends StatefulWidget {
  const NovelRuleImportDialog({super.key, required this.service,
    required this.importer, required this.initialValue});
  final NovelService service;
  final NovelRuleImport importer;
  final String initialValue;

  @override
  State<NovelRuleImportDialog> createState() => _NovelRuleImportDialogState();
}

class _NovelRuleImportDialogState extends State<NovelRuleImportDialog> {
  late final _text = TextEditingController(text: widget.initialValue);
  bool _saving = false;
  String? _error;

  @override
  void dispose() { _text.dispose(); super.dispose(); }

  Future<void> _import() async {
    setState(() { _saving = true; _error = null; });
    try {
      final rules = await widget.importer.parse(_text.text);
      if (!mounted) return;
      await widget.service.importRules(rules);
      if (mounted) Navigator.pop(context, rules.length);
    } catch (error) {
      if (mounted) setState(() { _saving = false; _error = error.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: RuleDialog(
      title: '导入规则',
      icon: Icons.content_paste_go_rounded,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('支持规则链接、JSON 或 JSON 数组。同 ID 的小说规则会被替换。'),
          const SizedBox(height: 20),
          TextField(
            controller: _text,
            enabled: !_saving,
            minLines: 4,
            maxLines: 8,
            onChanged: (_) => setState(() => _error = null),
            decoration: InputDecoration(
              labelText: '规则内容',
              hintText: '在这里粘贴规则链接或 JSON',
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
              errorText: _error,
              errorMaxLines: 4,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消')),
        FilledButton.icon(
          onPressed: _saving || _text.text.trim().isEmpty ? null : _import,
          icon: _saving ? const SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.download_rounded),
          label: Text(_saving ? '正在导入' : '导入规则'),
        ),
      ],
    ),
  );
}
