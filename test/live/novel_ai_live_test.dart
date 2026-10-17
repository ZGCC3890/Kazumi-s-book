import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:kazumi/novel/novel_http_session.dart';
import 'package:kazumi/novel/novel_rule.dart';
import 'package:kazumi/novel/novel_ai.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/services/sync/webdav.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('configured AI resolves an anime title into novel title candidates', () async {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    final service = NovelService(WebDav());
    try {
      final names = await service.suggestTitles('辉夜大小姐想让我告白', toAnime: false,
        settings: NovelAiSettings(enabled: true, token: Platform.environment['BOOK_AI_TOKEN']!));
      expect(names, isNotEmpty);
      expect(names.any((name) => name.contains('辉夜')), true);
      stdout.writeln('LIVE AI title candidates: ${names.join(' / ')}');
      if (Platform.environment.containsKey('BOOK_WENKU_PASSWORD')) {
        final directory = await Directory.systemTemp.createTemp('book-ai-source-');
        final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 12), receiveTimeout: const Duration(seconds: 15)));
        final session = NovelHttpSession(() => dio, directory.path);
        final rule = NovelRule.decode(await File('novel_rules/wenku8.json').readAsString());
        try {
          await session.login(rule, Platform.environment['BOOK_WENKU_USER']!, Platform.environment['BOOK_WENKU_PASSWORD']!);
          final adapter = XPathNovelAdapter(rule, (url, method, headers, body) => session.fetch(rule, url, method, headers, body));
          final books = await adapter.search(names.first);
          expect(books.any((book) => book.url.endsWith('/2550.htm')), true);
          stdout.writeln('LIVE AI candidate found the expected Wenku8 book.');
        } finally {
          await session.logout(rule);
          dio.close();
          expect(directory.parent.absolute.path, Directory.systemTemp.absolute.path);
          await directory.delete(recursive: true);
        }
      }
      expect(service.aiSettings.token, isEmpty);
    } finally {
      service.dispose();
      HttpOverrides.global = previous;
    }
  }, skip: !Platform.environment.containsKey('BOOK_AI_TOKEN'));
}
