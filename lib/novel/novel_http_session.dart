import 'dart:convert';
import 'dart:typed_data';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:enough_convert/gbk.dart';
import 'package:html/parser.dart' as html;
import 'novel_models.dart';
import 'novel_rule.dart';

/// Source-specific sessions stay on this device. Passwords are never persisted.
class NovelHttpSession {
  NovelHttpSession(this._client, this.directory);
  final Dio Function() _client;
  final String directory;
  final _jars = <String, PersistCookieJar>{};
  PersistCookieJar _jar(NovelRule rule) => _jars.putIfAbsent(
    rule.id,
    () => PersistCookieJar(
      persistSession: true,
      storage: FileStorage('$directory/${rule.id}/'),
    ),
  );

  Encoding _codec(NovelRule rule) => rule.json['encoding'] == 'gbk'
      ? const GbkCodec(allowInvalid: false)
      : utf8;

  Future<Response<List<int>>> _request(
    NovelRule rule,
    String address,
    String method,
    Map<String, String> headers,
    Map<String, String> body,
  ) async {
    var uri = Uri.parse(address);
    final visited = <String>{};
    String form(String value) => _codec(rule)
        .encode(value)
        .map((b) => '%${b.toRadixString(16).padLeft(2, '0')}')
        .join();
    final jar = _jar(rule);
    while (true) {
      if (!visited.add('$method $uri')) throw StateError('书源重定向循环：$uri');
      final cookies = await jar.loadForRequest(uri);
      final response = await _client().request<List<int>>(
        uri.toString(),
        data: method == 'POST'
            ? body.entries
                  .map((e) => '${form(e.key)}=${form(e.value)}')
                  .join('&')
            : null,
        options: Options(
          method: method,
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (status) =>
              status != null && status >= 200 && status < 400,
          contentType: method == 'POST'
              ? Headers.formUrlEncodedContentType
              : null,
          headers: {
            ...headers,
            if (cookies.isNotEmpty)
              'Cookie': cookies.map((c) => '${c.name}=${c.value}').join('; '),
          },
        ),
      );
      await jar.saveFromResponse(
        uri,
        (response.headers['set-cookie'] ?? [])
            .map(Cookie.fromSetCookieValue)
            .toList(),
      );
      if (![301, 302, 303, 307, 308].contains(response.statusCode))
        return response;
      final next = uri.resolve(response.headers.value('location')!);
      if (RegExp(
            rule.json['loginRequiredUrlPattern'] as String,
          ).hasMatch(next.toString()) &&
          (rule.json['loginRequiredUrlPattern'] as String).isNotEmpty) {
        throw const NovelLoginRequired();
      }
      if (next.host != uri.host ||
          !['http', 'https'].contains(next.scheme) ||
          (uri.scheme == 'https' && next.scheme != 'https')) {
        throw StateError('书源重定向超出当前站点或降低连接安全性：$next');
      }
      if (response.statusCode == 303 ||
          (method == 'POST' && [301, 302].contains(response.statusCode)))
        method = 'GET';
      uri = next;
    }
  }

  Future<NovelResponse> fetch(
    NovelRule rule,
    String url,
    String method,
    Map<String, String> headers,
    Map<String, String> body,
  ) async {
    final response = await _request(rule, url, method, headers, body);
    return NovelResponse(
      _codec(rule).decode(response.data!),
      response.realUri.toString(),
    );
  }

  Future<Uint8List> image(NovelRule rule, String url) async =>
      Uint8List.fromList(
        (await _request(rule, url, 'GET', rule.headers, {})).data!,
      );

  Future<void> login(NovelRule rule, String username, String password) async {
    final spec = rule.json['login'] as NovelJson;
    await fetch(rule, spec['url'] as String, 'POST', rule.headers, {
      ...Map<String, String>.from(spec['fields'] as Map),
      spec['usernameField'] as String: username,
      spec['passwordField'] as String: password,
    });
    final verified = await fetch(
      rule,
      spec['verifyUrl'] as String,
      'GET',
      rule.headers,
      {},
    );
    if (RegExp(
          rule.json['loginRequiredUrlPattern'] as String,
        ).hasMatch(verified.url) ||
        html
                .parse(verified.body)
                .querySelector(spec['verifySelector'] as String) ==
            null) {
      throw StateError('登录未成功，请确认账号密码或在站点完成必要验证');
    }
  }

  Future<void> logout(NovelRule rule) => _jar(rule).deleteAll();
}
