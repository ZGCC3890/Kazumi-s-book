import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:kazumi/bean/dialog/rule_add_dialog.dart';
import 'package:kazumi/novel/novel_rule.dart';
import 'package:kazumi/novel/novel_rules_page.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/services/storage/storage.dart';

String get _raw => File('novel_rules/linovel.json').readAsStringSync();

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override Future<String?> getApplicationSupportPath() async => path;
}

class _Rules extends NovelService {
  _Rules() : super(WebDav());
  final installed = <String, NovelRule>{};
  int writes = 0;
  String? url;
  @override List<NovelRule> get rules => installed.values.toList();
  @override String? get ruleCatalogUrl => url;
  @override Future<void> saveRuleCatalogUrl(String value) async { url = value; }
  @override Future<void> importRules(Iterable<NovelRule> rules) async {
    writes++;
    for (final rule in rules) { installed[rule.id] = rule; }
    notifyListeners();
  }
  @override Future<void> removeRule(String id) async { installed.remove(id); notifyListeners(); }
}

class _Picker extends FilePicker {
  FilePickerResult? result;
  bool? requestedData;
  @override Future<FilePickerResult?> pickFiles({String? dialogTitle, String? initialDirectory,
    FileType type = FileType.any, List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading, bool allowCompression = false,
    int compressionQuality = 0, bool allowMultiple = false, bool withData = false,
    bool withReadStream = false, bool lockParentWindow = false, bool readSequential = false}) async {
    requestedData = withData;
    return result;
  }
}

Future<void> _open(WidgetTester tester, _Rules service, {
  Future<String> Function(String)? readText, double scale = 1, Size size = const Size(480, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() async { await tester.pumpWidget(const SizedBox.shrink()); service.dispose(); });
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale)), child: child!),
    home: NovelRulesPage(service: service,
      readText: readText ?? (_) => throw StateError('Unexpected rule download')),
  ));
  await tester.pumpAndSettle();
}

Future<void> _add(WidgetTester tester, String option) async {
  await tester.tap(find.text('添加规则'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  setUpAll(() async {
    paths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('novel-rule-ui-');
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
    // Native plugin registration is owned by this test isolate.
    FilePicker.platform = _Picker();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    expect(root.parent.absolute.path, Directory.systemTemp.absolute.path);
    expect(root.uri.pathSegments.where((part) => part.isNotEmpty).last, startsWith('novel-rule-ui-'));
    await root.delete(recursive: true);
  });
  testWidgets('shared anime add dialog retains all four existing choices', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => showRuleAddDialog(context), child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    for (final label in ['浏览规则仓库', '从剪贴板导入', '从文件导入', '新建规则']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.textContaining('番剧来源'), findsOneWidget);
  });

  for (final size in [const Size(360, 900), const Size(1280, 900)]) {
    testWidgets('novel add choices stay simple at double text scale $size', (tester) async {
      await _open(tester, _Rules(), scale: 2, size: size);
      expect(find.text('规则索引 URL'), findsNothing);
      await tester.tap(find.text('添加规则'));
      await tester.pumpAndSettle();
      expect(find.text('浏览规则仓库'), findsOneWidget);
      expect(find.text('从剪贴板导入'), findsOneWidget);
      expect(find.text('从文件导入'), findsOneWidget);
      expect(find.text('新建规则'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('clipboard failures keep editable input; invalid mixed batch never writes', (tester) async {
    final service = _Rules();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async =>
      call.method == 'Clipboard.getData' ? {'text': 'https://rules.test/broken.json'} : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _open(tester, service, readText: (_) async => throw StateError('下载失败'));
    await _add(tester, '从剪贴板导入');
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      'https://rules.test/broken.json');
    await tester.tap(find.text('导入规则').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('下载失败'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      'https://rules.test/broken.json');
    expect(service.writes, 0);
    await tester.enterText(find.byType(TextField).last, '[$_raw,{"api":"1","name":"番剧规则"}]');
    await tester.tap(find.text('导入规则').last);
    await tester.pumpAndSettle();
    expect(service.writes, 0);
    expect(find.textContaining('需要 version=1'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, _raw);
    await tester.tap(find.text('导入规则').last);
    await tester.pumpAndSettle();
    expect(service.rules.single.id, 'linovel');
    expect(find.text('规则内容'), findsNothing);
    expect(find.text('已导入 1 条小说规则'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('catalog loads on entry, installs with one tap and deletion requires confirmation', (tester) async {
    final service = _Rules();
    final requests = <String>[];
    await _open(tester, service, readText: (url) async {
      requests.add(url);
      return url.endsWith('catalog.json') ? jsonEncode({'version': 1, 'rules': [
        {'id': 'linovel', 'name': '轻之文库', 'description': '小说来源', 'file': 'linovel.json'},
      ]}) : _raw;
    });
    await _add(tester, '浏览规则仓库');
    expect(requests, [NovelRulesPage.defaultCatalog]);
    expect(find.text('获取规则列表'), findsNothing);
    await tester.tap(find.text('安装'));
    await tester.pumpAndSettle();
    expect(service.rules.single.id, 'linovel');
    expect(find.text('重新获取'), findsOneWidget);
    Navigator.of(tester.element(find.text('小说规则仓库'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留'));
    await tester.pumpAndSettle();
    expect(service.rules.length, 1);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(service.rules, isEmpty);
  });

  testWidgets('invalid catalog settings preserve the old address and editable candidate', (tester) async {
    final service = _Rules()..url = 'https://rules.test/catalog.json';
    await _open(tester, service, readText: (url) async {
      if (url.contains('invalid')) throw StateError('仓库地址无效');
      return '{"version":1,"rules":[]}';
    });
    await _add(tester, '浏览规则仓库');
    await tester.tap(find.byTooltip('规则仓库设置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://invalid.test/catalog.json');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(service.url, 'https://rules.test/catalog.json');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'https://invalid.test/catalog.json');
    expect(find.textContaining('仓库地址无效'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('file import supports JSON arrays and cancelling leaves rules unchanged', (tester) async {
    final service = _Rules();
    final picker = _Picker();
    final oldPicker = FilePicker.platform;
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = oldPicker);
    await _open(tester, service);
    await _add(tester, '从文件导入');
    expect(service.writes, 0);
    final bytes = Uint8List.fromList(utf8.encode('[$_raw]'));
    picker.result = FilePickerResult([PlatformFile(name: 'rules.json', size: bytes.length, bytes: bytes)]);
    await _add(tester, '从文件导入');
    expect(picker.requestedData, isTrue);
    expect(service.rules.single.id, 'linovel');
  });
}
