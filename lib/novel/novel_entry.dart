import 'package:flutter/material.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'novel_models.dart';
import 'novel_reader_page.dart';
import 'novel_rules_page.dart';
import 'novel_service.dart';

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
        anime.nameCn.isEmpty ? anime.name : anime.nameCn,
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
              const ListTile(title: Text('选择小说版本')),
              for (final edition in service.editions.where(
                (e) => ids.contains(e.id),
              ))
                ListTile(
                  title: Text(service.work(edition.workId).title),
                  subtitle: Text(edition.label),
                  onTap: () => Navigator.pop(ctx, edition.id),
                ),
            ],
          ),
        ),
      );
      if (selected == null || !context.mounted) return;
      id = selected;
    }
    await read(context, service, id);
  }

  static Future<void> read(
    BuildContext context,
    NovelService service,
    String editionId,
  ) async {
    final book = service.selectedBook(editionId);
    if (book == null) throw StateError('小说版本未关联书源');
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            NovelReaderPage(service: service, editionId: editionId, book: book),
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
    if (service.rules.isEmpty) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => NovelRulesPage(service: service)),
      );
    }
    if (!context.mounted || service.rules.isEmpty) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => NovelSearchPage(
          service: service,
          animeId: animeId,
          initialQuery: title,
          existingEditionId: editionId,
          existingWorkId: workId,
        ),
      ),
    );
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
  late String _source;
  List<NovelBook> _results = [];
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _query = TextEditingController(text: widget.initialQuery);
    _source = widget.service.rules.first.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search();
    });
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_query.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _results = [];
    });
    try {
      final results = await widget.service
          .adapter(_source)
          .search(_query.text.trim());
      if (mounted) _results = results;
    } catch (error) {
      if (mounted) _error = error.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bind(NovelBook book) async {
    final service = widget.service;
    var editionId = widget.existingEditionId;
    final label = TextEditingController(
      text: service.rule(_source).json['edition'] as String,
    );
    var language = service.rule(_source).json['language'] as String;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('确认对应小说和版本'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(book.title),
                    subtitle: Text(
                      '${book.author}\n${service.rule(book.sourceId).name}',
                    ),
                  ),
                  if (widget.existingEditionId == null)
                    DropdownButtonFormField<String>(
                      initialValue: editionId ?? 'new',
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: '关联版本'),
                      items: [
                        const DropdownMenuItem(
                          value: 'new',
                          child: Text('新建小说版本'),
                        ),
                        for (final edition in service.editions)
                          DropdownMenuItem(
                            value: edition.id,
                            child: Text(
                              '${service.work(edition.workId).title} · ${edition.label}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) =>
                          update(() => editionId = v == 'new' ? null : v),
                    ),
                  if (editionId != null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '仅当确认是同一译本/文本版本时关联已有版本。不同译文请新建版本。切源后仍需核验章节与文本位置。',
                      ),
                    ),
                  if (editionId == null) ...[
                    TextField(
                      controller: label,
                      decoration: const InputDecoration(labelText: '版本名称'),
                    ),
                    DropdownButton<String>(
                      value: language,
                      items: const [
                        DropdownMenuItem(value: 'zh', child: Text('中文')),
                        DropdownMenuItem(value: 'ja', child: Text('日文')),
                      ],
                      onChanged: (v) => update(() => language = v!),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认并阅读'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      try {
        final id = await service.bind(
          animeId: widget.animeId,
          book: book,
          editionLabel: label.text,
          language: language,
          existingEditionId: editionId,
          existingWorkId: widget.existingWorkId,
        );
        if (mounted) await NovelEntry.read(context, service, id);
      } catch (error) {
        if (mounted) setState(() => _error = error.toString());
      }
    }
    label.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('查找轻小说')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                initialValue: _source,
                decoration: const InputDecoration(labelText: '小说书源'),
                items: [
                  for (final r in widget.service.rules)
                    DropdownMenuItem(value: r.id, child: Text(r.name)),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _source = v!;
                        _results = [];
                      }),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _query,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  labelText: '书名或作者，可修改译名搜索',
                  suffixIcon: IconButton(
                    tooltip: '搜索',
                    onPressed: _busy ? null : _search,
                    icon: const Icon(Icons.search),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text('首次确认作品和版本后，追番卡片上的阅读键会直接续读。'),
            ],
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(_error!),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(_results[i].title),
              subtitle: Text(_results[i].author),
              trailing: const Icon(Icons.menu_book_outlined),
              onTap: () => _bind(_results[i]),
            ),
          ),
        ),
      ],
    ),
  );
}
