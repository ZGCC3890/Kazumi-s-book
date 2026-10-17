import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'novel_http_session.dart';
import 'novel_models.dart';
import 'novel_rule.dart';

class NovelAccount {
  const NovelAccount(this.username, this.password);
  final String username, password;
}

/// Credentials are bound to the login endpoints the reader explicitly used.
class NovelCredentialStore {
  const NovelCredentialStore();
  static const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false, storageNamespace: 'kazumis_book_accounts'),
    wOptions: WindowsOptions(useBackwardCompatibility: false),
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  String _key(String id) => 'kazumisbook.novel.account.v1.$id';
  Future<NovelAccount?> read(NovelRule rule) async {
    final raw = await storage.read(key: _key(rule.id));
    if (raw == null) return null;
    final value = jsonDecode(raw) as Map<String, dynamic>;
    final login = rule.json['login'] as Map;
    if (value['loginUrl'] != login['url'] || value['verifyUrl'] != login['verifyUrl']) {
      throw StateError('书源登录地址已更改，请重新登录以确认新的站点');
    }
    return NovelAccount(value['username'] as String, value['password'] as String);
  }
  Future<void> write(NovelRule rule, NovelAccount account) => storage.write(
    key: _key(rule.id), value: jsonEncode({
      'username': account.username, 'password': account.password,
      'loginUrl': (rule.json['login'] as Map)['url'],
      'verifyUrl': (rule.json['login'] as Map)['verifyUrl'],
    }));
  Future<void> delete(String id) => storage.delete(key: _key(id));
}

/// Only an explicit login-required response renews a saved account session.
class NovelAccounts {
  NovelAccounts(this.http, this.credentials);
  final NovelHttpSession http;
  final NovelCredentialStore credentials;
  final _renewing = <String, Future<void>>{};
  final _versions = <String, int>{};
  final _queues = <String, AsyncSerialQueue>{};
  AsyncSerialQueue _queue(String id) => _queues.putIfAbsent(id, AsyncSerialQueue.new);
  void _changed(String id) => _versions[id] = (_versions[id] ?? 0) + 1;

  Future<void> login(NovelRule rule, NovelAccount account) => _queue(rule.id).run(() async {
    await http.login(rule, account.username, account.password);
    await credentials.write(rule, account);
    _changed(rule.id);
  });
  Future<void> logout(NovelRule rule) => _queue(rule.id).run(() async {
    await credentials.delete(rule.id);
    await http.logout(rule);
    _changed(rule.id);
  });

  Future<T> execute<T>(NovelRule rule, Future<T> Function() operation) async {
    final version = _versions[rule.id] ?? 0;
    try {
      return await operation();
    } on NovelLoginRequired {
      if (rule.json['login'] == null) rethrow;
      if ((_versions[rule.id] ?? 0) == version) {
        final pending = _renewing[rule.id];
        if (pending != null) {
          await pending;
        } else {
          final renewal = _queue(rule.id).run(() async {
            if ((_versions[rule.id] ?? 0) == version) await _renew(rule);
          });
          _renewing[rule.id] = renewal;
          try { await renewal; } finally { _renewing.remove(rule.id); }
        }
      }
      return operation();
    }
  }

  Future<void> _renew(NovelRule rule) async {
    final account = await credentials.read(rule);
    if (account == null) throw const NovelLoginRequired();
    await http.login(rule, account.username, account.password);
    _changed(rule.id);
  }
}

class NovelAuthenticatedSource implements NovelSourceAdapter {
  const NovelAuthenticatedSource(this.source, this.rule, this.accounts);
  final NovelSourceAdapter source;
  final NovelRule rule;
  final NovelAccounts accounts;
  @override
  Future<List<NovelBook>> search(String keyword) => accounts.execute(rule, () => source.search(keyword));
  @override
  Future<NovelBook> bookFromUrl(String url) => accounts.execute(rule, () => source.bookFromUrl(url));
  @override
  Future<List<NovelChapter>> catalog(NovelBook book) => accounts.execute(rule, () => source.catalog(book));
  @override
  Future<List<NovelBlock>> content(NovelChapter chapter) => accounts.execute(rule, () => source.content(chapter));
}
