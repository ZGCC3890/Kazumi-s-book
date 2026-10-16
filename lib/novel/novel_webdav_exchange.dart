import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'novel_sync_state.dart';

/// Production exchange algorithm, isolated from the WebDAV client's file I/O.
class NovelWebDavExchange {
  const NovelWebDavExchange();
  static final snapshotName = RegExp(r'^[0-9a-f]{32}-[0-9a-f]{64}\.json$');

  Future<String?> run({
    required String deviceId,
    required Set<String> knownSnapshots,
    required Future<List<String>> Function() list,
    required Future<String> Function(String name) read,
    required Future<void> Function(String name, String body) write,
    required Future<void> Function(String from, String to) move,
    required Future<NovelSyncState> Function(
      NovelSyncState remote,
      Set<String> seen,
    )
    merge,
    required bool Function() enabled,
  }) async {
    if (!enabled()) return null;
    final remoteNames = (await list()).where(snapshotName.hasMatch).toSet();
    final seen = {...knownSnapshots};
    var remote = NovelSyncState();
    for (final name
        in remoteNames.difference(knownSnapshots).toList()..sort()) {
      final raw = await read(name);
      if (!name.endsWith('-${sha256.convert(utf8.encode(raw))}.json')) {
        throw FormatException('小说同步文件校验失败：$name');
      }
      remote = remote.merge(NovelSyncState.decode(raw));
      seen.add(name);
    }
    if (!enabled()) return null;
    // Caller persists merged payload and seen names in a single local record.
    final merged = await merge(remote, seen);
    if (!enabled() || merged.entities.isEmpty) return null;
    final encoded = merged.encode();
    final name = '$deviceId-${sha256.convert(utf8.encode(encoded))}.json';
    if (remoteNames.contains(name)) return null;
    final nonce = Random.secure().nextInt(1 << 32).toRadixString(16);
    final pending = '$name-$nonce.cache';
    await write(pending, encoded);
    if (!enabled()) return null;
    // Destination never existed. No delete or replace of an earlier snapshot.
    await move(pending, name);
    return name;
  }
}
