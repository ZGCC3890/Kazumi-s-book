import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_rule_import.dart';
import 'package:kazumi/utils/encoding.dart';

String _rule(String id, [String name = '测试书源']) {
  final value = jsonDecode(File('novel_rules/linovel.json').readAsStringSync()) as Map<String, dynamic>;
  return jsonEncode({...value, 'id': id, 'name': name});
}

void main() {
  test('single JSON and arrays use the novel schema and replace duplicate IDs', () async {
    final importer = NovelRuleImport((_) => throw StateError('No network expected'));
    expect((await importer.parse(_rule('first'))).single.id, 'first');
    final rules = await importer.parse('[${_rule('first')},${_rule('second')},${_rule('first', '新版名称')}]');
    expect(rules.map((rule) => rule.id), ['first', 'second']);
    expect(rules.first.name, '新版名称');
  });

  test('clipboard share links round-trip UTF-8 names and multiple rules', () async {
    final importer = NovelRuleImport((_) => throw StateError('No network expected'));
    final rules = await importer.parse('${jsonToKazumiBase64(_rule('first', '书源甲'))}\n'
      '${jsonToKazumiBase64(_rule('second', '书源乙'))}');
    expect(rules.map((rule) => rule.name), ['书源甲', '书源乙']);
  });

  test('HTTP import downloads the selected URL and propagates download errors', () async {
    final requests = <String>[];
    final importer = NovelRuleImport((url) async {
      requests.add(url);
      if (url.endsWith('failed')) throw StateError('download failed');
      return _rule('downloaded');
    });
    expect((await importer.parse('https://rules.test/book.json')).single.id, 'downloaded');
    await expectLater(importer.parse('https://rules.test/failed'), throwsStateError);
    expect(requests, ['https://rules.test/book.json', 'https://rules.test/failed']);
  });

  test('empty arrays, malformed JSON and video rules reject the entire import', () async {
    final importer = NovelRuleImport((_) => throw StateError('No network expected'));
    for (final input in ['[]', '{broken', '[${_rule('valid')},{"api":"1","name":"番剧规则"}]']) {
      await expectLater(importer.parse(input), throwsFormatException);
    }
  });

  test('catalog resolves relative rule addresses and rejects mismatched IDs', () async {
    final requests = <String>[];
    final importer = NovelRuleImport((url) async {
      requests.add(url);
      if (url.endsWith('catalog.json')) return jsonEncode({'version': 1,
        'rules': [{'id': 'first', 'name': '书源', 'description': '', 'file': 'books/first.json'}]});
      return _rule('first');
    });
    final entries = await importer.catalog('https://rules.test/custom/catalog.json');
    expect((await importer.fromCatalog('https://rules.test/custom/catalog.json', entries.single)).id, 'first');
    expect(requests.last, 'https://rules.test/custom/books/first.json');
    await expectLater(importer.fromCatalog('https://rules.test/custom/catalog.json',
      {'id': 'other', 'file': 'books/first.json'}), throwsFormatException);
  });

  test('malformed catalog entries fail before they can be saved or displayed', () async {
    for (final entry in [
      {'id': 'first', 'file': 'first.json'},
      {'id': 'first', 'name': '书源', 'description': 42, 'file': 'first.json'},
    ]) {
      final importer = NovelRuleImport((_) async => jsonEncode({'version': 1, 'rules': [entry]}));
      await expectLater(importer.catalog('https://rules.test/catalog.json'), throwsFormatException);
    }
  });
}
