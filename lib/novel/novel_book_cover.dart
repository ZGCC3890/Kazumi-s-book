import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'novel_models.dart';
import 'novel_service.dart';

class NovelBookCover extends StatefulWidget {
  const NovelBookCover({super.key, required this.service, required this.book,
    this.width = 44, this.height = 64});
  final NovelService service;
  final NovelBook? book;
  final double width, height;
  @override
  State<NovelBookCover> createState() => _NovelBookCoverState();
}

class _NovelBookCoverState extends State<NovelBookCover> {
  Future<Uint8List>? _bytes;
  String? _sourceRule;
  String? get _currentRule => widget.service.rules
      .where((rule) => rule.id == widget.book?.sourceId).firstOrNull?.encode();
  void _load() {
    _sourceRule = _currentRule;
    final book = widget.book;
    _bytes = book == null || book.cover.isEmpty
        ? null
        : widget.service.image(book.sourceId, book.cover);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant NovelBookCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service ||
        oldWidget.book?.sourceId != widget.book?.sourceId ||
        oldWidget.book?.cover != widget.book?.cover ||
        _sourceRule != _currentRule)
      _load();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    height: widget.height,
    child: _bytes == null
        ? const Icon(Icons.menu_book_outlined)
        : ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: FutureBuilder<Uint8List>(
              future: _bytes,
              builder: (context, snapshot) {
                if (snapshot.hasError)
                  return Tooltip(
                    message: '封面加载失败：${snapshot.error}',
                    child: const Icon(Icons.broken_image_outlined),
                  );
                if (!snapshot.hasData)
                  return const Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                return Image.memory(
                  snapshot.data!,
                  fit: BoxFit.cover,
                  cacheWidth: (widget.width * MediaQuery.devicePixelRatioOf(context)).round(),
                  semanticLabel: '${widget.book!.title}封面',
                  errorBuilder: (context, error, stack) => Tooltip(
                    message: '封面解码失败：$error',
                    child: const Icon(Icons.broken_image_outlined),
                  ),
                );
              },
            ),
          ),
  );
}
