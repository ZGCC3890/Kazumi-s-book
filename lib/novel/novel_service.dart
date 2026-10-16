import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'novel_models.dart';
import 'novel_rule.dart';
import 'novel_sync_state.dart';
import 'novel_reader_store.dart';
import 'novel_http_session.dart';

class NovelService extends ChangeNotifier
    with WidgetsBindingObserver
    implements NovelReaderStore {
  NovelService(this.webDav);
  final WebDav webDav;
  final _writes = AsyncSerialQueue();
  late Box<String> _box, _cache, _rules;
  late String deviceId;
  late NovelHttpSession _http;
  @override
  NovelSyncState state = NovelSyncState();
  Map<String, List<String>> _seen = {};
  Timer? _syncTimer, _poll;
  @override
  String? syncError;
  DateTime? lastSync;
  bool syncing = false;
  Future<void>? _initialization;
  Future<void>? _defaultRulesInstallation;
  static const defaultCatalog =
      'https://raw.githubusercontent.com/ZGCC3890/'
      'Kazumi-s-book/feature/novel-reader/novel_rules/catalog.json';

  static String newId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<void> init() => _initialization ??= _init();
  Future<void> _init() async {
    final path = '${(await getApplicationSupportDirectory()).path}/hive';
    _box = await Hive.openBox<String>('novel_v1', path: path);
    _cache = await Hive.openBox<String>('novel_cache_v1', path: path);
    _rules = await Hive.openBox<String>('novel_rules_v1', path: path);
    _http = NovelHttpSession(DioFactory.pluginDio, '$path/novel_sessions');
    final storedId = _box.get('deviceId');
    deviceId = storedId ?? newId();
    if (storedId == null) await _box.put('deviceId', deviceId);
    final stored = _box.get('state');
    if (stored != null) {
      final local = jsonDecode(stored) as NovelJson;
      state = NovelSyncState.decode(local['data'] as String);
      _seen = (local['seen'] as NovelJson).map(
        (k, v) => MapEntry(k, List<String>.from(v as List)),
      );
    }
    WidgetsBinding.instance.addObserver(this);
    _poll = Timer.periodic(
      const Duration(seconds: 30),
      (_) => syncAutomatically(),
    );
    unawaited(syncAutomatically());
  }

  List<NovelRule> get rules => _rules.values.map(NovelRule.decode).toList();
  NovelRule rule(String id) => rules.singleWhere((r) => r.id == id);
  NovelSourceAdapter adapter(String id) => XPathNovelAdapter(
    rule(id),
    (url, method, headers, body) =>
        _http.fetch(rule(id), url, method, headers, body),
  );

  Future<void> login(String sourceId, String username, String password) =>
      _http.login(rule(sourceId), username, password);
  Future<void> logout(String sourceId) => _http.logout(rule(sourceId));
  @override
  Future<Uint8List> image(String sourceId, String url) async {
    final key = 'image/$sourceId/$url';
    final cached = _cache.get(key);
    if (cached != null) return base64Decode(cached);
    final bytes = await _http.image(rule(sourceId), url);
    await _cache.put(key, base64Encode(bytes));
    return bytes;
  }

  Future<void> importRule(String raw) async {
    final parsed = NovelRule.decode(raw);
    await _rules.put(parsed.id, parsed.encode());
    notifyListeners();
  }

  Future<void> removeRule(String id) async {
    await _rules.delete(id);
    notifyListeners();
  }

  /// Install the separate rule repository once. Deletions remain intentional;
  /// a failed download is reported to the caller and can be retried.
  Future<void> ensureDefaultRules() {
    if (_box.get('defaultRulesInstalled') == '1') return Future.value();
    return _defaultRulesInstallation ??= _installDefaultRules().whenComplete(
      () => _defaultRulesInstallation = null,
    );
  }

  Future<void> _installDefaultRules() async {
    final url = ruleCatalogUrl ?? defaultCatalog;
    Future<String> get(String address) async =>
        (await DioFactory.pluginDio.get<String>(
          address,
          options: Options(responseType: ResponseType.plain),
        )).data!;
    final catalog = jsonDecode(await get(url)) as NovelJson;
    if (catalog['version'] != 1) throw const FormatException('不支持的规则索引版本');
    final downloads = <String, String>{};
    for (final entry in catalog['rules'] as List) {
      final parsed = NovelRule.decode(
        await get(Uri.parse(url).resolve(entry['file'] as String).toString()),
      );
      if (parsed.id != entry['id']) {
        throw const FormatException('规则文件 id 与索引条目不一致');
      }
      final current = _rules.get(parsed.id);
      if (current == null ||
          (entry.containsKey('replaces') &&
              (entry['replaces'] as List).contains(
                sha256.convert(utf8.encode(current)).toString(),
              ))) {
        downloads[parsed.id] = parsed.encode();
      }
    }
    await _rules.putAll(downloads);
    await _rules.flush();
    await _box.put('defaultRulesInstalled', '1');
    await _box.flush();
    notifyListeners();
  }

  String? get preferredSource => _box.get('preferredSource');
  Future<void> selectSource(String id) => _box.put('preferredSource', id);

  String? get ruleCatalogUrl => _box.get('ruleCatalogUrl');
  Future<void> saveRuleCatalogUrl(String url) =>
      _box.put('ruleCatalogUrl', url);

  void refreshView() => notifyListeners();
  List<NovelEdition> get editions => state
      .keys('edition')
      .where(
        (key) => state.revisions(key).length == 1 && state.value(key) != null,
      )
      .map((key) => NovelEdition.fromJson(state.value(key)!))
      .toList();
  NovelWork work(String id) => NovelWork.fromJson(state.value('work/$id')!);
  List<String> boundEditions(int animeId) {
    final j = state.value('anime/$animeId');
    return j == null ? [] : List<String>.from(j['editionIds'] as List);
  }

  NovelBook? selectedBook(String editionId) {
    final j = state.value('selected/$editionId');
    if (j == null) return null;
    final book = state.value('source/$editionId/${j['sourceId']}');
    return book == null ? null : NovelBook.fromJson(book['book'] as NovelJson);
  }

  @override
  NovelPosition? position(String editionId) {
    final j = state.value('position/$editionId');
    return j == null ? null : NovelPosition.fromJson(j);
  }

  String _mappingKey(
    String editionId,
    String sourceId,
    String chapterUrl,
    NovelBook target,
  ) =>
      'chapterMap/$editionId/${sha256.convert(utf8.encode(jsonEncode([sourceId, chapterUrl, target.sourceId, target.url])))}';

  @override
  NovelChapter? mappedChapter(NovelPosition from, NovelBook target) {
    final value = state.value(
      _mappingKey(from.editionId, from.sourceId, from.chapter.url, target),
    );
    return value == null
        ? null
        : NovelChapter.fromJson(value['chapter'] as NovelJson);
  }

  @override
  Future<void> confirmChapterMapping(
    NovelPosition from,
    NovelBook target,
    NovelChapter chapter,
  ) => _commit((s) {
    final originalBook = NovelBook.fromJson(
      s.value('source/${from.editionId}/${from.sourceId}')!['book']
          as NovelJson,
    );
    return s
        .edit(
          _mappingKey(from.editionId, from.sourceId, from.chapter.url, target),
          {
            'editionId': from.editionId,
            'fromSourceId': from.sourceId,
            'fromChapter': from.chapter.toJson(),
            'targetBook': target.toJson(),
            'chapter': chapter.toJson(),
          },
          deviceId,
        )
        .edit(
          _mappingKey(
            from.editionId,
            target.sourceId,
            chapter.url,
            originalBook,
          ),
          {
            'editionId': from.editionId,
            'fromSourceId': target.sourceId,
            'fromChapter': chapter.toJson(),
            'targetBook': originalBook.toJson(),
            'chapter': from.chapter.toJson(),
          },
          deviceId,
        );
  });

  @override
  List<NovelJson> bookmarks(String editionId) => state
      .keys('bookmark')
      .where((key) => state.revisions(key).length == 1)
      .map(state.value)
      .whereType<NovelJson>()
      .where((j) => (j['position'] as NovelJson)['editionId'] == editionId)
      .toList();

  Future<void> _commit(
    NovelSyncState Function(NovelSyncState) change, {
    bool local = true,
    Map<String, List<String>>? seen,
  }) => _writes.run(() async {
    final next = change(state);
    if (next.encode() == state.encode() && seen == null) return;
    // Payload and causal revision share a single persisted record.
    await _box.put(
      'state',
      jsonEncode({'data': next.encode(), 'seen': seen ?? _seen}),
    );
    await _box.flush();
    state = next;
    if (seen != null) _seen = seen;
    notifyListeners();
    if (local) _scheduleSync();
  });

  Future<String> bind({
    required int animeId,
    required NovelBook book,
    required String editionLabel,
    required String language,
    String? existingEditionId,
    String? existingWorkId,
  }) async {
    final editionId = existingEditionId ?? newId();
    final workId = existingWorkId ?? newId();
    await _commit((s) {
      if (existingEditionId == null) {
        if (existingWorkId == null) {
          s = s.edit(
            'work/$workId',
            NovelWork(workId, book.title, book.author).toJson(),
            deviceId,
          );
        }
        s = s.edit(
          'edition/$editionId',
          NovelEdition(editionId, workId, editionLabel, language).toJson(),
          deviceId,
        );
      }
      if (animeId > 0) {
        final old = s.value('anime/$animeId');
        final ids = old == null
            ? <String>[]
            : List<String>.from(old['editionIds'] as List);
        s = s.edit('anime/$animeId', {
          'animeId': animeId,
          'editionIds': {...ids, editionId}.toList(),
          'confirmed': true,
        }, deviceId);
      }
      return s
          .edit('source/$editionId/${book.sourceId}', {
            'book': book.toJson(),
            'editionId': editionId,
            'ruleVersion': rule(book.sourceId).json['version'],
            'confirmedAt': DateTime.now().millisecondsSinceEpoch,
          }, deviceId)
          .edit('selected/$editionId', {'sourceId': book.sourceId}, deviceId);
    });
    return editionId;
  }

  @override
  Future<void> savePosition(NovelPosition position) => _commit((s) {
    final key = 'position/${position.editionId}';
    if (jsonEncode(s.value(key)) == jsonEncode(position.toJson())) return s;
    return s.edit(key, position.toJson(), deviceId);
  });
  @override
  Future<void> addBookmark(NovelPosition position, String note) {
    final id = newId();
    return _commit(
      (s) => s.edit('bookmark/$id', {
        'id': id,
        'position': position.toJson(),
        'note': note,
      }, deviceId),
    );
  }

  @override
  Future<void> deleteBookmark(String id) =>
      _commit((s) => s.edit('bookmark/$id', null, deviceId));
  @override
  Future<void> resolve(String key, NovelRevision selected) =>
      _commit((s) => s.resolve(key, selected, deviceId));

  @override
  Future<List<NovelChapter>> catalog(
    NovelBook book, {
    bool refresh = false,
  }) async {
    final key =
        'catalog/${sha256.convert(utf8.encode(rule(book.sourceId).encode()))}/${book.url}';
    final cached = _cache.get(key);
    if (!refresh && cached != null) {
      return (jsonDecode(cached) as List)
          .map((j) => NovelChapter.fromJson(j as NovelJson))
          .toList();
    }
    final chapters = await adapter(book.sourceId).catalog(book);
    await _cache.put(key, jsonEncode(chapters.map((c) => c.toJson()).toList()));
    return chapters;
  }

  @override
  Future<List<NovelBlock>> content(
    String sourceId,
    NovelChapter chapter, {
    bool refresh = false,
  }) async {
    final key =
        'content/${sha256.convert(utf8.encode(rule(sourceId).encode()))}/${chapter.url}';
    final cached = _cache.get(key);
    if (!refresh && cached != null) {
      return (jsonDecode(cached) as List)
          .map((j) => NovelBlock.fromJson(j as NovelJson))
          .toList();
    }
    final blocks = await adapter(sourceId).content(chapter);
    await _cache.put(key, jsonEncode(blocks.map((b) => b.toJson()).toList()));
    return blocks;
  }

  @override
  NovelJson get preferences {
    final raw = _box.get('preferences');
    return raw == null
        ? {
            'fontSize': 20.0,
            'lineHeight': 1.8,
            'theme': 0,
            'mode': 'scroll',
            'font': 'system',
            'margin': 24.0,
            'brightness': 0.0,
          }
        : jsonDecode(raw) as NovelJson;
  }

  @override
  Future<void> savePreferences(NovelJson value) =>
      _box.put('preferences', jsonEncode(value));

  bool get syncEnabled =>
      GStorage.getSetting(SettingsKeys.webDavEnable) &&
      GStorage.getSetting(SettingsKeys.webDavEnableNovels);
  void _scheduleSync() {
    if (!syncEnabled || _syncTimer != null) return;
    _syncTimer = Timer(const Duration(seconds: 15), () {
      _syncTimer = null;
      unawaited(syncAutomatically());
    });
  }

  @override
  Future<void> syncAutomatically() async {
    if (!syncEnabled || syncing) return;
    try {
      await sync();
    } catch (error) {
      // Failure remains visible; local revisions are never discarded.
      syncError = error.toString();
      notifyListeners();
    }
  }

  Future<void> sync() async {
    if (!syncEnabled) throw StateError('请先启用 WebDAV 小说同步');
    if (syncing) return;
    syncing = true;
    notifyListeners();
    try {
      final scope = sha256
          .convert(
            utf8.encode(
              '${GStorage.getSetting(SettingsKeys.webDavURL)}\n'
              '${GStorage.getSetting(SettingsKeys.webDavUsername)}\n/kazumiSync/novels/v1',
            ),
          )
          .toString();
      final published = await webDav.syncNovels(
        deviceId: deviceId,
        knownSnapshots: (_seen[scope] ?? []).toSet(),
        merge: (remote, names) async {
          await _commit(
            (s) => s.merge(remote),
            local: false,
            seen: {..._seen, scope: names.toList()..sort()},
          );
          return state;
        },
      );
      if (published != null) {
        await _commit(
          (s) => s,
          local: false,
          seen: {
            ..._seen,
            scope: {...?_seen[scope], published}.toList()..sort(),
          },
        );
      }
      syncError = null;
      lastSync = DateTime.now();
    } catch (error) {
      syncError = error.toString();
      rethrow;
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused) {
      unawaited(syncAutomatically());
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
