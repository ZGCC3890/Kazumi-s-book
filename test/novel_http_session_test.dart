import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_http_session.dart';
import 'package:kazumi/novel/novel_rule.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('one source login persists its session across restarts without storing password', () async {
    final original = HttpOverrides.current;
    HttpOverrides.global = null;
    final directory = await Directory.systemTemp.createTemp('novel_session_');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    var loginRequests = 0;
    final requests = <String>[];
    final subscription = server.listen((request) async {
      requests.add(request.uri.path);
      final response = request.response;
      if (request.uri.path == '/login') {
        loginRequests++;
        final form = Uri.splitQueryString(await utf8.decoder.bind(request).join());
        expect(form['username'], 'fixture');
        expect(form['password'], 'private-password');
        response.cookies.add(Cookie('reading_session', 'session-cookie')..path = '/');
        response.statusCode = 302;
        response.headers.set('location', '/verified');
      } else if (request.cookies.any((c) => c.name == 'reading_session' && c.value == 'session-cookie')) {
        expect(request.headers.value('user-agent'), 'KazumisBook/0.1.0');
        expect(request.headers.value('accept-encoding'), 'identity');
        response.write('<div id="authenticated">fixture book</div>');
      } else {
        response.statusCode = 302;
        response.headers.set('location', '/needs-login');
      }
      await response.close();
    });
    final json = jsonDecode(await File('novel_rules/wenku8.json').readAsString()) as Map<String, dynamic>;
    json['encoding'] = 'utf-8';
    json['loginRequiredUrlPattern'] = '^${RegExp.escape(base)}/needs-login';
    json['login'] = {'url': '$base/login', 'usernameField': 'username', 'passwordField': 'password',
      'fields': <String, String>{}, 'verifyUrl': '$base/verified', 'verifySelector': '#authenticated'};
    final rule = NovelRule.decode(jsonEncode(json));
    final dio = Dio();
    try {
      var session = NovelHttpSession(dio, directory.path);
      await expectLater(session.fetch(rule, '$base/book', 'GET', rule.headers, {}),
        throwsA(isA<NovelLoginRequired>()));
      await session.login(rule, 'fixture', 'private-password');
      session = NovelHttpSession(dio, directory.path);
      expect((await session.fetch(rule, '$base/book', 'GET', rule.headers, {})).body, contains('fixture book'));
      expect(await session.image(rule, '$base/image'), isNotEmpty);
      expect(loginRequests, 1);
      expect(requests, isNot(contains('/needs-login')));
      final stored = await directory.list(recursive: true).where((e) => e is File).cast<File>().toList();
      for (final file in stored) {
        expect(await file.readAsString(), isNot(contains('private-password')));
      }
      await session.logout(rule);
      await expectLater(session.fetch(rule, '$base/book', 'GET', rule.headers, {}),
        throwsA(isA<NovelLoginRequired>()));
    } finally {
      dio.close();
      await subscription.cancel();
      await server.close(force: true);
      await directory.delete(recursive: true);
      HttpOverrides.global = original;
    }
  });
}
