import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_locator.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_sync_state.dart';

const _positionKey = 'position/edition-one';

NovelChapter _chapter({
  String url = 'https://source.test/book/volume-2/chapter-2',
  String title = '第二章 启程',
  String volume = '第二卷',
  String kind = '正文',
  int? number = 2,
}) =>
    NovelChapter(
      url: url,
      title: title,
      volume: volume,
      kind: kind,
      number: number,
    );

NovelPosition _capture(String text, int offset) => NovelLocator.capture(
      editionId: 'edition-one',
      sourceId: 'source-one',
      chapter: _chapter(),
      text: text,
      offset: offset,
      updatedAt: 1234,
    );

Object? _document(NovelSyncState state) => jsonDecode(state.encode());

void main() {
  group('NovelSyncState causal records', () {
    final initial = NovelSyncState().edit(
      _positionKey,
      {'chapter': 10, 'updatedAt': 1000},
      'device-a',
    );
    final laterA = initial.edit(
      _positionKey,
      {'chapter': 11, 'updatedAt': 2000},
      'device-a',
    );
    final offlineB = initial.edit(
      _positionKey,
      {'chapter': 3, 'updatedAt': 1},
      'device-b',
    );
    final otherBook = NovelSyncState().edit(
      'position/edition-two',
      {'chapter': 4},
      'device-c',
    );

    test('merge is idempotent for both settled and conflicting states', () {
      for (final state in [initial, laterA, laterA.merge(offlineB)]) {
        expect(_document(state.merge(state)), _document(state));
      }
    });

    test('merge is commutative across causal, concurrent and separate records',
        () {
      final states = [initial, laterA, offlineB, otherBook];
      for (final a in states) {
        for (final b in states) {
          expect(_document(a.merge(b)), _document(b.merge(a)));
        }
      }
    });

    test('merge is associative over mixed revision histories', () {
      final states = [initial, laterA, offlineB, otherBook];
      for (final a in states) {
        for (final b in states) {
          for (final c in states) {
            expect(
              _document(a.merge(b).merge(c)),
              _document(a.merge(b.merge(c))),
            );
          }
        }
      }
    });

    test('clock skew does not discard a concurrent earlier chapter', () {
      final merged = laterA.merge(offlineB);
      expect(merged.conflicts, contains(_positionKey));
      expect(
        merged.revisions(_positionKey).map((r) => r.value!['chapter']),
        unorderedEquals([11, 3]),
      );
      expect(() => merged.value(_positionKey), throwsStateError);
    });

    test('ordinary edit cannot silently resolve concurrent progress', () {
      final merged = laterA.merge(offlineB);
      expect(
        () => merged.edit(_positionKey, {'chapter': 12}, 'device-a'),
        throwsStateError,
      );
      expect(merged.revisions(_positionKey), hasLength(2));
    });

    test('causally newer rereading replaces a farther progress position', () {
      final reread = laterA.edit(
        _positionKey,
        {'chapter': 2, 'updatedAt': 0},
        'device-b',
      );
      final merged = laterA.merge(reread);
      expect(merged.conflicts, isEmpty);
      expect(merged.value(_positionKey)!['chapter'], 2);
    });

    test('concurrent bookmark delete and edit require explicit resolution', () {
      const key = 'bookmark/one';
      final base = NovelSyncState().edit(key, {'note': 'before'}, 'device-a');
      final deleted = base.edit(key, null, 'device-a');
      final edited = base.edit(key, {'note': 'offline edit'}, 'device-b');
      final merged = deleted.merge(edited);

      expect(merged.revisions(key), hasLength(2));
      final deletion = merged.revisions(key).singleWhere((r) => r.value == null);
      final resolved = merged.resolve(key, deletion, 'device-c',
          expectedToken: merged.conflictToken(key));
      expect(resolved.value(key), isNull);
      expect(resolved.revisions(key), hasLength(1));
      expect(resolved.merge(edited).value(key), isNull);
      expect(resolved.merge(base).value(key), isNull);
      expect(resolved.merge(deleted).conflicts, isEmpty);
    });

    test('resolving to the edited bookmark dominates the deletion too', () {
      const key = 'bookmark/two';
      final base = NovelSyncState().edit(key, {'note': 'before'}, 'device-a');
      final deleted = base.edit(key, null, 'device-a');
      final edited = base.edit(key, {'note': 'chosen'}, 'device-b');
      final merged = deleted.merge(edited);
      final selection = merged.revisions(key).singleWhere((r) => r.value != null);
      final resolved = merged.resolve(key, selection, 'device-c',
          expectedToken: merged.conflictToken(key));
      expect(resolved.merge(deleted).value(key)!['note'], 'chosen');
      expect(resolved.merge(edited).conflicts, isEmpty);
    });

    test('a stale selection cannot overwrite a changed conflict', () {
      final conflict = laterA.merge(offlineB);
      final selection = conflict.revisions(_positionKey).first;
      final token = conflict.conflictToken(_positionKey);
      final resolved = conflict.resolve(_positionKey, selection, 'device-c',
          expectedToken: token);
      expect(
        () => resolved.resolve(_positionKey, selection, 'device-a',
            expectedToken: token),
        throwsStateError,
      );
    });

    test('a newly arrived candidate invalidates a still-present selection', () {
      final shown = laterA.merge(offlineB);
      final selected = shown.revisions(_positionKey).first;
      final token = shown.conflictToken(_positionKey);
      final third = initial.edit(_positionKey, {'chapter': 7}, 'device-c');
      final current = shown.merge(third);
      final before = current.encode();
      expect(current.revisions(_positionKey), contains(selected));
      expect(current.revisions(_positionKey), hasLength(3));
      expect(
        () => current.resolve(_positionKey, selected, 'reader',
            expectedToken: token),
        throwsA(isA<StateError>().having((error) => error.message,
            'message', '冲突已发生变化，请重新选择')),
      );
      expect(current.encode(), before);
      expect(current.revisions(_positionKey), hasLength(3));
    });

    test('removing an unselected candidate invalidates the whole token', () {
      final shown = laterA.merge(offlineB);
      final selected = shown.revisions(_positionKey).first;
      final current = NovelSyncState({_positionKey: [selected]});
      final before = current.encode();
      expect(
        () => current.resolve(_positionKey, selected, 'reader',
            expectedToken: shown.conflictToken(_positionKey)),
        throwsStateError,
      );
      expect(current.encode(), before);
    });

    test('inspecting candidates without choosing never writes a resolution', () {
      final current = laterA.merge(offlineB);
      final before = current.encode();
      final displayed = current.revisions(_positionKey);
      final token = current.conflictToken(_positionKey);
      expect(displayed, hasLength(2));
      expect(token, isNotEmpty);
      // Cancel performs no resolve call; inspection must remain read-only.
      expect(current.encode(), before);
      expect(current.conflicts, contains(_positionKey));
    });

    test('token and rebuilt selection ignore candidate and JSON key order', () {
      final a = NovelRevision(clock: {'a': 2, 'b': 1}, value: {
        'chapter': 2,
        'anchor': {'quote': 'here', 'prefix': 'before'},
      });
      final b = NovelRevision(clock: {'a': 1, 'b': 2}, value: null);
      final shown = NovelSyncState({_positionKey: [a, b]});
      final rebuilt = NovelRevision(clock: {'b': 1, 'a': 2}, value: {
        'anchor': {'prefix': 'before', 'quote': 'here'},
        'chapter': 2,
      });
      final current = NovelSyncState({_positionKey: [b, rebuilt]});
      expect(current.conflictToken(_positionKey), shown.conflictToken(_positionKey));
      final selectedCopy = NovelRevision.fromJson(
          jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
      expect(identical(selectedCopy, a), isFalse);
      final resolved = current.resolve(_positionKey, selectedCopy, 'reader',
          expectedToken: shown.conflictToken(_positionKey));
      expect(resolved.value(_positionKey), rebuilt.value);
      expect(resolved.revisions(_positionKey).single.clock,
          {'a': 2, 'b': 2, 'reader': 1});
      expect(resolved.merge(shown).conflicts, isEmpty);
    });

    test('token changes with value or clock and preserves value list order', () {
      NovelSyncState state(Map<String, int> clock, List<int> values) =>
          NovelSyncState({_positionKey: [
            NovelRevision(clock: clock, value: {'items': values}),
          ]});
      final original = state({'a': 1}, [1, 2]).conflictToken(_positionKey);
      expect(state({'a': 2}, [1, 2]).conflictToken(_positionKey), isNot(original));
      expect(state({'a': 1}, [2, 1]).conflictToken(_positionKey), isNot(original));
    });

    test('valid token cannot authorize a different candidate payload', () {
      final current = laterA.merge(offlineB);
      final original = current.revisions(_positionKey).first;
      final forged = NovelRevision(clock: original.clock, value: {'chapter': 999});
      final before = current.encode();
      expect(
        () => current.resolve(_positionKey, forged, 'reader',
            expectedToken: current.conflictToken(_positionKey)),
        throwsStateError,
      );
      expect(current.encode(), before);
    });

    test('unrelated entity changes do not invalidate a displayed conflict', () {
      final shown = laterA.merge(offlineB);
      final current = shown.merge(otherBook);
      final resolved = current.resolve(
          _positionKey, shown.revisions(_positionKey).first, 'reader',
          expectedToken: shown.conflictToken(_positionKey));
      expect(resolved.conflicts, isEmpty);
      expect(resolved.value('position/edition-two'), otherBook.value('position/edition-two'));
    });

    test('causal coverage accepts semantic clock and object key equivalence', () {
      final a = NovelSyncState({_positionKey: [NovelRevision(
        clock: {'a': 1, 'b': 2},
        value: {'chapter': 2, 'anchor': {'before': '甲', 'after': '乙'}},
      )]});
      final b = NovelSyncState({_positionKey: [NovelRevision(
        clock: {'b': 2, 'a': 1},
        value: {'anchor': {'after': '乙', 'before': '甲'}, 'chapter': 2},
      )]});
      expect(a.covers(b), isTrue);
      expect(b.covers(a), isTrue);
      final conflictingPayload = NovelSyncState({_positionKey: [NovelRevision(
        clock: {'a': 1, 'b': 2}, value: {'chapter': 9},
      )]});
      expect(a.covers(conflictingPayload), isFalse);
      expect(conflictingPayload.covers(a), isFalse);
    });

    test('coverage needs every concurrent candidate and every entity', () {
      final concurrent = laterA.merge(offlineB);
      expect(concurrent.covers(laterA), isTrue);
      expect(concurrent.covers(offlineB), isTrue);
      expect(laterA.covers(concurrent), isFalse);
      expect(offlineB.covers(concurrent), isFalse);
      expect(concurrent.covers(otherBook), isFalse);
      expect(concurrent.merge(otherBook).covers(concurrent), isTrue);
      expect(concurrent.covers(concurrent.merge(otherBook)), isFalse);
      expect(NovelSyncState().covers(concurrent), isFalse);
      expect(concurrent.covers(NovelSyncState()), isTrue);
      final reordered = NovelSyncState({
        _positionKey: concurrent.revisions(_positionKey).reversed.toList(),
      });
      expect(concurrent.covers(reordered), isTrue);
      expect(reordered.covers(concurrent), isTrue);
    });

    test('coverage retains tombstones and distinguishes concurrent deletion', () {
      const key = 'bookmark/deleted';
      final base = NovelSyncState().edit(key, {'note': 'old'}, 'a');
      final deleted = base.edit(key, null, 'a');
      final edited = base.edit(key, {'note': 'offline'}, 'b');
      expect(deleted.covers(base), isTrue);
      expect(base.covers(deleted), isFalse);
      expect(NovelSyncState().covers(deleted), isFalse);
      expect(edited.covers(deleted), isFalse);
      expect(deleted.covers(edited), isFalse);
      final concurrent = deleted.merge(edited);
      final resolved = concurrent.resolve(key,
          concurrent.revisions(key).singleWhere((revision) => revision.value == null),
          'reader', expectedToken: concurrent.conflictToken(key));
      expect(resolved.covers(concurrent), isTrue);
      expect(concurrent.covers(resolved), isFalse);
      expect(resolved.merge(base).value(key), isNull);
    });

    test('coverage follows causal history rather than numeric reading progress', () {
      final reread = laterA.edit(_positionKey, {'chapter': 1}, 'device-a');
      expect(reread.covers(laterA), isTrue);
      expect(laterA.covers(reread), isFalse);
    });

    test('same revision accepts equivalent nested JSON with different key order',
        () {
      final a = NovelSyncState({
        _positionKey: [
          NovelRevision(clock: {'a': 1}, value: {
            'chapter': 2,
            'anchor': {'prefix': 'before', 'quote': 'here'},
          }),
        ],
      });
      final b = NovelSyncState({
        _positionKey: [
          NovelRevision(clock: {'a': 1}, value: {
            'anchor': {'quote': 'here', 'prefix': 'before'},
            'chapter': 2,
          }),
        ],
      });
      expect(a.merge(b).revisions(_positionKey), hasLength(1));
      expect(_document(a.merge(b)), _document(b.merge(a)));
    });

    test('same revision with genuinely different contents is rejected', () {
      final a = NovelSyncState().edit(_positionKey, {'chapter': 1}, 'a');
      final b = NovelSyncState().edit(_positionKey, {'chapter': 2}, 'a');
      expect(() => a.merge(b), throwsFormatException);
    });

    test('serialization preserves unresolved concurrent candidates', () {
      final state = laterA.merge(offlineB).merge(otherBook);
      final restored = NovelSyncState.decode(state.encode());
      expect(_document(restored), _document(state));
      expect(restored.conflicts, contains(_positionKey));
    });

    test('an unsupported document version cannot be accepted for rewriting', () {
      expect(
        () => NovelSyncState.decode('{"version":2,"entities":{}}'),
        throwsFormatException,
      );
    });
  });

  group('NovelLocator chapter identity', () {
    test('parses Arabic and formal Chinese chapter numbers', () {
      for (final entry in {
        '第二章 启程': 2,
        '第十二话': 12,
        '第两百零三章': 203,
        '第一千零二十四章': 1024,
        '第203章': 203,
      }.entries) {
        expect(NovelLocator.numberOf(entry.key), entry.value);
      }
      expect(NovelLocator.numberOf('后记'), isNull);
    });

    test('same chapter number in a different volume is never an exact match', () {
      final position = _capture('在这里继续阅读', 2);
      final correct = _chapter(
        url: 'https://second.test/book/chapter-two',
        title: '第2章 启程',
        volume: '第2卷',
      );
      final chapters = [
        _chapter(volume: '第一卷'),
        _chapter(kind: '番外'),
        _chapter(title: '第二章 别离'),
        _chapter(number: 3),
        correct,
      ];
      expect(
        NovelLocator.candidates(position, 'source-two', chapters),
        [correct],
      );
    });

    test('translated titles match the same volume and chapter number', () {
      final translated = _chapter(title: '第2章 出发', volume: '第2卷');
      expect(
        NovelLocator.candidates(_capture('这里是正文', 1), 'source-two', [
          _chapter(title: '第2章 出发', volume: '第1卷'),
          _chapter(title: '第3章 出发', number: 3),
          translated,
        ]),
        [translated],
      );
    });

    test('ambiguous duplicate chapters remain multiple candidates', () {
      final first = _chapter(url: 'https://second.test/a');
      final second = _chapter(url: 'https://second.test/b');
      expect(
        NovelLocator.candidates(
          _capture('这里是正文', 1),
          'source-two',
          [first, second],
        ),
        hasLength(2),
      );
    });

    test('missing chapter does not use the same catalog index as a substitute',
        () {
      expect(
        NovelLocator.candidates(
          _capture('这里是正文', 1),
          'source-two',
          [_chapter(number: 3, title: '第三章 归途')],
        ),
        isEmpty,
      );
    });
  });

  group('NovelLocator text evidence', () {
    final text = String.fromCharCodes(
      List.generate(180, (index) => 0x4e00 + index),
    );

    test('normalizes Chinese/Japanese punctuation and Unicode whitespace in VM',
        () {
      expect(
        NovelLocator.normalize('「你好，世界！」\u3000こんにちは。\nABC-42★'),
        '你好世界こんにちはabc42',
      );
      expect(NovelLocator.normalize('『カタカナ』・ひらがな'), 'カタカナひらがな');
    });

    test('same content restores exact semantic offset despite punctuation', () {
      final position = _capture('甲，乙。丙！丁？戊', 3);
      expect(NovelLocator.locate(position, '甲乙\n丙丁\u3000戊'), 3);
    });

    test('unique contextual anchor survives an insertion before its paragraph',
        () {
      final position = _capture(text, 45);
      const inserted = '新增加的前言';
      expect(
        NovelLocator.locate(position, '$inserted$text'),
        NovelLocator.normalize(inserted).length + 45,
      );
    });

    test('repeated matching context is ambiguous rather than first-match wins',
        () {
      final position = _capture(text, 45);
      expect(NovelLocator.locate(position, '$text$text'), isNull);
    });

    test('changed text without an anchor requires explicit location selection',
        () {
      final position = _capture(text, 45);
      expect(NovelLocator.locate(position, '这是另外一个译本，无法证明对应原文位置。'), isNull);
    });

    test('chapter end is recoverable when the complete content is unchanged',
        () {
      final position = _capture(text, NovelLocator.normalize(text).length);
      expect(position.quote, isEmpty);
      expect(NovelLocator.locate(position, text), 180);
      expect(NovelLocator.locate(position, '$text新增内容'), isNull);
    });
  });
}
