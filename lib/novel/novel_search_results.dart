import 'package:flutter/material.dart';
import 'package:kazumi/pages/info/watch_entry.dart';
import 'novel_anime_link.dart';
import 'novel_book_cover.dart';
import 'novel_cover_grid.dart';
import 'novel_models.dart';
import 'novel_service.dart';

class NovelSearchGrid extends StatelessWidget {
  const NovelSearchGrid({super.key, required this.service, required this.books,
    required this.onRead});
  final NovelService service;
  final List<NovelBook> books;
  final ValueChanged<NovelBook>? onRead;

  @override
  Widget build(BuildContext context) => NovelCoverGrid(
      itemCount: books.length,
      actionHeight: MediaQuery.textScalerOf(context).scale(12) * 1.4 + 100,
      itemBuilder: (context, index, width) {
        final book = books[index];
        void read() => onRead!(book);
        return Semantics(
          identifier: 'novel-search-result-$index',
          child: Material(
          key: ValueKey('novel-result-${book.sourceId}-${book.url}'),
          color: Colors.transparent,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            onTap: onRead == null ? null : read,
            borderRadius: BorderRadius.circular(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DecoratedBox(
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(8)),
                child: NovelBookCover(service: service, book: book,
                  width: width, height: width * 1.45),
              ),
              const SizedBox(height: 8),
              Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall),
            ]),
          ),
          const Spacer(),
          Text(service.rule(book.sourceId).name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 12, height: 1.4)),
          Semantics(identifier: 'novel-read-${book.sourceId}-$index',
            child: SizedBox(height: 48, child: TextButton.icon(
            onPressed: onRead == null ? null : read,
            icon: const Icon(Icons.menu_book_outlined), label: const Text('阅读')))),
          SizedBox(height: 48, child: NovelAnimeLink(service: service, book: book,
            showAi: true, lazy: true,
            onOpen: (anime) => WatchEntry.open(context, anime))),
          ]),
        ));
      },
    );
}
