import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_models.dart';
import 'package:kazumi/novel/novel_rule.dart';

NovelRule _rule(String id) =>
    NovelRule.decode(File('novel_rules/$id.json').readAsStringSync());
const _book = NovelBook(
  sourceId: 'lightnovel',
  url: 'https://www.lightnovel.fun/book/168',
  title: '测试小说',
);
const _chapter = NovelChapter(
  url: 'https://www.lightnovel.fun/reader/168/1',
  title: '第一章',
  volume: '正文',
  kind: '正文',
);

void main() {
  test(
    'JSON source reads every volume and chapter page and rejects incomplete catalogs',
    () async {
      final requests = <String>[];
      var incomplete = false;
      final adapter = XPathNovelAdapter(_rule('lightnovel'), (
        url,
        method,
        headers,
        body,
      ) async {
        expect(method, 'POST');
        final page = int.parse(body['page']!);
        final volumes = url.endsWith('get-book-volumes');
        requests.add('${volumes ? 'volume' : body['volume_id']}/$page');
        final list = volumes
            ? [
                {
                  'volume_id': page,
                  'title': '第$page卷',
                  'chapter_count': incomplete ? 3 : 2,
                },
              ]
            : [
                {'chapter_id': '${body['volume_id']}$page', 'title': '第$page章'},
              ];
        return NovelResponse(
          jsonEncode({
            'code': 0,
            'data': {
              'list': list,
              'page_info': {'has_next': page == 1 ? 1 : 0},
            },
          }),
          url,
        );
      });
      final chapters = await adapter.catalog(_book);
      expect(chapters, hasLength(4));
      expect(chapters.map((c) => c.volume), ['第1卷', '第1卷', '第2卷', '第2卷']);
      expect(requests, ['volume/1', 'volume/2', '1/1', '1/2', '2/1', '2/2']);
      incomplete = true;
      await expectLater(adapter.catalog(_book), throwsFormatException);
    },
  );
  test(
    'JSON source preserves illustration position and reports restricted chapters',
    () async {
      var locked = 0;
      final adapter = XPathNovelAdapter(
        _rule('lightnovel'),
        (url, method, headers, body) async => NovelResponse(
          jsonEncode({
            'code': 0,
            'data': {
              'locked': locked,
              'render_preview': locked == 1
                  ? []
                  : {
                      'body_html':
                          '<p>前文</p><p><img src="/pic.jpg"></p><p>后文</p>',
                    },
            },
          }),
          url,
        ),
      );
      final blocks = await adapter.content(_chapter);
      expect(blocks.map((b) => b.image), [false, true, false]);
      expect(blocks[1].value, 'https://www.lightnovel.fun/pic.jpg');
      locked = 1;
      await expectLater(
        adapter.content(_chapter),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('访问权限'),
          ),
        ),
      );
    },
  );
  test(
    'linovel real DOM structure keeps volumes and illustration order',
    () async {
      final adapter = XPathNovelAdapter(_rule('linovel'), (
        url,
        method,
        headers,
        body,
      ) async {
        if (url.contains('/search/'))
          return NovelResponse('''<a class="search-book" href="/book/42.html">
        <div class="book-name">原创小说</div><div class="book-extra">作者甲 丨 奇幻</div>
        <div class="book-cover"><img src="/cover.jpg"></div></a>''', url);
        if (url.endsWith('/book/42.html'))
          return NovelResponse('''<h2 class="volume-title">第一卷</h2>
        <div class="chapter"><a href="/book/42/1.html">第一章</a></div>''', url);
        return NovelResponse(
          '''<div class="article-text"><p>前文</p><p><a href="/pic.png"><img src="/pic.png"></a></p><p>后文</p></div>''',
          url,
        );
      });
      final book = (await adapter.search('原创')).single;
      expect(book.author, '作者甲');
      final chapter = (await adapter.catalog(book)).single;
      expect(chapter.volume, '第一卷');
      final blocks = await adapter.content(chapter);
      expect(blocks.map((b) => b.image), [false, true, false]);
      expect(blocks[1].value, 'https://www.linovel.net/pic.png');
    },
  );
}
