import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'novel_models.dart';
import 'novel_service.dart';
import 'novel_ai_page.dart';

class NovelAnimeLink extends StatefulWidget {
  const NovelAnimeLink({
    super.key,
    required this.service,
    required this.book,
    this.editionId,
    this.showAi = false,
  });
  final NovelService service;
  final NovelBook book;
  final String? editionId;
  final bool showAi;
  @override
  State<NovelAnimeLink> createState() => _NovelAnimeLinkState();
}

class _NovelAnimeLinkState extends State<NovelAnimeLink> {
  late Future<List<BangumiItem>> _matches;
  late String _binding;
  String _bindingKey() =>
      (widget.service
              .animeIdsForBook(widget.book, editionId: widget.editionId)
              .toList()
            ..sort())
          .join(',');
  void _load({bool refresh = false}) {
    _binding = _bindingKey();
    _matches = widget.service.relatedAnime(
      widget.book,
      editionId: widget.editionId,
      refresh: refresh,
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
    widget.service.addListener(_onBindingChanged);
  }

  void _onBindingChanged() {
    if (_binding != _bindingKey()) setState(_load);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onBindingChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant NovelAnimeLink oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      oldWidget.service.removeListener(_onBindingChanged);
      widget.service.addListener(_onBindingChanged);
    }
    if (oldWidget.service != widget.service ||
        oldWidget.book.sourceId != widget.book.sourceId ||
        oldWidget.book.url != widget.book.url ||
        oldWidget.book.title != widget.book.title ||
        oldWidget.editionId != widget.editionId) {
      _load();
    }
  }

  Future<void> _open(List<BangumiItem> matches) async {
    final anime = matches.length == 1
        ? matches.single
        : await showDialog<BangumiItem>(
            context: context,
            builder: (ctx) => SimpleDialog(
              title: const Text('选择番剧'),
              children: [
                for (final item in matches)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, item),
                    child: Text(
                      '${item.nameCn.isEmpty ? item.name : item.nameCn}'
                      '${item.airDate.length >= 4 ? ' · ${item.airDate.substring(0, 4)}' : ''}',
                    ),
                  ),
              ],
            ),
          );
    if (anime != null && mounted) {
      await context.pushNamed('/info/', arguments: anime);
    }
  }

  Future<void> _ai() async {
    final title = await chooseAiTitle(context, widget.service, widget.book.title, toAnime: true);
    if (title == null || !mounted) return;
    try {
      final matches = await widget.service.animeForTitle(title);
      if (!mounted) return;
      if (matches.isEmpty) {
        _message('没有搜索到这个名称的番剧');
        return;
      }
      await _open(matches);
    } catch (error) {
      if (mounted) _message(error.toString());
    }
  }

  void _message(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    if (widget.showAi) IconButton(tooltip: 'AI 关联番剧', icon: const Icon(Icons.auto_awesome_outlined), onPressed: _ai),
    FutureBuilder<List<BangumiItem>>(
    future: _matches,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      }
      if (snapshot.hasError) {
        return IconButton(
          tooltip: '番剧关联查询失败：${snapshot.error}，点击重试',
          icon: const Icon(Icons.error_outline),
          onPressed: () => setState(() => _load(refresh: true)),
        );
      }
      if (snapshot.data!.isEmpty) return const SizedBox.shrink();
      return IconButton(
        tooltip: '查看番剧详情',
        icon: const Icon(Icons.live_tv_outlined),
        onPressed: () => _open(snapshot.data!),
      );
    },
  )]);
}
