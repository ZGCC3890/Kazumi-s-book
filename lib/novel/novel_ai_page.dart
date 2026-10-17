import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'novel_ai.dart';
import 'novel_service.dart';

String _error(Object error) => error is DioException
    ? 'AI 请求失败：${error.response?.statusCode ?? error.type.name}'
    : error.toString();

class NovelAiPage extends StatefulWidget {
  const NovelAiPage({super.key, required this.service});
  final NovelService service;
  @override
  State<NovelAiPage> createState() => _NovelAiPageState();
}

class _NovelAiPageState extends State<NovelAiPage> {
  late final _endpoint = TextEditingController(text: widget.service.aiSettings.endpoint);
  late final _model = TextEditingController(text: widget.service.aiSettings.model);
  late final _token = TextEditingController(text: widget.service.aiSettings.token);
  late bool _enabled = widget.service.aiSettings.enabled;
  late bool _webSearch = widget.service.aiSettings.webSearch;
  bool _busy = false;
  String? _message;
  CancelToken? _request;
  NovelAiSettings get _value => NovelAiSettings(enabled: _enabled,
    webSearch: _webSearch,
    endpoint: _endpoint.text.trim(), model: _model.text.trim(), token: _token.text.trim());
  @override
  void dispose() {
    _request?.cancel();
    _endpoint.dispose();
    _model.dispose();
    _token.dispose();
    super.dispose();
  }
  Future<void> _run({required bool test}) async {
    setState(() { _busy = true; _message = null; });
    try {
      if (test) {
        _request = CancelToken();
        await widget.service.suggestTitles('辉夜大小姐想让我告白', toAnime: false,
          settings: _value, cancelToken: _request);
      } else {
        await widget.service.saveAiSettings(_value);
      }
      if (mounted) setState(() => _message = test ? '连接验证成功，设置尚未保存' : '已保存到本机');
    } catch (error) {
      if (mounted) setState(() => _message = _error(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AI 作品关联')),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680),
      child: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('通过兼容 OpenAI Chat Completions 的接口查找作品译名。只发送作品名称；候选名称由你确认后用于实际搜索，不自动绑定作品。Token 仅保存在本机，不参与云同步。'),
        SwitchListTile(title: const Text('启用 AI 作品关联'), value: _enabled,
          onChanged: _busy ? null : (value) => setState(() => _enabled = value)),
        SwitchListTile(title: const Text('联网检索作品资料'), value: _webSearch,
          subtitle: const Text('需要 API 基址支持 DeepSeek Search 协议。关闭后只使用模型已有知识。'),
          onChanged: _busy ? null : (value) => setState(() => _webSearch = value)),
        TextField(controller: _endpoint, enabled: !_busy,
          decoration: const InputDecoration(labelText: 'API 基址', hintText: 'https://api.deepseek.com')),
        TextField(controller: _model, enabled: !_busy,
          decoration: const InputDecoration(labelText: '模型')),
        TextField(controller: _token, enabled: !_busy, obscureText: true,
          enableSuggestions: false, autocorrect: false,
          decoration: const InputDecoration(labelText: 'API Token')),
        const SizedBox(height: 20),
        if (_busy) const LinearProgressIndicator(),
        if (_message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(_message!)),
        Wrap(spacing: 12, children: [
          OutlinedButton(onPressed: _busy ? null : () => _run(test: true), child: const Text('验证连接')),
          FilledButton(onPressed: _busy ? null : () => _run(test: false), child: const Text('保存')),
        ]),
      ]))),
  );
}

Future<String?> chooseAiTitle(BuildContext context, NovelService service,
    String title, {required bool toAnime}) async {
  if (!service.aiSettings.enabled) {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NovelAiPage(service: service)));
    if (!context.mounted || !service.aiSettings.enabled) return null;
  }
  return showDialog<String>(context: context, builder: (_) =>
    _AiTitleDialog(service: service, title: title, toAnime: toAnime));
}

class _AiTitleDialog extends StatefulWidget {
  const _AiTitleDialog({required this.service, required this.title, required this.toAnime});
  final NovelService service;
  final String title;
  final bool toAnime;
  @override
  State<_AiTitleDialog> createState() => _AiTitleDialogState();
}

class _AiTitleDialogState extends State<_AiTitleDialog> {
  final _cancel = CancelToken();
  Future<List<String>>? _titles;
  Future<List<String>> _query() => widget.service.suggestTitles(widget.title,
    toAnime: widget.toAnime, cancelToken: _cancel);
  @override
  void dispose() { _cancel.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) => FutureBuilder<List<String>>(
    future: _titles ??= _query(),
    builder: (context, snapshot) => AlertDialog(
    title: const Text('AI 关联候选'),
    content: SizedBox(width: 460, child: Builder(builder: (context) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(), SizedBox(height: 12), Text('正在查询作品名称…')]);
        }
        if (snapshot.hasError) return Text(_error(snapshot.error!));
        if (snapshot.data!.isEmpty) return const Text('AI 没有找到可信的对应名称。');
        return SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
          children: [const Text('选择名称后查询实际来源，AI 候选不代表作品已关联。'),
            for (final title in snapshot.data!) ListTile(title: Text(title),
              trailing: const Icon(Icons.search), onTap: () => Navigator.pop(context, title)),
          ]));
      })),
    actions: [if (snapshot.connectionState == ConnectionState.done)
      TextButton(onPressed: () => setState(() { _titles = null; }), child: const Text('重新查询')),
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))],
  ));
}
