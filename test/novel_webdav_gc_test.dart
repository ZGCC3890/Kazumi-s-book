import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/novel/novel_sync_state.dart';
import '../lib/novel/novel_webdav_exchange.dart';

const _a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _c = 'cccccccccccccccccccccccccccccccc';
const _key = 'position/book';

String _name(String device, String raw) =>
    '$device-${sha256.convert(utf8.encode(raw))}.json';

class _Dav {
  final files = <String, String>{};
  final events = <String>[];
  Future<void> Function(String)? beforeRead;
  Future<void> Function(String)? beforeRemove;
  void Function(String)? afterMove;
  String Function(String, String)? readResponse;
  String? fail;
  int listings = 0;

  String add(NovelSyncState state, String device, {bool legacy = false}) =>
      addRaw(state.encode(), device, legacy: legacy);

  String addRaw(String raw, String device, {bool legacy = false}) {
    final name = '${legacy ? 'v1/' : ''}${_name(device, raw)}';
    files[name] = raw;
    return name;
  }

  Set<String> get roots => files.keys
      .where((name) => !name.contains('/') &&
          NovelWebDavExchange.snapshotName.hasMatch(name))
      .toSet();

  NovelSyncState get rootState {
    expect(roots, isNotEmpty, reason: 'A valid root keeper must survive');
    return roots.fold(NovelSyncState(),
        (state, name) => state.merge(NovelSyncState.decode(files[name]!)));
  }

  Future<List<String>> list() async {
    events.add('LIST');
    listings++;
    return files.keys.toList();
  }

  Future<String> read(String name) async {
    events.add('GET $name');
    await beforeRead?.call(name);
    if (fail == 'GET') throw StateError('GET failed');
    final raw = files[name];
    if (raw == null) throw NovelSnapshotMissing(name);
    return readResponse?.call(name, raw) ?? raw;
  }

  Future<void> write(String name, String body) async {
    events.add('PUT $name');
    if (fail == 'PUT') throw StateError('PUT failed');
    files[name] = body;
  }

  Future<void> move(String from, String to) async {
    events.add('MOVE $to');
    if (fail == 'MOVE') throw StateError('MOVE failed');
    if (files.containsKey(to)) throw StateError('Destination already exists');
    files[to] = files.remove(from)!;
    afterMove?.call(to);
  }

  Future<void> remove(String name) async {
    events.add('DELETE $name');
    await beforeRemove?.call(name);
    if (fail == 'DELETE') throw StateError('DELETE failed');
    // The transport's already-absent DELETE is idempotent; GET absence has
    // its separate explicit NovelSnapshotMissing protocol above.
    files.remove(name);
  }
}

class _Client {
  _Client(this.id, [NovelSyncState? initial])
      : state = initial ?? NovelSyncState();
  final String id;
  NovelSyncState state;
  Set<String> seen = {};
  final commits = <Set<String>>[];
  bool enabled = true;
  bool failCommit = false;

  Future<String?> sync(_Dav dav, {Future<List<String>> Function()? list}) =>
      const NovelWebDavExchange().run(
        deviceId: id,
        knownSnapshots: {...seen},
        enabled: () => enabled,
        list: list ?? dav.list,
        read: dav.read,
        write: dav.write,
        move: dav.move,
        remove: dav.remove,
        merge: (incoming, names) async {
          if (failCommit) throw StateError('Local commit failed');
          state = state.merge(incoming);
          seen = {...names};
          commits.add({...names});
          return state;
        },
      );
}

NovelSyncState _position(int chapter) =>
    NovelSyncState().edit(_key, {'chapter': chapter}, _a);

void main() {
  test('strict causal GC keeps a verified head and converges known snapshots', () async {
    final dav = _Dav();
    final old = _position(8);
    final newer = old.edit(_key, {'chapter': 2}, _a);
    final oldName = dav.add(old, _a);
    final head = dav.add(newer, _a);
    final client = _Client(_b)..seen = {'gone.json'};
    await client.sync(dav);
    expect(dav.roots, {head});
    expect(dav.files.containsKey(oldName), isFalse);
    expect(dav.rootState.value(_key)!['chapter'], 2);
    expect(client.seen, {head});
    expect(dav.events.lastIndexOf('GET $head'),
        lessThan(dav.events.indexOf('DELETE $oldName')));
    expect(dav.events.where((event) => event.startsWith('PUT ')), isEmpty);
  });

  test('240 progress writes compact to a bounded head set for a new device', () async {
    final dav = _Dav();
    final client = _Client(_a);
    for (var chapter = 1; chapter <= 240; chapter++) {
      client.state = client.state.edit(_key, {'chapter': chapter}, _a);
      await client.sync(dav);
      expect(dav.roots, hasLength(1));
      expect(client.seen, dav.roots);
    }
    dav.events.clear();
    final newcomer = _Client(_b);
    await newcomer.sync(dav);
    expect(newcomer.state.value(_key)!['chapter'], 240);
    expect(dav.roots, hasLength(1));
    expect(dav.events.where((event) => event.startsWith('GET ')).length,
        lessThanOrEqualTo(3));
    expect(dav.events.where((event) => event.startsWith('PUT ')), isEmpty);
  });

  test('two compactors retain the same lexicographic equivalent keeper', () async {
    final dav = _Dav();
    final state = _position(3);
    final keeper = dav.add(state, _a);
    final redundant = dav.add(state, _b);
    final gate = Completer<void>();
    var arrived = 0;
    dav.beforeRemove = (name) async {
      expect(name, redundant);
      if (++arrived == 2) gate.complete();
      await gate.future;
    };
    await Future.wait([_Client(_a).sync(dav), _Client(_b).sync(dav)])
        .timeout(const Duration(seconds: 5));
    expect(dav.roots, {keeper});
    expect(dav.events, isNot(contains('DELETE $keeper')));
    expect(dav.rootState.covers(state), isTrue);
  });

  test('equivalent roots with different clock and value key order are reused', () async {
    final dav = _Dav();
    final left = NovelSyncState({_key: [NovelRevision(
      clock: {'a': 1, 'b': 2},
      value: {'chapter': 1, 'anchor': {'quote': '文', 'before': '前'}},
    )]});
    final right = NovelSyncState({_key: [NovelRevision(
      clock: {'b': 2, 'a': 1},
      value: {'anchor': {'before': '前', 'quote': '文'}, 'chapter': 1},
    )]});
    final keeper = dav.add(left, _a);
    final redundant = dav.add(right, _b);
    expect(keeper.split('-').last, isNot(redundant.split('-').last));
    await _Client(_c, right).sync(dav);
    expect(dav.roots, {keeper});
    expect(dav.events.where((event) => event.startsWith('PUT ')), isEmpty);
    expect(dav.rootState.covers(left), isTrue);
    expect(left.covers(dav.rootState), isTrue);
  });

  for (final operation in ['GET', 'PUT', 'MOVE', 'DELETE']) {
    test('$operation failure never removes the old committed snapshot', () async {
      final dav = _Dav();
      final old = _position(8);
      final oldName = dav.add(old, _a);
      final oldRaw = dav.files[oldName];
      final client = _Client(_a, old.edit(_key, {'chapter': 2}, _a));
      dav.fail = operation;
      await expectLater(client.sync(dav), throwsStateError);
      expect(dav.files[oldName], oldRaw);
      expect(client.state.value(_key)!['chapter'], 2);
      if (operation != 'DELETE') {
        expect(dav.events.where((event) => event.startsWith('DELETE ') &&
            event.endsWith('.json')), isEmpty);
      }
      dav.fail = null;
      await client.sync(dav);
      expect(dav.rootState.covers(client.state), isTrue);
      expect(dav.roots, hasLength(1));
    });
  }

  test('keeper readback hash failure prevents deleting the legacy source', () async {
    final dav = _Dav();
    final state = _position(2);
    final legacy = dav.add(state, _a, legacy: true);
    String? published;
    dav.afterMove = (name) => published = name;
    dav.readResponse = (name, raw) => name == published ? '$raw ' : raw;
    await expectLater(_Client(_a).sync(dav), throwsFormatException);
    expect(published, isNotNull);
    expect(dav.files.containsKey(legacy), isTrue);
    expect(dav.events.where((event) => event.startsWith('DELETE ')), isEmpty);
  });

  test('failed and interrupted uploads clean only this device pending files', () async {
    final dav = _Dav();
    final old = _position(1);
    final head = dav.add(old, _a);
    final client = _Client(_a, old.edit(_key, {'chapter': 2}, _a));
    dav.fail = 'MOVE';
    dav.beforeRemove = (name) async {
      if (name.endsWith('.cache')) throw StateError('DELETE cleanup failed');
    };
    await expectLater(client.sync(dav), throwsA(predicate((Object error) =>
        error.toString().contains('MOVE failed') &&
        error.toString().contains('DELETE cleanup failed'))));
    // Capture the real production upload name left when both network stages
    // fail; a hand-written cache name would miss naming regressions.
    final abandoned = dav.files.keys.singleWhere((name) => name.endsWith('.cache'));
    final legacy = 'v1/$abandoned';
    final foreign = abandoned.replaceFirst(_a, _b);
    dav.files.addAll({legacy: 'old own legacy', foreign: 'active other device'});
    dav.beforeRemove = null;
    await expectLater(client.sync(dav), throwsStateError);
    expect(dav.files[head], old.encode());
    expect(dav.files[foreign], 'active other device');
    expect(dav.files.keys.where((name) => name.endsWith('.cache')), [foreign]);
    dav.fail = null;
    await client.sync(dav);
    expect(dav.roots, hasLength(1));
    expect(dav.files.keys.where((name) => name.endsWith('.cache')), [foreign]);
  });

  test('invalid source checksum aborts before publication or deletion', () async {
    final dav = _Dav();
    final name = dav.add(_position(1), _a);
    dav.files[name] = _position(9).encode();
    await expectLater(_Client(_b).sync(dav), throwsFormatException);
    expect(dav.files.keys, [name]);
    expect(dav.events.where((event) =>
        event.startsWith('PUT ') || event.startsWith('DELETE ')), isEmpty);
  });

  test('local atomic commit failure cannot trigger remote garbage collection', () async {
    final dav = _Dav();
    final old = _position(1);
    dav.add(old, _a);
    dav.add(old.edit(_key, {'chapter': 2}, _a), _a);
    final before = Map<String, String>.from(dav.files);
    await expectLater((_Client(_b)..failCommit = true).sync(dav), throwsStateError);
    expect(dav.files, before);
    expect(dav.events.where((event) => event.startsWith('DELETE ')), isEmpty);
  });

  test('failure after one deletion retains a keeper covering every original head', () async {
    final dav = _Dav();
    final old = _position(1);
    final middle = old.edit(_key, {'chapter': 2}, _a);
    final newest = middle.edit(_key, {'chapter': 3}, _a);
    dav.add(old, _a);
    dav.add(middle, _a);
    final keeper = dav.add(newest, _a);
    var deletes = 0;
    dav.beforeRemove = (_) async {
      if (++deletes == 2) throw StateError('Second DELETE failed');
    };
    final client = _Client(_b);
    await expectLater(client.sync(dav), throwsStateError);
    expect(dav.files.containsKey(keeper), isTrue);
    expect(dav.roots, hasLength(2));
    expect(dav.rootState.covers(old.merge(middle).merge(newest)), isTrue);
    dav.beforeRemove = null;
    await client.sync(dav);
    expect(dav.roots, {keeper});
    expect(client.seen, {keeper});
  });

  test('a concurrent root absent from the initial listing is never deleted', () async {
    final dav = _Dav();
    final old = _position(1);
    dav.add(old, _a);
    dav.add(old.edit(_key, {'chapter': 2}, _a), _a);
    String? lateName;
    final late = old.edit(_key, {'chapter': 7}, _b);
    dav.beforeRemove = (_) async {
      lateName ??= dav.add(late, _b);
    };
    final client = _Client(_a);
    await client.sync(dav);
    expect(lateName, isNotNull);
    expect(dav.files.containsKey(lateName), isTrue);
    expect(dav.events, isNot(contains('DELETE $lateName')));
    expect(dav.rootState.revisions(_key), hasLength(2));
    dav.beforeRemove = null;
    await client.sync(dav);
    expect(client.state.revisions(_key), hasLength(2));
    expect(dav.roots, hasLength(1));
  });

  test('GC preserves every unresolved concurrent candidate in the keeper', () async {
    final dav = _Dav();
    final base = _position(1);
    final a = base.edit(_key, {'chapter': 9}, _a);
    final b = base.edit(_key, {'chapter': 2}, _b);
    final c = base.edit(_key, {'chapter': 5}, _c);
    dav.add(a, _a);
    dav.add(b, _b);
    dav.add(c, _c);
    final client = _Client(_a);
    await client.sync(dav);
    expect(dav.roots, hasLength(1));
    expect(dav.rootState.revisions(_key).map((r) => r.value!['chapter']),
        unorderedEquals([9, 2, 5]));
    expect(dav.rootState.covers(a.merge(b).merge(c)), isTrue);
  });

  test('an offline old device cannot resurrect a compacted bookmark tombstone', () async {
    const key = 'bookmark/one';
    final dav = _Dav();
    final original = NovelSyncState().edit(key, {'note': 'old'}, _a);
    final deleted = original.edit(key, null, _a);
    dav.add(original, _a);
    dav.add(deleted, _a);
    await _Client(_a, deleted).sync(dav);
    final offline = _Client(_b, original);
    await offline.sync(dav);
    expect(offline.state.value(key), isNull);
    expect(offline.state.revisions(key), hasLength(1));
    expect(dav.rootState.covers(deleted), isTrue);
    final editedOffline = _Client(_c, original.edit(key, {'note': 'edited'}, _c));
    await editedOffline.sync(dav);
    expect(dav.rootState.revisions(key), hasLength(2));
    expect(dav.rootState.revisions(key).where((r) => r.value == null), hasLength(1));
  });

  test('legacy cleanup follows verified root publication and preserves foreign cache', () async {
    final dav = _Dav();
    final state = _position(4);
    final legacy = dav.add(state, _a, legacy: true);
    final sentinels = {
      'foreign-upload.cache': 'in flight',
      'v1/foreign-upload.cache': 'old in flight',
      'notes.json': 'unrelated',
    };
    dav.files.addAll(sentinels);
    final client = _Client(_b);
    await client.sync(dav);
    final keeper = dav.roots.single;
    final moveAt = dav.events.indexOf('MOVE $keeper');
    final verifyAt = dav.events.lastIndexOf('GET $keeper');
    final deleteAt = dav.events.indexOf('DELETE $legacy');
    expect(moveAt, greaterThanOrEqualTo(0));
    expect(verifyAt, greaterThan(moveAt));
    expect(deleteAt, greaterThan(verifyAt));
    expect(client.seen, {keeper});
    for (final entry in sentinels.entries) {
      expect(dav.files[entry.key], entry.value);
      expect(dav.events, isNot(contains('DELETE ${entry.key}')));
    }
    expect(dav.events, isNot(contains('DELETE v1')));
    expect(dav.events, isNot(contains('DELETE v1/')));
  });

  test('a late legacy write survives this round and is merged on the next', () async {
    final dav = _Dav();
    final original = _position(1);
    dav.add(original, _a, legacy: true);
    final late = original.edit(_key, {'chapter': 5}, _b);
    String? lateName;
    dav.afterMove = (_) => lateName ??= dav.add(late, _b, legacy: true);
    final client = _Client(_a);
    await client.sync(dav);
    expect(lateName, isNotNull);
    expect(dav.files.containsKey(lateName), isTrue);
    expect(dav.events, isNot(contains('DELETE $lateName')));
    dav.afterMove = null;
    await client.sync(dav);
    expect(client.state.value(_key)!['chapter'], 5);
    expect(dav.files.containsKey(lateName), isFalse);
    expect(dav.rootState.covers(late), isTrue);
  });

  test('confirmed concurrent compaction missing snapshot relists and keeps its replacement', () async {
    final dav = _Dav();
    final state = _position(1);
    final vanished = dav.add(state, _a);
    final replacement = dav.add(state, _b);
    var once = false;
    dav.beforeRead = (name) async {
      if (name == vanished && !once) {
        once = true;
        dav.files.remove(vanished);
      }
    };
    await _Client(_c).sync(dav);
    expect(dav.listings, greaterThan(1));
    expect(dav.roots, {replacement});
    expect(dav.rootState.covers(state), isTrue);
  });

  test('missing last snapshot is an error and never fabricates remote success', () async {
    final dav = _Dav();
    final vanished = dav.add(_position(1), _a);
    dav.beforeRead = (name) async => dav.files.remove(name);
    await expectLater(_Client(_b).sync(dav),
        throwsA(anyOf(isA<NovelSnapshotMissing>(), isA<StateError>())));
    expect(dav.events, contains('GET $vanished'));
    expect(dav.events.where((event) => event.startsWith('PUT ')), isEmpty);
    expect(dav.events.where((event) => event.startsWith('DELETE ')), isEmpty);
  });

  test('a false missing response without listing disappearance is not retried as GC', () async {
    final dav = _Dav();
    final first = dav.add(_position(1), _a);
    dav.add(_position(1), _b);
    dav.beforeRead = (name) async => throw NovelSnapshotMissing(name);
    await expectLater(_Client(_c).sync(dav),
        throwsA(anyOf(isA<NovelSnapshotMissing>(), isA<StateError>())));
    expect(dav.files.containsKey(first), isTrue);
    expect(dav.events.where((event) => event.startsWith('DELETE ')), isEmpty);
    expect(dav.listings, lessThanOrEqualTo(2));
  });

  test('persistent concurrent replacement stops after a bounded retry budget', () async {
    final dav = _Dav();
    final state = _position(1);
    dav.add(state, _a);
    var generation = 1;
    dav.beforeRead = (name) async {
      dav.files.remove(name);
      dav.add(state, (generation++).toRadixString(16).padLeft(32, '0'));
    };
    await expectLater(_Client(_c).sync(dav).timeout(const Duration(seconds: 3)),
        throwsA(anyOf(isA<NovelSnapshotMissing>(), isA<StateError>())));
    expect(generation, lessThanOrEqualTo(5));
    expect(dav.roots, hasLength(1));
    expect(dav.events.where((event) => event.startsWith('DELETE ')), isEmpty);
  });
}
