import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_accounts.dart';
import 'package:kazumi/novel/novel_http_session.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_rule.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HttpServer server;
  late Dio dio;
  late NovelRule rule;
  late NovelHttpSession http;
  late NovelAccounts accounts;
  const credentials = NovelCredentialStore();
  late String base;
  late int generation, logins, reads;
  late bool rejectBook, htmlLogin;
  Completer<void>? loginGate;
  HttpOverrides? previous;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    previous = HttpOverrides.current;
    HttpOverrides.global = null;
    directory = await Directory.systemTemp.createTemp('novel-accounts-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    generation = 1; logins = 0; reads = 0; rejectBook = false; htmlLogin = false; loginGate = null;
    server.listen((request) async {
      final response = request.response;
      final authenticated = request.cookies.any((cookie) => cookie.name == 'session' && cookie.value == '$generation');
      if (request.uri.path == '/login') {
        logins++;
        final fields = Uri.splitQueryString(await utf8.decoder.bind(request).join());
        if (loginGate != null) await loginGate!.future;
        if (fields['username'] == 'reader' && fields['password'] == 'saved-password') {
          response.cookies.add(Cookie('session', '$generation')..path = '/');
        }
        response.write('login submitted');
      } else if (request.uri.path == '/verify') {
        response.write(authenticated ? '<a id="logout">退出</a>' : '<form id="login"></form>');
      } else if (request.uri.path == '/error') {
        response.statusCode = 500;
      } else {
        reads++;
        if (authenticated && !rejectBook) {
          response.write('<div style="width:373px"><div><a><img src="/cover"></a></div>'
            '<b><a href="/book/1" title="Fixture">Fixture</a></b><p>作者:Author/分类:Test</p></div>');
        } else if (htmlLogin) {
          response.write('<form id="login"></form>');
        } else {
          response.statusCode = 302;
          response.headers.set('location', '/needs-login');
        }
      }
      await response.close();
    });
    final json = jsonDecode(File('novel_rules/wenku8.json').readAsStringSync()) as Map<String, dynamic>;
    json['encoding'] = 'utf-8';
    json['searchUrl'] = '$base/book?q=@keyword';
    json['loginRequiredUrlPattern'] = '^${RegExp.escape(base)}/needs-login';
    json['loginRequiredXPath'] = '//form[@id="login"]';
    json['login'] = {'url': '$base/login', 'verifyUrl': '$base/verify', 'verifySelector': '#logout',
      'usernameField': 'username', 'passwordField': 'password', 'fields': <String, String>{}};
    rule = NovelRule.decode(jsonEncode(json));
    dio = Dio();
    http = NovelHttpSession(() => dio, directory.path);
    accounts = NovelAccounts(http, credentials);
  });
  tearDown(() async {
    dio.close(force: true);
    await server.close(force: true);
    expect(directory.parent.absolute.path, Directory.systemTemp.absolute.path);
    await directory.delete(recursive: true);
    HttpOverrides.global = previous;
  });
  Future<NovelResponse> book() => http.fetch(rule, '$base/book', 'GET', rule.headers, {});
  Future<void> remember([String password = 'saved-password']) =>
    credentials.write(rule, NovelAccount('reader', password));

  test('stored credentials survive a new store, remain source-bound and can be deleted', () async {
    expect(await credentials.read(rule), isNull);
    await remember();
    expect((await const NovelCredentialStore().read(rule))!.password, 'saved-password');
    final other = NovelRule.decode(jsonEncode({...rule.json, 'id': 'other'}));
    expect(await credentials.read(other), isNull);
    final changed = jsonDecode(rule.encode()) as Map<String, dynamic>;
    changed['login']['url'] = '$base/another-login';
    await expectLater(credentials.read(NovelRule.decode(jsonEncode(changed))), throwsStateError);
    await credentials.delete(rule.id);
    expect(await credentials.read(rule), isNull);
  });
  test('a failed account edit cannot validate against the previous account cookie', () async {
    await http.login(rule, 'reader', 'saved-password');
    await expectLater(http.login(rule, 'other-reader', 'wrong-password'), throwsStateError);
  });
  test('an expired session renews once, including after restarting the HTTP session', () async {
    await remember();
    expect((await accounts.execute(rule, book)).body, contains('Fixture'));
    expect(logins, 1);
    await accounts.execute(rule, book);
    expect(logins, 1);
    generation++;
    http = NovelHttpSession(() => dio, directory.path);
    accounts = NovelAccounts(http, credentials);
    await accounts.execute(rule, book);
    expect(logins, 2);
    expect(reads, 5);
  });
  test('a login form detected by the real XPath parser renews and resumes search', () async {
    htmlLogin = true;
    await remember();
    final source = NovelAuthenticatedSource(XPathNovelAdapter(rule,
      (url, method, headers, body) => http.fetch(rule, url, method, headers, body)), rule, accounts);
    expect((await source.search('Fixture')).single.title, 'Fixture');
    expect(logins, 1);
  });
  test('missing credentials, anonymous rules and transport errors never fabricate login', () async {
    await expectLater(accounts.execute(rule, book), throwsA(isA<NovelLoginRequired>()));
    final anonymous = jsonDecode(rule.encode()) as Map<String, dynamic>..remove('login');
    await expectLater(accounts.execute(NovelRule.decode(jsonEncode(anonymous)), book), throwsA(isA<NovelLoginRequired>()));
    await remember();
    await expectLater(accounts.execute(rule,
      () => http.fetch(rule, '$base/error', 'GET', rule.headers, {})), throwsA(isA<DioException>()));
    expect(logins, 0);
  });
  test('wrong saved password or a rejected renewed session stops without a retry loop', () async {
    await remember('wrong-password');
    await expectLater(accounts.execute(rule, book), throwsStateError);
    expect(logins, 1);
    await remember();
    rejectBook = true;
    await expectLater(accounts.execute(rule, book), throwsA(isA<NovelLoginRequired>()));
    expect(logins, 2);
    expect(reads, 3);
  });
  test('concurrent expired requests share a single login', () async {
    await remember();
    loginGate = Completer<void>();
    final first = accounts.execute(rule, book);
    final second = accounts.execute(rule, book);
    while (reads < 2 || logins < 1) { await Future<void>.delayed(const Duration(milliseconds: 5)); }
    loginGate!.complete();
    expect((await Future.wait([first, second])).length, 2);
    expect(logins, 1);
  });
  test('a late expired response uses the session already renewed by another request', () async {
    await remember();
    final delayed = Completer<void>();
    var attempts = 0;
    final late = accounts.execute(rule, () async {
      if (attempts++ == 0) { await delayed.future; throw const NovelLoginRequired(); }
      return book();
    });
    await accounts.execute(rule, book);
    delayed.complete();
    expect((await late).body, contains('Fixture'));
    expect(logins, 1);
  });
  test('clearing an account during renewal leaves no authenticated session', () async {
    await remember();
    loginGate = Completer<void>();
    final renewing = accounts.execute(rule, book);
    while (logins == 0) { await Future<void>.delayed(const Duration(milliseconds: 5)); }
    final cleared = accounts.logout(rule);
    final completed = renewing.then((_) {}, onError: (Object error) {
      expect(error, isA<NovelLoginRequired>());
    });
    loginGate!.complete();
    await cleared;
    await completed;
    expect(await credentials.read(rule), isNull);
    await expectLater(book(), throwsA(isA<NovelLoginRequired>()));
  });
  test('manual login persists only verified credentials and supersedes a queued renewal', () async {
    loginGate = Completer<void>();
    final manual = accounts.login(rule, const NovelAccount('reader', 'saved-password'));
    while (logins == 0) { await Future<void>.delayed(const Duration(milliseconds: 5)); }
    final request = accounts.execute(rule, book);
    while (reads == 0) { await Future<void>.delayed(const Duration(milliseconds: 5)); }
    loginGate!.complete();
    await manual;
    await request;
    expect(logins, 1);
    expect((await credentials.read(rule))!.username, 'reader');
    await expectLater(accounts.login(rule, const NovelAccount('wrong', 'wrong')), throwsStateError);
    expect((await credentials.read(rule))!.username, 'reader');
  });
  test('source wrapper resumes book details, catalog and chapter content', () async {
    await remember();
    final delegate = _Source(book);
    final source = NovelAuthenticatedSource(delegate, rule, accounts);
    final found = await source.bookFromUrl('$base/book');
    generation++;
    final chapters = await source.catalog(found);
    generation++;
    expect((await source.content(chapters.single)).single.value, 'body');
    expect(logins, 3);
    expect(delegate.calls, ['details', 'details', 'catalog', 'catalog', 'content', 'content']);
  });
}

class _Source implements NovelSourceAdapter {
  _Source(this.read);
  final Future<NovelResponse> Function() read;
  final calls = <String>[];
  @override Future<NovelBook> bookFromUrl(String url) async {
    calls.add('details'); await read();
    return NovelBook(sourceId: 'wenku8', url: url, title: 'Fixture', author: 'Author', cover: '');
  }
  @override Future<List<NovelChapter>> catalog(NovelBook book) async {
    calls.add('catalog'); await read();
    return [NovelChapter(url: '${book.url}/1', title: 'Chapter', kind: 'text', volume: 'Volume')];
  }
  @override Future<List<NovelBlock>> content(NovelChapter chapter) async {
    calls.add('content'); await read(); return [const NovelBlock.text('body')];
  }
  @override Future<List<NovelBook>> search(String keyword) => throw UnimplementedError();
}
