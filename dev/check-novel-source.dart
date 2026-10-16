// Run with: dart --packages=.dart_tool/package_config.json dev/check-novel-source.dart
// <rule-id> <query> <book-url> <chapter-url> [proxy-uri]
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import '../lib/novel/novel_http_session.dart';
import '../lib/novel/novel_rule.dart';

Future<void> main(List<String> args) async {
  final rule = NovelRule.decode(
    await File('novel_rules/${args[0]}.json').readAsString(),
  );
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );
  if (args.length == 5) {
    final proxy = Uri.parse(args[4]);
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () =>
          HttpClient()..findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}',
    );
  }
  final directory = await Directory.systemTemp.createTemp('book-source-check-');
  final session = NovelHttpSession(() => dio, directory.path);
  final adapter = XPathNovelAdapter(
    rule,
    (url, method, headers, body) =>
        session.fetch(rule, url, method, headers, body),
  );
  final books = await adapter.search(args[1]);
  final book = books.singleWhere((b) => b.url == args[2]);
  final detail = await adapter.bookFromUrl(book.url);
  if (detail.title.isEmpty || detail.author.isEmpty)
    throw StateError('Empty detail metadata');
  final chapters = await adapter.catalog(book);
  final chapter = chapters.singleWhere((c) => c.url == args[3]);
  final blocks = await adapter.content(chapter);
  final images = blocks.where((b) => b.image).toList();
  final imageBytes = images.isEmpty
      ? 0
      : (await session.image(rule, images.first.value)).length;
  print(
    '${rule.id}: search=${books.length} chapters=${chapters.length} '
    'text=${blocks.where((b) => !b.image).length} illustrations=${images.length} firstImageBytes=$imageBytes',
  );
  dio.close(force: true);
  await directory.delete(recursive: true);
}
