import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'novel_models.dart';
import 'novel_rule.dart';
import 'novel_reader_page.dart';
import 'novel_service.dart';
import 'novel_search_query.dart';

class NovelEntry {
  static Future<void> conflicts(
    BuildContext context,
    NovelService service,
  ) async {
    while (service.state.conflicts.isNotEmpty && context.mounted) {
      if (!context.mounted) return;
      final key = service.state.conflicts.first;
      final revisions = service.state.revisions(key);
      final chosen = await showDialog<int>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('选择要保留的阅读数据'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(key),
                  const Text('两台设备独立修改了同一记录。选择后会同步你的决定。'),
                  for (var i = 0; i < revisions.length; i++)
                    ListTile(
                      title: Text(
                        revisions[i].value == null
                            ? '删除这条记录'
                            : key.startsWith('position/')
                            ? '${(revisions[i].value!['chapter'] as NovelJson)['volume']} '
                                  '${(revisions[i].value!['chapter'] as NovelJson)['title']}'
                            : revisions[i].value.toString(),
                      ),
                      subtitle: Text(
                        revisions[i].value?['quote'] as String? ??
                            revisions[i].clock.keys.join(' / '),
                      ),
                      onTap: () => Navigator.pop(ctx, i),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('稍后决定'),
            ),
          ],
        ),
      );
      if (chosen == null) return;
      await service.resolve(key, revisions[chosen]);
    }
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
    await conflicts(context, service);
    if (!context.mounted || service.state.conflicts.isNotEmpty) return;
    final ids = service.boundEditions(anime.id);
    if (ids.isEmpty) {
      await search(
        context,
        service,
        anime.id,
        novelQueryFromAnime(anime.nameCn.isEmpty ? anime.name : anime.nameCn),
      );
      return;
    }
    var id = ids.first;
    if (ids.length > 1) {
      final selected = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('选择小说')),
              for (final edition in service.editions.where(
                (e) => ids.contains(e.id),
              ))
                ListTile(
                  title: Text(service.work(edition.workId).title),
                  subtitle: Text(service.work(edition.workId).author),
                  onTap: () => Navigator.pop(ctx, edition.id),
                ),
            ],
          ),
        ),
      );
      if (selected == null || !context.mounted) return;
      id = selected;
    }
    if (!context.mounted) return;
    await search(
      context,
      service,
      anime.id,
      novelQueryFromAnime(anime.nameCn.isEmpty ? anime.name : anime.nameCn),
      editionId: id,
    );
  }

  static Future<void> read(
    BuildContext context,
    NovelService service,
    String editionId, {
    int animeId = 0,
  }) async {
    final book = service.selectedBook(editionId);
    if (book == null) throw StateError('这本小说尚未选择书源');
    await service.ensureDefaultRules();
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (readerContext) => NovelReaderPage(
          service: service,
          editionId: editionId,
          book: book,
          onLeave: (chapters) async {
            if (chapters.isEmpty) return;
            final count = await service.recordReadChapters(editionId, chapters);
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
                content: Text(
                  targetAnimeId > 0
                      ? '已读过一章以上。加入书架后，关联番剧也会加入追番并标记为“在看”。'
                      : '已读过一章以上，加入书架方便下次继续阅读。',
                ),
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
            if (targetAnimeId > 0) {
              final anime = await BangumiApi.getBangumiInfoByID(targetAnimeId);
              if (anime == null) throw StateError('无法获取关联番剧，尚未加入书架，请重试');
              final collect = inject<CollectController>();
              await collect.addCollect(anime, type: CollectType.watching.value);
              if (collect.getCollectType(anime) != CollectType.watching.value) {
                throw StateError('番剧“在看”状态未保存，尚未加入书架，请重试');
              }
            }
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
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 640,
          height: MediaQuery.sizeOf(context).height * .7,
          child: NovelSearchPage(
            service: service,
            animeId: animeId,
            initialQuery: title,
            existingEditionId: editionId,
            existingWorkId: workId,
          ),
        ),
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
  });
  final NovelService service;
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
  final Set<String> _loading = {}, _loginRequired = {};
  int _generation = 0;
  String _submittedQuery = '';
  bool _busy = false;
  String? _error;
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
      await service.ensureDefaultRules();
      if (!mounted) return;
      if (service.rules.isEmpty) throw StateError('没有已启用的小说书源，请在书架的小说规则中添加');
      final preferred = service.preferredSource;
      setState(() {
        _source = service.rules.any((r) => r.id == preferred)
            ? preferred
            : service.rules.first.id;
        _busy = false;
      });
      await _search();
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _busy = false;
        });
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
    try {
      final results = await widget.service.adapter(source).search(query);
      if (mounted && generation == _generation) _results[source] = results;
    } on NovelLoginRequired catch (error) {
      if (mounted && generation == _generation) {
        _errors[source] = error.toString();
        _loginRequired.add(source);
      }
    } catch (error) {
      if (mounted && generation == _generation)
        _errors[source] = error.toString();
    } finally {
      if (mounted && generation == _generation)
        setState(() => _loading.remove(source));
    }
  }

  Future<void> _login(String source) async {
    final username = TextEditingController();
    final password = TextEditingController();
    var busy = false;
    String? error;
    final dialog = DialogRoute<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text('登录${widget.service.rule(source).name}'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('只需首次登录；会话保存在本机，账号密码不上传至规则仓库或云同步。会话过期后才需要重新登录。'),
                TextField(
                  controller: username,
                  enabled: !busy,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: '书源用户名'),
                ),
                TextField(
                  controller: password,
                  enabled: !busy,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: '密码'),
                ),
                if (busy) const LinearProgressIndicator(),
                if (error != null) Text(error!),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      update(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await widget.service.login(
                          source,
                          username.text.trim(),
                          password.text,
                        );
                        password.clear();
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (failure) {
                        if (ctx.mounted)
                          update(() {
                            busy = false;
                            error = failure.toString();
                          });
                      }
                    },
              child: const Text('登录并搜索'),
            ),
          ],
        ),
      ),
    );
    final loggedIn = await Navigator.of(context).push(dialog);
    await dialog.completed;
    password.clear();
    username.dispose();
    password.dispose();
    if (loggedIn == true && mounted) {
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
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = widget.service;
      final rule = service.rule(book.sourceId);
      final id = await service.bind(
        animeId: widget.animeId,
        book: book,
        editionLabel: rule.json['edition'] as String,
        language: rule.json['language'] as String,
        existingEditionId:
            widget.existingEditionId ?? service.editionForBook(book),
        existingWorkId: widget.existingWorkId,
      );
      if (mounted) Navigator.pop(context, id);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addUrl() async {
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
    if (url == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final book = await widget.service.adapter(_source!).bookFromUrl(url);
      if (mounted) {
        setState(() => _busy = false);
        await _bind(book);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: false,
      title: const Text('选择小说书源'),
      actions: [
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                controller: _query,
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
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                SelectableText(_error!),
                if (_source == null)
                  TextButton(
                    onPressed: _busy ? null : _prepare,
                    child: const Text('重试获取书源'),
                  ),
              ],
            ),
          ),
        Expanded(
          child: ListView(
            children: [
              for (final rule in widget.service.rules) ...[
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
                for (final book in _results[rule.id] ?? <NovelBook>[])
                  ListTile(
                    title: Text(book.title),
                    subtitle: Text(book.author),
                    trailing: const Icon(Icons.menu_book_outlined),
                    onTap: _busy ? null : () => _bind(book),
                  ),
                const Divider(height: 1),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
