import 'dart:convert';
import 'novel_models.dart';

/// A multi-value register. Concurrent edits remain visible until resolved.
class NovelRevision {
  NovelRevision({required Map<String, int> clock, required this.value})
    : clock = Map.unmodifiable(clock);
  final Map<String, int> clock;
  final NovelJson? value; // null is a replicated deletion tombstone.

  bool dominates(NovelRevision other) =>
      other.clock.entries.every((e) => (clock[e.key] ?? 0) >= e.value);
  NovelJson toJson() => {'clock': clock, 'value': value};
  factory NovelRevision.fromJson(NovelJson j) => NovelRevision(
    clock: Map<String, int>.from(j['clock'] as Map),
    value: j['value'] as NovelJson?,
  );
}

class NovelSyncState {
  NovelSyncState([Map<String, List<NovelRevision>> entities = const {}])
    : entities = Map.unmodifiable({
        for (final e in entities.entries)
          e.key: List<NovelRevision>.unmodifiable(e.value),
      });
  final Map<String, List<NovelRevision>> entities;

  List<NovelRevision> revisions(String key) => entities[key] ?? const [];
  NovelJson? value(String key) {
    final candidates = revisions(key);
    if (candidates.length > 1) throw StateError('阅读数据存在并发修改：$key');
    return candidates.isEmpty ? null : candidates.single.value;
  }

  Iterable<String> keys(String prefix) =>
      entities.keys.where((k) => k.startsWith('$prefix/'));
  Iterable<String> get conflicts =>
      entities.keys.where((key) => entities[key]!.length > 1);

  NovelSyncState edit(String key, NovelJson? value, String deviceId) {
    if (revisions(key).length > 1) {
      throw StateError('请先选择并发修改的位置：$key');
    }
    return _write(key, value, deviceId);
  }

  /// Captures every displayed candidate, independent of map/list ordering.
  String conflictToken(String key) {
    final candidates = revisions(key)
        .map((revision) => _canonical(revision.toJson()))
        .toList()
      ..sort();
    return jsonEncode({'key': key, 'candidates': candidates});
  }

  NovelSyncState resolve(
    String key,
    NovelRevision selected,
    String deviceId, {
    required String expectedToken,
  }) {
    if (conflictToken(key) != expectedToken) {
      throw StateError('冲突已发生变化，请重新选择');
    }
    final selectedValue = _canonical(selected.toJson());
    final candidate = revisions(key)
        .where((revision) => _canonical(revision.toJson()) == selectedValue)
        .firstOrNull;
    if (candidate == null) {
      throw StateError('所选候选不在当前冲突中，请重新选择');
    }
    return _write(key, candidate.value, deviceId);
  }

  /// Whether this complete state preserves every causal revision in [other].
  /// Deletion tombstones participate exactly like live values.
  bool covers(NovelSyncState other) {
    for (final entry in other.entities.entries) {
      for (final candidate in entry.value) {
        final covered = revisions(entry.key).any(
          (revision) =>
              revision.dominates(candidate) &&
              (!candidate.dominates(revision) ||
                  _canonical(revision.value) == _canonical(candidate.value)),
        );
        if (!covered) return false;
      }
    }
    return true;
  }

  NovelSyncState _write(String key, NovelJson? value, String deviceId) {
    final clock = <String, int>{};
    for (final r in revisions(key)) {
      for (final e in r.clock.entries) {
        if (e.value > (clock[e.key] ?? 0)) clock[e.key] = e.value;
      }
    }
    clock[deviceId] = (clock[deviceId] ?? 0) + 1;
    return NovelSyncState({
      ...entities,
      key: [NovelRevision(clock: clock, value: value)],
    });
  }

  NovelSyncState merge(NovelSyncState other) {
    final merged = <String, List<NovelRevision>>{};
    for (final key in {...entities.keys, ...other.entities.keys}) {
      final survivors = <NovelRevision>[];
      for (final candidate in [...revisions(key), ...other.revisions(key)]) {
        final same = survivors.where(
          (r) => r.dominates(candidate) && candidate.dominates(r),
        );
        if (same.isNotEmpty) {
          if (_canonical(same.single.value) != _canonical(candidate.value)) {
            throw FormatException('相同修订包含不同内容：$key');
          }
          continue;
        }
        if (survivors.any((r) => r.dominates(candidate))) continue;
        survivors.removeWhere(candidate.dominates);
        survivors.add(candidate);
      }
      // Canonical ordering makes merge commutative on the wire as well.
      survivors.sort((a, b) => _clockKey(a).compareTo(_clockKey(b)));
      merged[key] = survivors;
    }
    return NovelSyncState(merged);
  }

  static String _clockKey(NovelRevision r) {
    final keys = r.clock.keys.toList()..sort();
    return keys.map((k) => '$k:${r.clock[k]}').join(',');
  }

  static String _canonical(Object? value) {
    Object? sorted(Object? v) {
      if (v is Map) {
        final keys = v.keys.cast<String>().toList()..sort();
        return {for (final key in keys) key: sorted(v[key])};
      }
      if (v is List) return v.map(sorted).toList();
      return v;
    }

    return jsonEncode(sorted(value));
  }

  String encode() {
    final keys = entities.keys.toList()..sort();
    return jsonEncode({
      'version': 1,
      'entities': {
        for (final key in keys)
          key: entities[key]!.map((r) => r.toJson()).toList(),
      },
    });
  }

  factory NovelSyncState.decode(String text) {
    final j = jsonDecode(text) as NovelJson;
    if (j['version'] != 1) throw const FormatException('不支持的小说同步版本');
    final entities = j['entities'] as NovelJson;
    return NovelSyncState({
      for (final e in entities.entries)
        e.key: (e.value as List)
            .map((r) => NovelRevision.fromJson(r as NovelJson))
            .toList(),
    });
  }
}
