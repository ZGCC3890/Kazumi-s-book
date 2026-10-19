import 'package:flutter/material.dart';

/// A searchable selection field; typed queries never become configuration values.
class NovelAiChoice extends StatelessWidget {
  const NovelAiChoice({super.key, required this.label, required this.value,
    required this.choices, required this.onChanged});
  final String label, value;
  final Map<String, String> choices;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: 'novel-ai-choice-$label', button: true,
    child: Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: InkWell(
      onTap: onChanged == null ? null : () async {
        final selected = await showDialog<String>(context: context, builder: (_) =>
          _ChoiceDialog(label: label, value: value, choices: choices));
        if (selected != null && context.mounted) onChanged!(selected);
      },
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, enabled: onChanged != null,
          border: const OutlineInputBorder()),
        child: Row(children: [
          Expanded(child: Text(choices[value] ?? '请选择', maxLines: 2, overflow: TextOverflow.ellipsis)),
          const Icon(Icons.arrow_drop_down),
        ]),
      ),
    ),
  ));
}

class _ChoiceDialog extends StatefulWidget {
  const _ChoiceDialog({required this.label, required this.value, required this.choices});
  final String label, value;
  final Map<String, String> choices;
  @override
  State<_ChoiceDialog> createState() => _ChoiceDialogState();
}

class _ChoiceDialogState extends State<_ChoiceDialog> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final matches = widget.choices.entries.where((entry) =>
      '${entry.key} ${entry.value}'.toLowerCase().contains(_query.trim().toLowerCase())).toList();
    return AlertDialog(
      title: Text('选择${widget.label}'),
      content: SizedBox(width: 480, height: 360, child: Column(children: [
        TextField(autofocus: true,
          decoration: InputDecoration(labelText: '搜索${widget.label}', prefixIcon: const Icon(Icons.search)),
          onChanged: (value) => setState(() => _query = value)),
        const SizedBox(height: 8),
        Expanded(child: matches.isEmpty ? const Center(child: Text('没有匹配项')) : ListView.builder(
          itemCount: matches.length,
          itemBuilder: (context, index) {
            final entry = matches[index];
            return ListTile(title: Text(entry.value),
              selected: entry.key == widget.value,
              onTap: () => Navigator.pop(context, entry.key));
          },
        )),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))],
    );
  }
}
