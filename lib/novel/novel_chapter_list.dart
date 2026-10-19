import 'package:flutter/material.dart';
import 'novel_models.dart';

/// A centered sliver starts at the current chapter without estimating row heights.
class NovelChapterList extends StatefulWidget {
  const NovelChapterList({
    super.key,
    required this.chapters,
    required this.current,
    required this.onSelected,
  });
  final List<NovelChapter> chapters;
  final NovelChapter current;
  final ValueChanged<NovelChapter> onSelected;

  @override
  State<NovelChapterList> createState() => _NovelChapterListState();
}

class _NovelChapterListState extends State<NovelChapterList> {
  final _center = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final current = widget.chapters.indexWhere(
      (chapter) => chapter.url == widget.current.url,
    );
    // A chapter-mapping chooser may contain no current chapter.
    final start = current < 0 ? 0 : current;
    Widget row(int index) => ListTile(
      title: Text(widget.chapters[index].title),
      subtitle: Text(widget.chapters[index].volume),
      selected: index == current,
      onTap: () => widget.onSelected(widget.chapters[index]),
    );
    return CustomScrollView(
      center: _center,
      slivers: [
        SliverList.builder(
          itemCount: start,
          itemBuilder: (_, index) => row(start - index - 1),
        ),
        SliverList.builder(
          key: _center,
          itemCount: widget.chapters.length - start,
          itemBuilder: (_, index) => row(start + index),
        ),
      ],
    );
  }
}
