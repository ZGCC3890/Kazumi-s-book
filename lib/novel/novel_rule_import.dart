import 'dart:convert';
import '../utils/encoding.dart';
import 'novel_models.dart';
import 'novel_rule.dart';

/// Import transport shared by clipboard, files and the novel rule catalog.
class NovelRuleImport {
  const NovelRuleImport(this.readText);
  final Future<String> Function(String url) readText;

  Future<List<NovelRule>> parse(String input) async {
    var raw = input.trim();
    if (raw.startsWith('https://') || raw.startsWith('http://')) {
      raw = (await readText(raw)).trim();
    }
    final entries = <Object?>[];
    if (raw.toLowerCase().startsWith('kazumi:')) {
      for (final link in findKazumiRuleLinkSegments(raw)) {
        entries.add(jsonDecode(kazumiBase64ToJson('${link.scheme}${link.rawPayload}')));
      }
    } else {
      final decoded = jsonDecode(raw);
      entries.addAll(decoded is List ? decoded : [decoded]);
    }
    if (entries.isEmpty) throw const FormatException('没有可导入的小说规则');
    final rules = <String, NovelRule>{};
    for (final entry in entries) {
      final rule = NovelRule.decode(jsonEncode(entry));
      rules[rule.id] = rule;
    }
    return rules.values.toList();
  }

  Future<List<NovelJson>> catalog(String url) async {
    final value = jsonDecode(await readText(url)) as NovelJson;
    if (value['version'] != 1) throw const FormatException('不支持的规则索引版本');
    if (value['rules'] is! List) throw const FormatException('规则仓库缺少规则列表');
    final entries = <NovelJson>[];
    for (final entry in value['rules'] as List) {
      if (entry is! NovelJson) throw const FormatException('规则仓库条目必须是 JSON 对象');
      for (final key in ['id', 'name', 'file']) {
        if (entry[key] is! String || (entry[key] as String).trim().isEmpty) {
          throw FormatException('规则仓库条目缺少有效的 $key');
        }
      }
      if (entry['description'] is! String) {
        throw const FormatException('规则仓库条目缺少 description');
      }
      entries.add(entry);
    }
    return entries;
  }

  Future<NovelRule> fromCatalog(String url, NovelJson entry) async {
    final raw = await readText(Uri.parse(url).resolve(entry['file'] as String).toString());
    final rule = NovelRule.decode(raw);
    if (rule.id != entry['id']) throw const FormatException('规则文件 id 与索引条目不一致');
    return rule;
  }
}
