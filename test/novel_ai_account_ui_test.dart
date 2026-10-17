import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:kazumi/novel/novel_ai.dart';
import 'package:kazumi/novel/novel_ai_page.dart';
import 'package:kazumi/novel/novel_account_dialog.dart';
import 'package:kazumi/novel/novel_rule.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/services/sync/webdav.dart';

class _Launcher extends UrlLauncherPlatform {
  @override LinkDelegate? get linkDelegate => null;
  bool success = true;
  String? opened;
  @override Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened = url;
    return success;
  }
}

class _Service extends NovelService {
  _Service() : super(WebDav());
  NovelAiSettings settings = const NovelAiSettings();
  @override NovelAiSettings get aiSettings => settings;
  int saves = 0, queries = 0, verifications = 0, logins = 0;
  String username = 'previous-user';
  Object? failure;
  List<String> candidates = ['候选名称'];
  Completer<List<String>>? pending;
  CancelToken? cancel;
  @override Future<void> saveAiSettings(NovelAiSettings value) async {
    value.validate(); settings = value; saves++;
  }
  @override Future<List<String>> suggestTitles(String title, {required bool toAnime,
      NovelAiSettings? settings, CancelToken? cancelToken}) async {
    queries++;
    cancel = cancelToken;
    if (failure != null) throw failure!;
    return pending == null ? candidates : pending!.future;
  }
  @override List<NovelRule> get rules => ['wenku8', 'linovel'].map((id) =>
    NovelRule.decode(File('novel_rules/$id.json').readAsStringSync())).toList();
  @override String accountName(String sourceId) => username;
  @override Future<void> verifyAccount(String sourceId) async {
    verifications++;
    if (failure != null) throw failure!;
  }
  @override Future<void> login(String sourceId, String name, String password) async {
    logins++;
    if (failure != null) throw failure!;
    username = name;
  }
  @override Future<void> logout(String sourceId) async { username = ''; }
}

Future<void> _home(WidgetTester tester, _Service service, {bool account = false, String source = 'wenku8',
    void Function(String?)? selected}) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) =>
    TextButton(onPressed: () async {
      if (account) {
        await showNovelAccount(context, service, source);
      } else {
        selected?.call(await chooseAiTitle(context, service, '测试标题', toAnime: false));
      }
    }, child: const Text('open'))))));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late _Service service;
  late _Launcher launcher;
  setUp(() { service = _Service(); launcher = _Launcher(); UrlLauncherPlatform.instance = launcher; });
  tearDown(() => service.dispose());
  testWidgets('AI settings validate, save, reopen and test without implicitly saving', (tester) async {
    await tester.pumpWidget(MaterialApp(home: NovelAiPage(service: service)));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请填写模型'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'API 基址'), 'https://api.test/v1');
    await tester.enterText(find.widgetWithText(TextField, '模型'), 'fixture-model');
    await tester.enterText(find.widgetWithText(TextField, 'API Token'), 'fixture-token');
    await tester.tap(find.widgetWithText(SwitchListTile, '启用 AI 作品关联'));
    await tester.tap(find.widgetWithText(SwitchListTile, '联网检索作品资料'));
    await tester.tap(find.text('验证连接'));
    await tester.pumpAndSettle();
    expect(service.saves, 0);
    expect(find.text('连接验证成功，设置尚未保存'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(service.settings.enabled, true);
    expect(service.settings.token, 'fixture-token');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(home: NovelAiPage(service: service)));
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'API Token')).controller!.text, 'fixture-token');
    service.failure = DioException(requestOptions: RequestOptions(), type: DioExceptionType.connectionTimeout);
    await tester.tap(find.text('验证连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('connectionTimeout'), findsOneWidget);
  });
  testWidgets('disabled AI opens settings and cancel never requests a title', (tester) async {
    String? selection = 'unchanged';
    await _home(tester, service, selected: (v) => selection = v);
    expect(find.byType(NovelAiPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(service.queries, 0);
    expect(selection, isNull);
  });
  testWidgets('candidate selection, empty response, failure retry and request cancellation', (tester) async {
    service.settings = const NovelAiSettings(enabled: true, token: 'fixture-token');
    String? selection;
    await _home(tester, service, selected: (v) => selection = v);
    await tester.tap(find.text('候选名称'));
    await tester.pumpAndSettle();
    expect(selection, '候选名称');
    service.candidates = [];
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('没有找到可信'), findsOneWidget);
    service.failure = StateError('AI fixture error');
    await tester.tap(find.text('重新查询'));
    await tester.pumpAndSettle();
    expect(find.textContaining('AI fixture error'), findsOneWidget);
    service.failure = DioException(requestOptions: RequestOptions(),
      response: Response(requestOptions: RequestOptions(), statusCode: 401));
    await tester.tap(find.text('重新查询'));
    await tester.pumpAndSettle();
    expect(find.textContaining('401'), findsOneWidget);
    service.failure = null;
    service.pending = Completer<List<String>>();
    await tester.tap(find.text('重新查询'));
    await tester.pump();
    expect(find.text('正在查询作品名称…'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(service.cancel!.isCancelled, true);
    service.pending!.complete(['迟到结果']);
    await tester.pumpAndSettle();
    expect(find.text('迟到结果'), findsNothing);
  });
  testWidgets('source account edits, verifies and clears only its local session', (tester) async {
    await _home(tester, service, account: true);
    expect(find.text('previous-user'), findsOneWidget);
    await tester.tap(find.text('验证当前会话'));
    await tester.pumpAndSettle();
    expect(find.text('当前登录会话验证成功'), findsOneWidget);
    service.failure = StateError('expired');
    await tester.tap(find.text('验证当前会话'));
    await tester.pumpAndSettle();
    expect(find.textContaining('expired'), findsOneWidget);
    service.failure = null;
    await tester.tap(find.text('清除登录'));
    await tester.pumpAndSettle();
    expect(service.username, isEmpty);
    await tester.tap(find.text('登录并验证'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请填写书源'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '书源用户名'), 'new-user');
    await tester.enterText(find.widgetWithText(TextField, '密码'), 'test-password');
    service.failure = StateError('wrong password');
    await tester.tap(find.text('登录并验证'));
    await tester.pumpAndSettle();
    expect(find.textContaining('wrong password'), findsOneWidget);
    service.failure = null;
    await tester.tap(find.text('登录并验证'));
    await tester.pumpAndSettle();
    expect(service.username, 'new-user');
    expect(find.byType(NovelAccountDialog), findsNothing);
  });
  testWidgets('anonymous rules expose the source website and do not invent a login form', (tester) async {
    await _home(tester, service, account: true, source: 'linovel');
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('打开书源网站 / 注册'));
    await tester.pumpAndSettle();
    expect(launcher.opened, 'https://www.linovel.net');
    launcher.success = false;
    await tester.tap(find.text('打开书源网站 / 注册'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法打开书源网站'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(NovelAccountDialog), findsNothing);
  });
}
