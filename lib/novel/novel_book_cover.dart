import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'novel_models.dart';
import 'novel_service.dart';

class NovelBookCover extends StatefulWidget {
  const NovelBookCover({super.key, required this.service, required this.book});
  final NovelService service;
  final NovelBook? book;
  @override
  State<NovelBookCover> createState() => _NovelBookCoverState();
}

class _NovelBookCoverState extends State<NovelBookCover> {
  Future<Uint8List>? _bytes;
  void _load() {
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
        oldWidget.book?.cover != widget.book?.cover)
      _load();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 44,
    height: 64,
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
                  cacheWidth: 160,
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
