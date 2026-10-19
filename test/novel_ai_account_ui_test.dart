import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:kazumi/novel/novel_ai.dart';
import 'package:kazumi/novel/novel_ai_page.dart';
import 'package:kazumi/novel/novel_ai_choice.dart';
import 'package:kazumi/novel/novel_ai_providers.dart';
import 'package:kazumi/novel/novel_account_dialog.dart';
import 'package:kazumi/novel/novel_rule.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/novel/novel_accounts.dart';
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
  Completer<NovelAccount?>? pendingAccount;
  Completer<void>? pendingLogout;
  CancelToken? cancel;
  @override Future<void> saveAiSettings(NovelAiSettings value) async {
    value.validate(); settings = value; saves++;
  }
  @override Future<List<String>> suggestTitles(String title, {required bool toAnime,
      bool sameNovel = false, NovelAiSettings? settings, CancelToken? cancelToken}) async {
    queries++;
    cancel = cancelToken;
    if (failure != null) throw failure!;
    return pending == null ? candidates : pending!.future;
  }
  @override List<NovelRule> get rules => ['wenku8', 'linovel'].map((id) =>
    NovelRule.decode(File('novel_rules/$id.json').readAsStringSync())).toList();
  @override String accountName(String sourceId) => username;
  @override Future<NovelAccount?> accountCredentials(String sourceId) async =>
    pendingAccount == null ? NovelAccount(username, 'saved-password') : pendingAccount!.future;
  @override Future<void> verifyAccount(String sourceId) async {
    verifications++;
    if (failure != null) throw failure!;
  }
  @override Future<void> login(String sourceId, String name, String password) async {
    logins++;
    if (failure != null) throw failure!;
    username = name;
  }
  @override Future<void> logout(String sourceId) async {
    if (pendingLogout != null) await pendingLogout!.future;
    username = '';
  }
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

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _choice(String label) => find.byWidgetPredicate((w) => w is NovelAiChoice && w.label == label);

Future<void> _select(WidgetTester tester, String label, String query, String result) async {
  await _tap(tester, _choice(label));
  await tester.enterText(find.widgetWithText(TextField, '搜索$label'), query);
  await tester.pump();
  await _tap(tester, find.widgetWithText(ListTile, result));
}

void main() {
  late _Service service;
  late _Launcher launcher;
  setUp(() { service = _Service(); launcher = _Launcher(); UrlLauncherPlatform.instance = launcher; });
  tearDown(() => service.dispose());
  testWidgets('AI settings validate, save, reopen and test without implicitly saving', (tester) async {
    await tester.pumpWidget(MaterialApp(home: NovelAiPage(service: service)));
    await _tap(tester, find.text('保存'));
    expect(find.textContaining('请选择模型'), findsOneWidget);
    await _select(tester, '供应商 Provider', '自定义', '自定义 OpenAI 兼容接口');
    await tester.enterText(find.widgetWithText(TextField, 'API 基址'), 'https://api.test/v1');
    await tester.enterText(find.widgetWithText(TextField, '模型 ID'), 'fixture-model');
    await tester.enterText(find.widgetWithText(TextField, 'API Key'), 'fixture-token');
    await _tap(tester, find.widgetWithText(SwitchListTile, '启用 AI 作品关联'));
    await _tap(tester, find.widgetWithText(SwitchListTile, '联网检索作品资料'));
    await _tap(tester, find.text('验证连接'));
    expect(service.saves, 0);
    expect(find.text('连接验证成功，设置尚未保存'), findsOneWidget);
    await _tap(tester, find.text('保存'));
    expect(service.settings.enabled, true);
    expect(service.settings.token, 'fixture-token');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(home: NovelAiPage(service: service)));
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'API Key')).controller!.text, 'fixture-token');
    service.failure = DioException(requestOptions: RequestOptions(), type: DioExceptionType.connectionTimeout);
    await _tap(tester, find.text('验证连接'));
    expect(find.textContaining('connectionTimeout'), findsOneWidget);
  });
  test('provider matching recognizes existing endpoints without rewriting custom URLs', () {
    for (final provider in novelAiProviders) {
      expect(NovelAiProvider.forEndpoint('${provider.endpoint}/'), same(provider));
    }
    expect(NovelAiProvider.forEndpoint('https://api.deepseek.com/v1')!.id, 'deepseek');
    expect(NovelAiProvider.forEndpoint('https://api.deepseek.com/proxy'), isNull);
    expect(NovelAiProvider.forEndpoint('https://api.test/v1'), isNull);
  });
  for (final width in [360.0, 1280.0]) {
    testWidgets('searchable provider and model selection saves exact IDs at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      service.settings = const NovelAiSettings(token: 'previous-key');
      await tester.pumpWidget(MaterialApp(builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.5)), child: child!),
        home: NovelAiPage(service: service)));
      final key = find.widgetWithText(TextField, 'API Key');
      await _select(tester, '供应商 Provider', 'OPENAI', 'OpenAI');
      expect(tester.widget<TextField>(key).controller!.text, isEmpty);
      expect(tester.widget<NovelAiChoice>(_choice('模型')).value, isEmpty);
      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '联网检索作品资料')).value, false);
      await _tap(tester, _choice('模型'));
      await tester.enterText(find.widgetWithText(TextField, '搜索模型'), 'not-a-real-model');
      await tester.pump();
      expect(find.text('没有匹配项'), findsOneWidget);
      await _tap(tester, find.text('取消'));
      await _tap(tester, find.text('保存'));
      expect(service.saves, 0);
      await _select(tester, '模型', '4.1-mini', 'gpt-4.1-mini');
      await tester.ensureVisible(key);
      await tester.enterText(key, 'openai-fixture-key');
      await _select(tester, '供应商 Provider', 'OPENAI', 'OpenAI');
      expect(tester.widget<TextField>(key).controller!.text, 'openai-fixture-key');
      await _tap(tester, find.text('保存'));
      expect(service.settings.endpoint, 'https://api.openai.com/v1');
      expect(service.settings.model, 'gpt-4.1-mini');
      expect(service.settings.token, 'openai-fixture-key');
      expect(service.settings.webSearch, false);
      await _select(tester, '供应商 Provider', 'deepseek', 'DeepSeek');
      await _select(tester, '模型', 'flash', 'deepseek-flash');
      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, '联网检索作品资料')).value, true);
      expect(tester.widget<TextField>(key).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('saved unlisted model is preserved and custom endpoint changes clear old credentials', (tester) async {
    service.settings = const NovelAiSettings(endpoint: 'https://api.deepseek.com/v1/',
      model: 'legacy-model', token: 'saved-key');
    await tester.pumpWidget(MaterialApp(home: NovelAiPage(service: service)));
    expect(find.text('legacy-model（当前配置）'), findsOneWidget);
    await _select(tester, '模型', 'legacy', 'legacy-model（当前配置）');
    await _tap(tester, find.text('保存'));
    expect(service.settings.model, 'legacy-model');
    expect(service.settings.endpoint, 'https://api.deepseek.com/v1/');
    expect(service.settings.token, 'saved-key');
    await _select(tester, '供应商 Provider', 'custom', '自定义 OpenAI 兼容接口');
    await tester.enterText(find.widgetWithText(TextField, 'API 基址'), 'https://new.test/v1');
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'API Key')).controller!.text, isEmpty);
  });
  testWidgets('pending connection validation locks provider and model selection and cancels on exit', (tester) async {
    service.settings = const NovelAiSettings(token: 'saved-key');
    service.pending = Completer<List<String>>();
    await tester.pumpWidget(MaterialApp(home: NovelAiPage(service: service)));
    await tester.ensureVisible(find.text('验证连接'));
    await tester.tap(find.text('验证连接'));
    await tester.pump();
    for (final choice in tester.widgetList<NovelAiChoice>(find.byType(NovelAiChoice))) {
      expect(choice.onChanged, isNull);
    }
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'API Key')).enabled, false);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(service.cancel!.isCancelled, true);
    service.pending!.complete(['候选']);
    await tester.pump();
    expect(service.saves, 0);
    expect(tester.takeException(), isNull);
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
    expect(tester.widget<TextField>(find.widgetWithText(TextField, '密码')).controller!.text, 'saved-password');
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
  for (final outcome in ['empty', 'error', 'closed']) {
    testWidgets('saved account loading handles $outcome', (tester) async {
      service.pendingAccount = Completer<NovelAccount?>();
      await _home(tester, service, account: true);
      expect(tester.widget<TextField>(find.widgetWithText(TextField, '密码')).enabled, false);
      if (outcome == 'closed') {
        await tester.pumpWidget(const SizedBox());
        expect(find.byType(NovelAccountDialog), findsNothing);
      }
      if (outcome == 'error') {
        service.pendingAccount!.completeError(StateError('credential store error'));
      } else {
        service.pendingAccount!.complete(null);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (outcome == 'error') expect(find.textContaining('credential store error'), findsOneWidget);
      if (outcome == 'empty') expect(tester.widget<TextField>(find.widgetWithText(TextField, '密码')).controller!.text, isEmpty);
    });
  }
  testWidgets('system back during account clearing does not touch disposed fields', (tester) async {
    service.pendingLogout = Completer<void>();
    await _home(tester, service, account: true);
    await tester.tap(find.text('清除登录'));
    await tester.pump();
    Navigator.of(tester.element(find.byType(NovelAccountDialog))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(NovelAccountDialog), findsNothing);
    service.pendingLogout!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(service.username, isEmpty);
  });
}
