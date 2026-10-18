import 'dart:async';
import 'package:flutter/material.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'novel_models.dart';
import 'novel_rule.dart';
import 'novel_reader_page.dart';
import 'novel_service.dart';
import 'novel_search_query.dart';
import 'novel_search_results.dart';
import 'novel_rules_page.dart';
import 'novel_conflicts.dart';
import 'novel_account_dialog.dart';
import 'novel_ai_page.dart';

class NovelEntry {
  static Future<void> conflicts(
    BuildContext context,
    NovelService service,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (_) => ListenableBuilder(
        listenable: service,
        builder: (_, _) => SafeArea(child: ListView(
          children: [
            const ListTile(title: Text('需要选择的阅读数据')),
            for (final key in service.state.conflicts)
              NovelConflictTile(store: service, recordKey: key),
          ],
        )),
      ),
    );
  }

  static Future<void> open(
    BuildContext context,
    BangumiItem anime,
    NovelService service,
  ) async {
    try {
      await _open(context, anime, service);
    } catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  static Future<void> _open(
    BuildContext context,
    BangumiItem anime,
    NovelService service,
  ) async {
    if (!await NovelConflicts.ensure(context, service,
        () => ['anime/${anime.id}'])) return;
    if (!context.mounted) return;
    final ids = service.boundEditions(anime.id);
    if (ids.isEmpty) {
      var query = novelQueryFromAnime(anime.nameCn.isEmpty ? anime.name : anime.nameCn);
      if (service.aiSettings.enabled) {
        final selected = await chooseAiTitle(context, service, query, toAnime: false);
        if (selected == null || !context.mounted) return;
        query = selected;
      }
      await search(
        context,
        service,
        anime.id,
        query,
      );
      return;
    }
    var id = ids.first;
    if (ids.length > 1) {
      final selected = await showModalBottomSheet<String>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) => ListenableBuilder(
          listenable: service,
          builder: (_, _) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('选择小说')),
              for (final candidate in ids)
                for (final key in NovelConflicts.displayKeys(service.state, candidate, includeShelf: false))
                  NovelConflictTile(store: service, recordKey: key),
              for (final edition in service.editions.where(
                (e) => ids.contains(e.id) &&
                    NovelConflicts.displayKeys(service.state, e.id, includeShelf: false).isEmpty,
              ))
                ListTile(
                  title: Text(NovelConflicts.workDeleted(service.state, edition.id)
                      ? '作品信息已删除' : service.work(edition.workId).title),
                  subtitle: Text(NovelConflicts.workDeleted(service.state, edition.id)
                      ? '仍可选择书源继续阅读' : service.work(edition.workId).author),
                  onTap: () => Navigator.pop(ctx, edition.id),
                ),
            ],
          ),
        ),
        ),
      );
      if (selected == null || !context.mounted) return;
      id = selected;
    }
    if (!context.mounted) return;
    await read(context, service, id, animeId: anime.id);
  }

  static Future<void> read(
    BuildContext context,
    NovelService service,
    String editionId, {
    int animeId = 0,
  }) async {
    if (!await NovelConflicts.ensure(context, service,
        () => NovelConflicts.sourceKeys(service.state, editionId))) return;
    if (!context.mounted) return;
    final book = service.selectedBook(editionId);
    if (book == null) throw StateError('这本小说尚未选择书源');
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute(
        builder: (readerContext) => NovelReaderPage(
          service: service,
          editionId: editionId,
          book: book,
          onLeave: (chapters) async {
            if (chapters.isEmpty) return;
            final count = await service.recordReadChapters(editionId, chapters);
            if (count > 1 && readerContext.mounted &&
                !await NovelConflicts.ensure(readerContext, service,
                    () => ['shelf/$editionId'])) return;
            if (count <= 1 ||
                service.isShelved(editionId) ||
                !readerContext.mounted)
              return;
            final associations = service.animeIdsForEdition(editionId);
            final targetAnimeId = animeId > 0
                ? animeId
                : associations.length == 1
                ? associations.single
                : 0;
            final add = await showDialog<bool>(
              context: readerContext,
              builder: (ctx) => AlertDialog(
                title: const Text('加入书架？'),
                content: const Text('已读过一章以上，加入书架方便下次继续阅读。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('暂不添加'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('加入书架'),
                  ),
                ],
              ),
            );
            if (add != true) return;
            await service.addToShelf(editionId, animeId: targetAnimeId);
          },
        ),
      ),
    );
  }

  static Future<void> search(
    BuildContext context,
    NovelService service,
    int animeId,
    String title, {
    String? editionId,
    String? workId,
  }) async {
    final selected = await showAdaptiveBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      maxHeightFactor: .88,
      builder: (_) => NovelSearchPage(
        service: service,
        animeId: animeId,
        initialQuery: title,
        existingEditionId: editionId,
        existingWorkId: workId,
      ),
    );
    if (selected != null && context.mounted) {
      await read(context, service, selected, animeId: animeId);
    }
  }
}

class NovelSearchPage extends StatefulWidget {
  const NovelSearchPage({
    super.key,
    required this.service,
    required this.animeId,
    required this.initialQuery,
    this.existingEditionId,
    this.existingWorkId,
  }) : embedded = false,
       onSelected = null,
       header = null;
  const NovelSearchPage.results({
    super.key,
    required this.service,
    required this.initialQuery,
    required this.onSelected,
    required this.header,
  }) : animeId = 0,
       existingEditionId = null,
       existingWorkId = null,
       embedded = true;
  final NovelService service;
  final bool embedded;
  final Widget? header;
  final Future<void> Function(String editionId)? onSelected;
  final int animeId;
  final String initialQuery;
  final String? existingEditionId, existingWorkId;
  @override
  State<NovelSearchPage> createState() => _NovelSearchPageState();
}

class _NovelSearchPageState extends State<NovelSearchPage> {
  late final TextEditingController _query;
  String? _source;
  final Map<String, List<NovelBook>> _results = {};
  final Map<String, String> _errors = {};
  final Map<String, int> _sourceRequests = {};
  final Set<String> _loading = {}, _loginRequired = {};
  int _generation = 0;
  String _submittedQuery = '';
  bool _busy = false;
  String? _error;
  bool _updatingRules = false;
  String? _rulesError;
  @override
  void initState() {
    super.initState();
    _query = TextEditingController(text: widget.initialQuery);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prepare();
    });
  }

  Future<void> _prepare() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = widget.service;
      if (service.rules.isEmpty) await service.ensureDefaultRules();
      if (!mounted) return;
      if (service.rules.isEmpty) throw StateError('没有已启用的小说书源，请在书架的小说规则中添加');
      final preferred = service.preferredSource;
      setState(() {
        _source = service.rules.any((r) => r.id == preferred)
            ? preferred
            : service.rules.first.id;
        _busy = false;
      });
      if (service.needsDefaultRules && !_updatingRules) unawaited(_updateDefaults());
      await _search();
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _busy = false;
        });
    }
  }

  Future<void> _updateDefaults() async {
    setState(() { _updatingRules = true; _rulesError = null; });
    final installed = {for (final rule in widget.service.rules) rule.id: rule.encode()};
    try {
      await widget.service.ensureDefaultRules();
      if (!mounted || _submittedQuery.isEmpty) return;
      final changed = widget.service.rules.where((rule) => installed[rule.id] != rule.encode()).toList();
      final generation = _generation, query = _submittedQuery;
      setState(() {
        for (final rule in changed) {
          _results.remove(rule.id);
          _errors.remove(rule.id);
          _loginRequired.remove(rule.id);
          _loading.add(rule.id);
        }
      });
      await Future.wait(changed.map((rule) => _searchSource(rule.id, query, generation)));
    } catch (error) {
      if (mounted) setState(() => _rulesError = error.toString());
    } finally {
      if (mounted) setState(() => _updatingRules = false);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_query.text.trim().isEmpty) return;
    final generation = ++_generation;
    final query = _query.text.trim();
    _submittedQuery = query;
    setState(() {
      _error = null;
      _results.clear();
      _errors.clear();
      _loginRequired.clear();
      _loading
        ..clear()
        ..addAll(widget.service.rules.map((r) => r.id));
    });
    await Future.wait(
      widget.service.rules.map(
        (rule) => _searchSource(rule.id, query, generation),
      ),
    );
  }

  Future<void> _searchSource(
    String source,
    String query,
    int generation,
  ) async {
    final request = (_sourceRequests[source] ?? 0) + 1;
    _sourceRequests[source] = request;
    bool current() => mounted && generation == _generation && _sourceRequests[source] == request;
    try {
      final results = await widget.service.adapter(source).search(query);
      if (current()) _results[source] = results;
    } on NovelLoginRequired catch (error) {
      if (current()) {
        _errors[source] = error.toString();
        _loginRequired.add(source);
      }
    } catch (error) {
      if (current())
        _errors[source] = error.toString();
    } finally {
      if (current())
        setState(() => _loading.remove(source));
    }
  }

  Future<void> _login(String source) async {
    final owner = ModalRoute.of(context)!;
    final loggedIn = await showNovelAccount(context, widget.service, source,
      submitLabel: '登录并搜索');
    if (loggedIn == true && mounted && owner.isActive) {
      final generation = _generation;
      setState(() {
        _loading.add(source);
        _errors.remove(source);
        _loginRequired.remove(source);
      });
      await _searchSource(source, _submittedQuery, generation);
    }
  }

  Future<void> _bind(NovelBook book) async {
    if (_busy) return;
    final owner = ModalRoute.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = widget.service;
      final rule = service.rule(book.sourceId);
      if (!await NovelConflicts.ensure(context, service, () => [
        if (widget.animeId > 0) 'anime/${widget.animeId}',
        if (widget.existingEditionId != null) ...[
          'edition/${widget.existingEditionId}',
          'selected/${widget.existingEditionId}',
          'source/${widget.existingEditionId}/${book.sourceId}',
        ],
        for (final key in service.state.keys('source'))
          if (
              service.state.revisions(key).any((revision) {
                final candidate = revision.value?['book'] as NovelJson?;
                return candidate?['sourceId'] == book.sourceId &&
                    candidate?['url'] == book.url;
              })) ...[key, 'edition/${key.split('/')[1]}'],
      ])) return;
      if (!mounted || !owner.isActive) return;
      final id = await service.bind(
        animeId: widget.animeId,
        book: book,
        editionLabel: rule.json['edition'] as String,
        language: rule.json['language'] as String,
        existingEditionId:
            widget.existingEditionId ?? service.editionForBook(book),
        existingWorkId: widget.existingWorkId,
      );
      if (mounted && owner.isActive) {
        if (widget.embedded) {
          await widget.onSelected!(id);
        } else {
          Navigator.pop(context, id);
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addUrl() async {
    final owner = ModalRoute.of(context)!;
    final controller = TextEditingController();
    final dialog = DialogRoute<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从公开书籍链接添加'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '书籍详情页 URL',
            hintText: 'https://www.wenku8.net/book/数字.htm',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('读取详情'),
          ),
        ],
      ),
    );
    final url = await Navigator.of(context).push(dialog);
    await dialog.completed;
    controller.dispose();
    if (url == null || !mounted || !owner.isActive) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final book = await widget.service.adapter(_source!).bookFromUrl(url);
      if (mounted && owner.isActive) {
        setState(() => _busy = false);
        await _bind(book);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _manageRules() async {
    final owner = ModalRoute.of(context)!;
    await Navigator.of(context, rootNavigator: true).push<void>(MaterialPageRoute(
      builder: (_) => NovelRulesPage(service: widget.service),
    ));
    if (mounted && owner.isActive) await _prepare();
  }

  @override
  Widget build(BuildContext context) => widget.embedded ? _content() : Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: false,
      title: const Text('小说搜索'),
      actions: [
        IconButton(tooltip: 'AI 关联小说', icon: const Icon(Icons.auto_awesome_outlined),
          onPressed: _busy ? null : () async {
            final title = await chooseAiTitle(context, widget.service, _query.text, toAnime: false);
            if (title == null || !mounted) return;
            _query.text = title;
            await _search();
          }),
        IconButton(
          tooltip: '管理小说规则',
          onPressed: _busy ? null : _manageRules,
          icon: const Icon(Icons.rule_folder_outlined),
        ),
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
    body: _content(),
  );

  Widget _content() => widget.embedded ? _resultList() : Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                controller: _query,
                enabled: !_busy,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  labelText: '书名',
                  suffixIcon: IconButton(
                    tooltip: '搜索',
                    onPressed: _busy ? null : _search,
                    icon: const Icon(Icons.search),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_busy || _updatingRules) const LinearProgressIndicator(),
        Expanded(
          child: _resultList(),
        ),
      ],
  );

  Widget _resultList() => ListView(
            children: [
              if (widget.embedded) ...[
                widget.header!,
                if (_busy || _updatingRules) const LinearProgressIndicator(),
              ],
              if (_rulesError != null)
                ListTile(
                  title: const Text('默认书源更新未完成，已安装书源可继续使用'),
                  subtitle: Text(_rulesError!, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: TextButton(onPressed: _updatingRules ? null : _updateDefaults,
                    child: const Text('重试')),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(children: [
                    SelectableText(_error!),
                    if (_source == null)
                      TextButton(onPressed: _busy ? null : _prepare,
                        child: const Text('重试获取书源')),
                  ]),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: NovelSearchGrid(
                  service: widget.service,
                  books: _results.values.expand((books) => books).toList(),
                  onRead: _busy ? null : _bind,
                ),
              ),
              ExpansionTile(
                title: const Text('书源状态'),
                subtitle: Text(_loading.isNotEmpty
                    ? '${_loading.length} 个书源正在搜索…'
                    : _errors.isNotEmpty
                    ? '${_errors.length} 个书源未完成，展开查看原因'
                    : '搜索完成'),
                children: [for (final rule in widget.service.rules) ...[
                ListTile(
                  dense: true,
                  title: Text(
                    rule.name,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  subtitle: Text(
                    _loading.contains(rule.id)
                        ? '正在搜索…'
                        : _errors[rule.id] ??
                              (_results[rule.id]?.isEmpty == true
                                  ? '没有找到这本小说'
                                  : '${_results[rule.id]?.length ?? 0} 个结果'),
                  ),
                  trailing: _loading.contains(rule.id)
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : _loginRequired.contains(rule.id)
                      ? TextButton(
                          onPressed: () => _login(rule.id),
                          child: const Text('首次登录'),
                        )
                      : PopupMenuButton<String>(
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'retry',
                              child: Text('重新搜索'),
                            ),
                            if (rule.directBookUrlPattern.isNotEmpty)
                              const PopupMenuItem(
                                value: 'url',
                                child: Text('打开书籍链接'),
                              ),
                            if (rule.json['login'] != null)
                              const PopupMenuItem(
                                value: 'login',
                                child: Text('书源账号'),
                              ),
                          ],
                          onSelected: (action) async {
                            if (action == 'login') {
                              await _login(rule.id);
                              return;
                            }
                            if (action == 'url') {
                              _source = rule.id;
                              await _addUrl();
                              return;
                            }
                            setState(() {
                              _loading.add(rule.id);
                              _errors.remove(rule.id);
                            });
                            await _searchSource(
                              rule.id,
                              _submittedQuery,
                              _generation,
                            );
                          },
                        ),
                ),
                const Divider(height: 1),
              ]],
              ),
            ],
  );
}
