import 'package:flutter/material.dart';
import 'novel_anime_link.dart';
import 'novel_book_cover.dart';
import 'novel_cover_grid.dart';
import 'novel_locator.dart';
import 'novel_models.dart';
import 'novel_search_query.dart';
import 'novel_service.dart';

/// Presentation grouping only. Choosing a source still binds its own edition.
class NovelSearchResult {
  NovelSearchResult(NovelBook book) : books = [book];
  final List<NovelBook> books;
  NovelBook get book => books.first;

  static List<NovelSearchResult> group(Iterable<NovelBook> books) {
    final results = <NovelSearchResult>[];
    Set<String> keys(NovelBook book) => novelTitleVariants(book.title)
        .map((title) => NovelLocator.normalize(novelQueryFromAnime(title)))
        .toSet();
    for (final book in books) {
      final titleKeys = keys(book);
      final matching = results.where((result) => result.books.any(
        (other) => keys(other).intersection(titleKeys).isNotEmpty)).toList();
      if (matching.isEmpty) {
        results.add(NovelSearchResult(book));
      } else {
        final target = matching.first;
        for (final merged in matching.skip(1)) {
          target.books.addAll(merged.books);
          results.remove(merged);
        }
        if (!target.books.any((other) => other.sourceId == book.sourceId && other.url == book.url)) {
          target.books.add(book);
        }
      }
    }
    return results;
  }
}

class NovelSearchGrid extends StatelessWidget {
  const NovelSearchGrid({super.key, required this.service, required this.results,
    required this.onOpen});
  final NovelService service;
  final List<NovelSearchResult> results;
  final ValueChanged<NovelSearchResult>? onOpen;

  @override
  Widget build(BuildContext context) => NovelCoverGrid(
      itemCount: results.length,
      itemBuilder: (context, index, width) {
        final result = results[index];
        return Semantics(
          identifier: 'novel-search-result-$index',
          child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('novel-result-${result.book.sourceId}-${result.book.url}'),
            onTap: onOpen == null ? null : () => onOpen!(result),
            borderRadius: BorderRadius.circular(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DecoratedBox(
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(8)),
                child: NovelBookCover(service: service, book: result.book,
                  width: width, height: width * 1.45),
              ),
              const SizedBox(height: 8),
              Text(result.book.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall),
            ]),
          ),
        ));
      },
    );
}

class NovelSearchDetailPage extends StatefulWidget {
  const NovelSearchDetailPage({super.key, required this.service, required this.result});
  final NovelService service;
  final NovelSearchResult result;

  @override
  State<NovelSearchDetailPage> createState() => _NovelSearchDetailPageState();
}

class _NovelSearchDetailPageState extends State<NovelSearchDetailPage> {
  bool _choosing = false;

  @override
  Widget build(BuildContext context) {
    final book = widget.result.book;
    return Scaffold(
      appBar: AppBar(title: const Text('小说详情')),
      body: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Center(child: NovelBookCover(service: widget.service, book: book, width: 150, height: 218)),
          const SizedBox(height: 16),
          Text(book.title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
          if (book.author.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 8),
              child: Text(book.author, textAlign: TextAlign.center)),
          Center(child: NovelAnimeLink(service: widget.service, book: book, showAi: true)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => setState(() => _choosing = !_choosing),
            icon: const Icon(Icons.menu_book_outlined),
            label: Text(_choosing ? '收起书源' : '选择书源阅读'),
          ),
          if (_choosing)
            for (final sourceBook in widget.result.books)
              ListTile(
                key: ValueKey('novel-source-${sourceBook.sourceId}-${sourceBook.url}'),
                title: Text(widget.service.rules.singleWhere((rule) => rule.id == sourceBook.sourceId).name),
                subtitle: Text([sourceBook.title, sourceBook.author].where((text) => text.isNotEmpty).join('\n')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pop(sourceBook),
              ),
        ]),
      )),
    );
  }
}
