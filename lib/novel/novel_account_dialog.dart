import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'novel_rule.dart';
import 'novel_service.dart';

Future<bool?> showNovelAccount(BuildContext context, NovelService service, String source,
    {String submitLabel = '登录并验证'}) => showDialog<bool>(context: context,
  barrierDismissible: false, builder: (_) => NovelAccountDialog(
    service: service, rule: service.rule(source), submitLabel: submitLabel));

class NovelAccountDialog extends StatefulWidget {
  const NovelAccountDialog({super.key, required this.service, required this.rule,
    this.submitLabel = '登录并验证'});
  final NovelService service;
  final NovelRule rule;
  final String submitLabel;
  @override
  State<NovelAccountDialog> createState() => _NovelAccountDialogState();
}

class _NovelAccountDialogState extends State<NovelAccountDialog> {
  late final _username = TextEditingController(text: widget.rule.json['login'] == null
    ? '' : widget.service.accountName(widget.rule.id));
  final _password = TextEditingController();
  bool _busy = false;
  String? _message;
  @override
  void dispose() { _username.dispose(); _password.dispose(); super.dispose(); }
  Future<void> _run(String action) async {
    final owner = ModalRoute.of(context)!;
    setState(() { _busy = true; _message = null; });
    try {
      switch (action) {
        case 'website':
          if (!await launchUrl(widget.rule.website, mode: LaunchMode.externalApplication)) {
            throw StateError('无法打开书源网站');
          }
        case 'verify':
          await widget.service.verifyAccount(widget.rule.id);
          _message = '当前登录会话验证成功';
        case 'logout':
          await widget.service.logout(widget.rule.id);
          _username.clear();
          _password.clear();
          _message = '已清除本机登录会话';
        case 'login':
          if (_username.text.trim().isEmpty || _password.text.isEmpty) {
            throw const FormatException('请填写书源用户名和密码');
          }
          await widget.service.login(widget.rule.id, _username.text.trim(), _password.text);
          if (!mounted || !owner.isActive) return;
          _password.clear();
          Navigator.pop(context, true);
      }
    } catch (error) {
      _message = error.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  @override
  Widget build(BuildContext context) {
    final supportsLogin = widget.rule.json['login'] != null;
    return AlertDialog(
      title: Text('${widget.rule.name} · 书源账号'),
      content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(widget.rule.website.toString()),
          TextButton.icon(onPressed: _busy ? null : () => _run('website'),
            icon: const Icon(Icons.open_in_new), label: const Text('打开书源网站 / 注册')),
          if (supportsLogin) ...[
            const Text('账号名和登录会话只保存在本机，密码不保存。修改账号后重新登录并验证，不参与云同步。'),
            TextField(controller: _username, enabled: !_busy, autocorrect: false,
              decoration: const InputDecoration(labelText: '书源用户名')),
            TextField(controller: _password, enabled: !_busy, obscureText: true,
              enableSuggestions: false, autocorrect: false,
              decoration: const InputDecoration(labelText: '密码')),
            Wrap(children: [
              TextButton(onPressed: _busy ? null : () => _run('verify'), child: const Text('验证当前会话')),
              TextButton(onPressed: _busy ? null : () => _run('logout'), child: const Text('清除登录')),
            ]),
          ] else const Text('这条规则未声明客户端登录和验证协议，当前使用匿名访问。可打开网站注册；网站登录不会自动导入本机。'),
          if (_busy) const LinearProgressIndicator(),
          if (_message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message!)),
        ],
      ))),
      actions: [TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false),
        child: const Text('取消')),
        if (supportsLogin) FilledButton(onPressed: _busy ? null : () => _run('login'),
          child: Text(widget.submitLabel))],
    );
  }
}
