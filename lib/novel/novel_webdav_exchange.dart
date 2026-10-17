import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'novel_sync_state.dart';

/// A listed immutable head was removed by a concurrent compactor.
class NovelSnapshotMissing implements Exception {
  const NovelSnapshotMissing(this.name);
  final String name;
  @override
  String toString() => '小说同步文件已不存在：$name';
}

/// Production exchange algorithm, isolated from the WebDAV client's file I/O.
class NovelWebDavExchange {
  const NovelWebDavExchange();
  static final snapshotName = RegExp(r'^[0-9a-f]{32}-[0-9a-f]{64}\.json$');

  static bool _isSnapshot(String name) => snapshotName.hasMatch(name) ||
      (name.startsWith('v1/') && snapshotName.hasMatch(name.substring(3)));

  Future<String?> run({
    required String deviceId,
    required Set<String> knownSnapshots,
    required Future<List<String>> Function() list,
    required Future<String> Function(String name) read,
    required Future<void> Function(String name, String body) write,
    required Future<void> Function(String from, String to) move,
    required Future<void> Function(String name) remove,
    required Future<NovelSyncState> Function(
      NovelSyncState remote,
      Set<String> seen,
    )
    merge,
    required bool Function() enabled,
  }) async {
    if (!enabled()) return null;
    Future<NovelSyncState> load(String name) async {
      final raw = await read(name);
      if (!name.endsWith('-${sha256.convert(utf8.encode(raw))}.json')) {
        throw FormatException('小说同步文件校验失败：$name');
      }
      return NovelSyncState.decode(raw);
    }

    final listed = await list();
    // This device's exchanges are serialized by the service queue. A pending
    // upload from its previous interrupted run cannot be an active upload now.
    final ownedPending = RegExp(
      '^(?:v1/)?${RegExp.escape(deviceId)}-[0-9a-f]{64}\\.json-[0-9a-f]{1,8}\\.cache\$',
    );
    for (final name in listed.where(ownedPending.hasMatch)) {
      if (!enabled()) return null;
      await remove(name);
    }
    var names = listed.where(_isSnapshot).toSet();
    for (var round = 0; round < 3; round++) {
      try {
        final states = <String, NovelSyncState>{};
        var incoming = NovelSyncState();
        Future<void> loadHeads(Iterable<String> heads) async {
          for (final name in heads.toList()..sort()) {
            if (!enabled()) return;
            final state = await load(name);
            states[name] = state;
            incoming = incoming.merge(state);
          }
        }

        // One unchanged head is incremental. Compaction must examine every
        // listed head, including those previously merged on this device.
        final compact = names.length > 1 || names.any((n) => n.startsWith('v1/'));
        await loadHeads(compact ? names : names.difference(knownSnapshots));
        if (!enabled()) return null;
        var merged = await merge(incoming, names);
        if (!enabled() || merged.entities.isEmpty) return null;
        var encoded = merged.encode();
        var hash = sha256.convert(utf8.encode(encoded)).toString();
        if (!compact && names.length == 1 &&
            names.single.endsWith('-$hash.json')) {
          return null;
        }
        await loadHeads(names.difference(states.keys.toSet()));
        if (!enabled()) return null;
        merged = await merge(incoming, names);
        if (!enabled()) return null;
        encoded = merged.encode();
        hash = sha256.convert(utf8.encode(encoded)).toString();
        final equivalent = states.entries.where((entry) =>
            !entry.key.contains('/') && entry.value.covers(merged) &&
            merged.covers(entry.value)).map((entry) => entry.key).toList()..sort();
        String? published;
        final String keeper;
        if (equivalent.isNotEmpty) {
          keeper = equivalent.first;
        } else {
          keeper = '$deviceId-$hash.json';
          final nonce = Random.secure().nextInt(1 << 32).toRadixString(16);
          final pending = '$keeper-$nonce.cache';
          var moved = false;
          Object? uploadError;
          try {
            await write(pending, encoded);
            if (!enabled()) return null;
            await move(pending, keeper);
            moved = true;
          } catch (error) {
            uploadError = error;
            rethrow;
          } finally {
            if (!moved) {
              try {
                await remove(pending);
              } catch (cleanupError) {
                throw StateError('小说临时上传文件未能清理：$pending；'
                    '上传结果：${uploadError ?? '同步已停止'}；清理错误：$cleanupError');
              }
            }
          }
          published = keeper;
        }

        // A successful PUT/MOVE is insufficient proof for deleting history.
        // Read the final immutable head and verify both checksum and causality.
        final verified = await load(keeper);
        if (!verified.covers(merged)) {
          throw StateError('小说同步文件未完整保留合并数据：$keeper');
        }
        for (final entry in states.entries) {
          if (!enabled()) return null;
          if (entry.key == keeper || !verified.covers(entry.value)) continue;
          final equal = entry.value.covers(verified);
          // Equal concurrent compactors agree on one name. Never let them
          // delete each other's last surviving copy.
          if (!equal || entry.key.startsWith('v1/') ||
              keeper.compareTo(entry.key) < 0) {
            await remove(entry.key);
          }
        }
        if (!enabled()) return null;
        // The state and bounded seen set are persisted atomically by caller.
        await merge(NovelSyncState(), {keeper});
        return published;
      } on NovelSnapshotMissing catch (missing) {
        if (round == 2 || !enabled()) rethrow;
        final current = (await list()).where(_isSnapshot).toSet();
        // Only a confirmed replacement permits restarting this protocol round.
        // A transient/false 404 or disappearance of the last head is an error.
        if (current.isEmpty || current.contains(missing.name)) rethrow;
        names = current;
      }
    }
    throw StateError('小说同步文件持续被其他设备整理，请稍后重试');
  }
}
