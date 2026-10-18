import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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
import 'novel_anime_resolver.dart';
import 'novel_ai.dart';
import 'novel_accounts.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';

class NovelService extends ChangeNotifier implements NovelReaderStore {
  NovelService(this.webDav, {Dio Function()? aiClient}) : _aiClient = aiClient ??
    (() => Dio(BaseOptions(connectTimeout: const Duration(seconds: 15))));
  final WebDav webDav;
  final Dio Function() _aiClient;
  final _writes = AsyncSerialQueue();
  final _ruleWrites = AsyncSerialQueue();
  final _anime = NovelAnimeResolver();
  NovelAiSettings _aiSettings = const NovelAiSettings();
  NovelAiSettings get aiSettings => _aiSettings;
  Future<void> saveAiSettings(NovelAiSettings value) async {
    value.validate();
    await _box.put('aiSettings', jsonEncode(value.toJson()));
    _aiSettings = value;
    notifyListeners();
  }
  Future<List<String>> suggestTitles(String title, {required bool toAnime,
      NovelAiSettings? settings, CancelToken? cancelToken}) async {
    final dio = _aiClient();
    try {
      return await NovelAiClient(dio).titles(settings ?? aiSettings, title,
        toAnime: toAnime, cancelToken: cancelToken);
    } finally {
      dio.close();
    }
  }
  Future<List<BangumiItem>> animeForTitle(String title) => _anime.forTitle(title);
  late Box<String> _box, _cache, _rules;
  late String deviceId;
  late NovelHttpSession _http;
  final _credentials = const NovelCredentialStore();
  late NovelAccounts _accounts;
  @override
  NovelSyncState state = NovelSyncState();
  Map<String, List<String>> _seen = {};
  @override
  String? syncError;
  String? syncNotice;
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
    final ai = _box.get('aiSettings');
    if (ai != null) _aiSettings = NovelAiSettings.fromJson(jsonDecode(ai) as NovelJson);
    _http = NovelHttpSession(
      () => DioFactory.pluginDio,
      '$path/novel_sessions',
    );
    _accounts = NovelAccounts(_http, _credentials);
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
  }

  List<NovelRule> get rules => _rules.values.map(NovelRule.decode).toList();
  NovelRule rule(String id) => rules.singleWhere((r) => r.id == id);
  NovelSourceAdapter adapter(String id) {
    final source = rule(id);
    return NovelAuthenticatedSource(XPathNovelAdapter(source,
      (url, method, headers, body) => _http.fetch(source, url, method, headers, body)),
      source, _accounts);
  }

  String accountName(String sourceId) => _box.get('account/$sourceId') ?? '';
  Future<NovelAccount?> accountCredentials(String sourceId) => _credentials.read(rule(sourceId));
  Future<void> login(String sourceId, String username, String password) async {
    await _accounts.login(rule(sourceId), NovelAccount(username, password));
    await _box.put('account/$sourceId', username);
  }
  Future<void> verifyAccount(String sourceId) => _http.verify(rule(sourceId));
  Future<void> logout(String sourceId) async {
    await _accounts.logout(rule(sourceId));
    await _box.delete('account/$sourceId');
  }
  @override
  Future<Uint8List> image(String sourceId, String url) async {
    final key = 'image/$sourceId/$url';
    final cached = _cache.get(key);
    if (cached != null) return base64Decode(cached);
    final source = rule(sourceId);
    final bytes = await _accounts.execute(source, () => _http.image(source, url));
    await _cache.put(key, base64Encode(bytes));
    return bytes;
  }

  Future<void> importRule(String raw) async {
    await importRules([NovelRule.decode(raw)]);
  }

  Future<void> importRules(Iterable<NovelRule> rules) => _ruleWrites.run(() async {
    final imported = rules.toList();
    await _rules.putAll({for (final rule in imported) rule.id: rule.encode()});
    await _box.deleteAll(imported.map((rule) => 'ruleRemoved/${rule.id}'));
    notifyListeners();
  });

  Future<void> removeRule(String id) => _ruleWrites.run(() async {
    await _rules.delete(id);
    await _box.put('ruleRemoved/$id', '1');
    notifyListeners();
  });

  /// Install the separate rule repository once. Deletions remain intentional;
  /// a failed download is reported to the caller and can be retried.
  bool get needsDefaultRules => _box.get('defaultRulesInstalled') != '4';

  Future<void> ensureDefaultRules() {
    if (!needsDefaultRules) return Future.value();
    return _defaultRulesInstallation ??= _installDefaultRules().whenComplete(
      () => _defaultRulesInstallation = null,
    );
  }

  Future<void> _installDefaultRules() async {
    final url = ruleCatalogUrl ?? defaultCatalog;
    await _ruleWrites.run(() async {
      if (_box.get('defaultRulesInstalled') == '1' && ruleCatalogUrl == null) {
        for (final id in ['wenku8', 'syosetu']) {
          if (!_rules.containsKey(id)) await _box.put('ruleRemoved/$id', '1');
        }
      }
    });
    Future<String> get(String address) async =>
        (await DioFactory.pluginDio.get<String>(
          address,
          options: Options(responseType: ResponseType.plain),
        )).data!;
    final catalog = jsonDecode(await get(url)) as NovelJson;
    if (catalog['version'] != 1) throw const FormatException('不支持的规则索引版本');
    final candidates = <String, (String, List<String>)>{};
    for (final entry in catalog['rules'] as List) {
      if (_box.get('ruleRemoved/${entry['id']}') == '1') continue;
      final parsed = NovelRule.decode(
        await get(Uri.parse(url).resolve(entry['file'] as String).toString()),
      );
      if (parsed.id != entry['id']) {
        throw const FormatException('规则文件 id 与索引条目不一致');
      }
      candidates[parsed.id] = (parsed.encode(), entry.containsKey('replaces')
        ? List<String>.from(entry['replaces'] as List) : const []);
    }
    await _ruleWrites.run(() async {
      if (url != (ruleCatalogUrl ?? defaultCatalog)) {
        throw StateError('规则仓库已更换，请重试获取默认书源');
      }
      final downloads = <String, String>{};
      for (final entry in candidates.entries) {
        if (_box.get('ruleRemoved/${entry.key}') == '1') continue;
        final current = _rules.get(entry.key);
        if (current == null || entry.value.$2.contains(sha256.convert(utf8.encode(current)).toString())) {
          downloads[entry.key] = entry.value.$1;
        }
      }
      await _rules.putAll(downloads);
      await _rules.flush();
      // Hive enumerates IDs alphabetically; prefer the first installed catalog source.
      if (preferredSource == null && _rules.isNotEmpty) {
        final first = (catalog['rules'] as List).where((entry) => _rules.containsKey(entry['id'])).firstOrNull;
        if (first != null) await selectSource(first['id'] as String);
      }
      await _box.put('defaultRulesInstalled', '4');
      await _box.flush();
    });
    notifyListeners();
  }

  String? get preferredSource => _box.get('preferredSource');
  Future<void> selectSource(String id) => _box.put('preferredSource', id);

  String? get ruleCatalogUrl => _box.get('ruleCatalogUrl');
  Future<void> saveRuleCatalogUrl(String url) =>
      _ruleWrites.run(() => _box.put('ruleCatalogUrl', url));

  void refreshView() => notifyListeners();
  List<NovelEdition> get editions => state
      .keys('edition')
      .where(
        (key) => state.revisions(key).length == 1 && state.value(key) != null,
      )
      .map((key) => NovelEdition.fromJson(state.value(key)!))
      .toList();
  NovelWork work(String id) => NovelWork.fromJson(state.value('work/$id')!);
  bool isShelved(String editionId) {
    final revisions = state.revisions('shelf/$editionId');
    if (revisions.isNotEmpty) {
      return revisions.length == 1 && revisions.single.value != null;
    }
    // 0.1.0 treated every edition as a shelf item. Preserve those records.
    return state.value('edition/$editionId')?['preview'] != true;
  }

  List<NovelEdition> get shelfEditions =>
      editions.where((e) => isShelved(e.id)).toList();

  @override
  Future<String> chapterReadIdentity(
    String editionId,
    NovelBook book,
    NovelChapter chapter,
    NovelPosition? restoredFrom,
  ) async {
    String key(String source, String url) =>
        'readChapterIdentity/$editionId/$source/$url';
    final current = key(book.sourceId, chapter.url);
    final known = _box.get(current);
    if (known != null) return known;
    var identity = current;
    if (restoredFrom != null) {
      final original = key(restoredFrom.sourceId, restoredFrom.chapter.url);
      identity = _box.get(original) ?? original;
    }
    await _box.put(current, identity);
    return identity;
  }

  Future<int> recordReadChapters(String editionId, Set<String> chapters) async {
    final key = 'readChapters/$editionId';
    final read = <String>{
      if (_box.get(key) != null)
        ...List<String>.from(jsonDecode(_box.get(key)!) as List),
      ...chapters,
    };
    await _box.put(key, jsonEncode(read.toList()));
    return read.length;
  }

  Future<void> addToShelf(String editionId, {int animeId = 0}) => _commit(
    (s) => s.edit('shelf/$editionId', {
      'editionId': editionId,
      'animeId': animeId,
    }, deviceId),
  );

  Future<void> removeFromShelf(String editionId) =>
      _commit((s) => s.edit('shelf/$editionId', null, deviceId));

  List<int> animeIdsForEdition(String editionId) => state
      .keys('anime')
      .where(
        (key) => state.revisions(key).length == 1 && state.value(key) != null,
      )
      .map(state.value)
      .whereType<NovelJson>()
      .where((j) => (j['editionIds'] as List).contains(editionId))
      .map((j) => j['animeId'] as int)
      .toList();

  Future<List<BangumiItem>> relatedAnime(NovelBook book,
      {String? editionId, bool refresh = false}) {
    final ids = animeIdsForBook(book, editionId: editionId);
    return ids.isEmpty ? _anime.forTitle(book.title, refresh: refresh)
        : _anime.forIds(ids, refresh: refresh);
  }

  List<int> animeIdsForBook(NovelBook book, {String? editionId}) {
    final id = editionId ?? editionForBook(book);
    return id == null ? <int>[] : animeIdsForEdition(id);
  }

  String? editionForBook(NovelBook book) {
    for (final edition in editions) {
      final key = 'source/${edition.id}/${book.sourceId}';
      final candidates = state.revisions(key);
      if (candidates.length > 1 && !candidates.any((revision) =>
          (revision.value?['book'] as NovelJson?)?['url'] == book.url)) continue;
      final source = state.value(key);
      if (source != null && (source['book'] as NovelJson)['url'] == book.url)
        return edition.id;
    }
    return null;
  }

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
  String chapterMappingKey(NovelPosition from, NovelBook target) =>
      _mappingKey(from.editionId, from.sourceId, from.chapter.url, target);

  @override
  List<String> chapterMappingWriteKeys(
    NovelPosition from, NovelBook target, NovelChapter chapter,
  ) {
    final sourceKey = 'source/${from.editionId}/${from.sourceId}';
    final keys = [sourceKey, chapterMappingKey(from, target)];
    if (state.revisions(sourceKey).length > 1) return keys;
    final source = state.value(sourceKey);
    if (source != null) {
      final original = NovelBook.fromJson(source['book'] as NovelJson);
      keys.add(_mappingKey(from.editionId, target.sourceId, chapter.url, original));
    }
    return keys;
  }

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
        s = s.edit('edition/$editionId', {
          ...NovelEdition(editionId, workId, editionLabel, language).toJson(),
          'preview': true,
        }, deviceId);
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
  Future<void> resolve(String key, NovelRevision selected, {
    required String expectedToken,
  }) => _commit((s) => s.resolve(key, selected, deviceId,
      expectedToken: expectedToken));

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
  @override
  Future<void> retrySync() async {
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
    syncNotice = null;
    notifyListeners();
    try {
      final account =
          '${GStorage.getSetting(SettingsKeys.webDavURL)}\n'
          '${GStorage.getSetting(SettingsKeys.webDavUsername)}\n';
      final legacyScope = sha256.convert(
        utf8.encode('$account/kazumiSync/novels/v1'),
      ).toString();
      final scope = sha256
          .convert(
            utf8.encode(
              '$account/kazumiSync/novels',
            ),
          )
          .toString();
      var migrated = false;
      final published = await webDav.syncNovels(
        deviceId: deviceId,
        knownSnapshots: (_seen[scope] ?? []).toSet(),
        onLegacyDetected: () {
          migrated = true;
          syncNotice = '正在迁移旧版小说同步数据…';
          notifyListeners();
        },
        merge: (remote, names) async {
          await _commit(
            (s) => s.merge(remote),
            seen: {
              ...(Map<String, List<String>>.from(_seen)..remove(legacyScope)),
              scope: names.toList()..sort(),
            },
          );
          return state;
        },
      );
      if (published != null) {
        await _commit(
          (s) => s,
          seen: {
            ..._seen,
            scope: {...?_seen[scope], published}.toList()..sort(),
          },
        );
      }
      syncError = null;
      syncNotice = migrated ? '旧版小说数据已合并，其他设备请升级。' : null;
      lastSync = DateTime.now();
    } catch (error) {
      syncNotice = null;
      syncError = error.toString();
      rethrow;
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

}
