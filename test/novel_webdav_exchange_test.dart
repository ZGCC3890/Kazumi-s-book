import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/novel/novel_sync_state.dart';
import '../lib/novel/novel_webdav_exchange.dart';

const _a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _key = 'position/book';

class _Remote {
  final files = <String, String>{};
  final reads = <String>[];
  final writes = <String>[];
  final moves = <String>[];
  String? failRead;
  bool failWrite = false;
  bool failMove = false;
  void Function()? afterWrite;
  String add(NovelSyncState state, String device) {
    final raw = state.encode();
    final name = '$device-${sha256.convert(utf8.encode(raw))}.json';
    files[name] = raw;
    return name;
  }
  Future<List<String>> list() async => files.keys.toList();
  Future<String> read(String name) async {
    reads.add(name);
    if (name == failRead) throw StateError('GET failed');
    return files[name]!;
  }
  Future<void> write(String name, String raw) async {
    writes.add(name);
    if (failWrite) throw StateError('PUT failed');
    files[name] = raw;
    afterWrite?.call();
  }
  Future<void> move(String from, String to) async {
    moves.add(to);
    if (failMove) throw StateError('MOVE failed');
    if (files.containsKey(to)) throw StateError('destination already exists');
    files[to] = files.remove(from)!;
  }
}

class _Device {
  _Device(this.id, [NovelSyncState? initial]) : state = initial ?? NovelSyncState();
  final String id;
  NovelSyncState state;
  Set<String> seen = {};
  bool enabled = true;
  bool failPersist = false;
  int commits = 0;
  Future<String?> sync(_Remote remote, {Future<List<String>> Function()? list}) =>
      const NovelWebDavExchange().run(deviceId: id, knownSnapshots: seen,
        list: list ?? remote.list, read: remote.read, write: remote.write,
        move: remote.move, enabled: () => enabled, merge: (incoming, names) async {
          if (failPersist) throw StateError('local commit failed');
          state = state.merge(incoming);
          seen = names;
          commits++;
          return state;
        });
}

void main() {
  test('incremental GET reads N then zero then only the new snapshot', () async {
    final remote = _Remote();
    final first = NovelSyncState().edit(_key, {'chapter': 3}, _a);
    final second = first.edit(_key, {'chapter': 4}, _a);
    final names = {remote.add(first, _a), remote.add(second, _a)};
    remote.files['unfinished.cache'] = 'partial';
    final device = _Device(_a);
    await device.sync(remote);
    expect(remote.reads.toSet(), names);
    expect(device.state.value(_key)!['chapter'], 4);
    remote.reads.clear();
    await device.sync(remote);
    expect(remote.reads, isEmpty);
    final newest = remote.add(second.edit(_key, {'chapter': 2}, _a), _a);
    await device.sync(remote);
    expect(remote.reads, [newest]);
    expect(device.state.value(_key)!['chapter'], 2);
  });

  test('GET failure leaves both local state and seen set uncommitted', () async {
    final remote = _Remote();
    remote.add(NovelSyncState().edit('book/one', {'title': 'one'}, _a), _a);
    remote.add(NovelSyncState().edit('book/two', {'title': 'two'}, _b), _b);
    remote.failRead = (remote.files.keys.toList()..sort()).last;
    final device = _Device(_a);
    await expectLater(device.sync(remote), throwsStateError);
    expect(device.state.entities, isEmpty);
    expect(device.seen, isEmpty);
    expect(device.commits, 0);
    expect(remote.writes, isEmpty);
  });

  test('content hash mismatch is rejected before marking seen or publishing', () async {
    final remote = _Remote();
    final name = remote.add(NovelSyncState().edit(_key, {'chapter': 1}, _a), _a);
    remote.files[name] = NovelSyncState().edit(_key, {'chapter': 99}, _a).encode();
    final device = _Device(_b);
    await expectLater(device.sync(remote), throwsFormatException);
    expect(device.seen, isEmpty);
    expect(device.commits, 0);
    expect(remote.writes, isEmpty);
  });

  test('local atomic commit failure does not publish or advance seen', () async {
    final remote = _Remote();
    remote.add(NovelSyncState().edit(_key, {'chapter': 2}, _a), _a);
    final device = _Device(_b)..failPersist = true;
    await expectLater(device.sync(remote), throwsStateError);
    expect(device.seen, isEmpty);
    expect(remote.writes, isEmpty);
  });

  for (final operation in ['PUT', 'MOVE']) {
    test('$operation failure retains old snapshot and local newer position; retry works', () async {
      final remote = _Remote();
      final initial = NovelSyncState().edit(_key, {'chapter': 8}, _a);
      final oldName = remote.add(initial, _a);
      final oldRaw = remote.files[oldName];
      final device = _Device(_a, initial.edit(_key, {'chapter': 2}, _a));
      remote.failWrite = operation == 'PUT';
      remote.failMove = operation == 'MOVE';
      await expectLater(device.sync(remote), throwsStateError);
      expect(remote.files[oldName], oldRaw);
      expect(device.state.value(_key)!['chapter'], 2);
      expect(remote.files.keys.where(NovelWebDavExchange.snapshotName.hasMatch), [oldName]);
      remote.failWrite = false;
      remote.failMove = false;
      final published = await device.sync(remote);
      expect(published, isNotNull);
      expect(remote.files[oldName], oldRaw);
      expect(NovelSyncState.decode(remote.files[published]!).value(_key)!['chapter'], 2);
    });
  }

  test('two devices publishing from the same listing retain concurrent positions', () async {
    final remote = _Remote();
    final first = _Device(_a, NovelSyncState().edit(_key, {'chapter': 7}, _a));
    final second = _Device(_b, NovelSyncState().edit(_key, {'chapter': 2}, _b));
    final gate = Completer<void>();
    var arrivals = 0;
    Future<List<String>> simultaneousList() async {
      final snapshot = remote.files.keys.toList();
      if (++arrivals == 2) gate.complete();
      await gate.future;
      return snapshot;
    }
    final names = await Future.wait([
      first.sync(remote, list: simultaneousList),
      second.sync(remote, list: simultaneousList),
    ]);
    expect(names.toSet(), hasLength(2));
    expect(remote.files.keys.where(NovelWebDavExchange.snapshotName.hasMatch), hasLength(2));
    await first.sync(remote);
    await second.sync(remote);
    expect(first.state.revisions(_key), hasLength(2));
    expect(first.state.encode(), second.state.encode());
    final selected = first.state.revisions(_key).singleWhere((r) => r.value!['chapter'] == 2);
    first.state = first.state.resolve(_key, selected, _a);
    await first.sync(remote);
    await second.sync(remote);
    expect(second.state.value(_key)!['chapter'], 2);
    expect(second.state.conflicts, isEmpty);
  });

  test('disabled sync performs no I/O', () async {
    final remote = _Remote();
    final device = _Device(_a, NovelSyncState().edit(_key, {'chapter': 1}, _a))..enabled = false;
    var listings = 0;
    expect(await device.sync(remote, list: () async { listings++; return []; }), isNull);
    expect(listings, 0);
    expect(remote.writes, isEmpty);
  });

  test('disabling after PUT leaves only an ignored cache, never a final snapshot', () async {
    final remote = _Remote();
    final device = _Device(_a, NovelSyncState().edit(_key, {'chapter': 1}, _a));
    remote.afterWrite = () => device.enabled = false;
    expect(await device.sync(remote), isNull);
    expect(remote.writes, hasLength(1));
    expect(remote.moves, isEmpty);
    expect(remote.files.keys.where(NovelWebDavExchange.snapshotName.hasMatch), isEmpty);
  });
}
