import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_http_session.dart';
import 'package:kazumi/novel/novel_rule.dart';

void main() {
  test('authenticated Wenku8 login, immediate search, catalog and content', () async {
    final directory = await Directory.systemTemp.createTemp('kazumi-wenku8-test-');
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20)));
    final session = NovelHttpSession(() => dio, directory.path);
    final rule = NovelRule.decode(await File('novel_rules/wenku8.json').readAsString());
    try {
      await session.login(rule, Platform.environment['BOOK_WENKU_USER']!,
        Platform.environment['BOOK_WENKU_PASSWORD']!);
      final adapter = XPathNovelAdapter(rule,
        (url, method, headers, body) => session.fetch(rule, url, method, headers, body));
      final books = await adapter.search('辉夜');
      expect(books.length, greaterThanOrEqualTo(5));
      final book = books.singleWhere((book) => book.url.endsWith('/2550.htm'));
      expect(book.title, '辉夜姬想让人告白(辉夜大小姐想让我告白)');
      expect(book.author, isNotEmpty);
      expect(book.cover, isNotEmpty);
      final chapters = await adapter.catalog(book);
      expect(chapters, isNotEmpty);
      final blocks = await adapter.content(chapters.first);
      expect(blocks, isNotEmpty);
    } finally {
      await session.logout(rule);
      dio.close(force: true);
      expect(directory.absolute.path, startsWith(Directory.systemTemp.absolute.path));
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.environment.containsKey('BOOK_WENKU_PASSWORD'),
    timeout: const Timeout(Duration(seconds: 75)));
}
