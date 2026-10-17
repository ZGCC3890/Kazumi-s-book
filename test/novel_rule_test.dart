import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/novel/novel_models.dart';
import '../lib/novel/novel_locator.dart';
import '../lib/novel/novel_rule.dart';

NovelRule _rule(String id) => NovelRule.decode(File('novel_rules/$id.json').readAsStringSync());
const _chapter = NovelChapter(url: 'https://initial.test/chapter',
    title: '第一章', volume: '第一卷', kind: 'chapter', number: 1);

void main() {
  test('owned English chapter titles retain nullable catalog numbers', () {
    for (final title in ['Chapter 1', 'Chapter 2', 'Chapter 3']) {
      expect(NovelLocator.numberOf(title), isNull);
    }
    expect(NovelLocator.numberOf('第3章'), 3);
  });

  test('wenku8 cards use full tiptitle, author and GBK query encoding', () async {
    String? requested;
    final adapter = XPathNovelAdapter(_rule('wenku8'), (url, method, headers, body) async {
      requested = url;
      expect(method, 'GET');
      expect(headers['Referer'], 'https://www.wenku8.net/');
      return const NovelResponse('''<div style="width:373px;height:136px"><div><a><img src="/cover.jpg"></a></div>
        <div><b><a href="/book/42.htm" tiptitle="完整的轻小说标题">完整的…</a></b>
        <p>作者:测试作者/分类:连载</p></div></div>''', 'https://mirror.test/results');
    });
    final books = await adapter.search('中文');
    expect(requested, contains('searchkey=%d6%d0%ce%c4'));
    expect(books, hasLength(1));
    expect(books.single.title, '完整的轻小说标题');
    expect(books.single.author, '测试作者');
    expect(books.single.url, 'https://mirror.test/book/42.htm');
    expect(books.single.cover, 'https://mirror.test/cover.jpg');
  });

  test('wenku8 single-result redirect returns the actual detail URL', () async {
    final adapter = XPathNovelAdapter(_rule('wenku8'), (url, method, headers, body) async =>
      const NovelResponse('''<span style="font-weight: bold"><b>唯一小说</b><a href="/uservote.php">投票</a></span>
      <table><tr><td>小说作者：某作者</td></tr></table>
      <img vspace="0" src="../cover.jpg"><a href="/novel/42/index.htm">小说目录</a>''',
      'https://mirror.test/book/42.htm'));
    final book = (await adapter.search('唯一小说')).single;
    expect(book.url, 'https://mirror.test/book/42.htm');
    expect(book.title, '唯一小说');
    expect(book.author, '某作者');
    expect(book.cover, 'https://mirror.test/cover.jpg');
  });

  test('wenku8 explicit public book URL extracts metadata despite the header login form', () async {
    final adapter = XPathNovelAdapter(_rule('wenku8'), (url, method, headers, body) async =>
      const NovelResponse('''<header><input type="password"></header>
        <span style="font-weight: bold"><b>公开书籍</b></span>
        <table><tr><td>小说作者：公开作者</td></tr></table><img vspace="0" src="/cover.jpg">''',
        'https://www.wenku8.net/book/4343.htm'));
    final book = await adapter.bookFromUrl('https://www.wenku8.net/book/4343.htm');
    expect(book.title, '公开书籍');
    expect(book.author, '公开作者');
    expect(book.url, 'https://www.wenku8.net/book/4343.htm');
    expect(book.cover, 'https://www.wenku8.net/cover.jpg');
  });

  test('wenku8 explicit book URL reports a real login redirect even without a password field', () async {
    final adapter = XPathNovelAdapter(_rule('wenku8'), (url, method, headers, body) async =>
      const NovelResponse('<h1>需要登录</h1>', 'http://www.wenku8.net/login.php?jumpurl=book'));
    await expectLater(adapter.bookFromUrl('https://www.wenku8.net/book/4343.htm'),
      throwsA(isA<NovelLoginRequired>()));
  });

  test('wenku8 detail-to-catalog follows final URL and nearest preceding volume', () async {
    final requests = <String>[];
    final adapter = XPathNovelAdapter(_rule('wenku8'), (url, method, headers, body) async {
      requests.add(url);
      if (requests.length == 1) {
        return const NovelResponse('<a href="../novel/42/index.htm">小说目录</a>',
          'https://mirror.test/book/42.htm');
      }
      return const NovelResponse('''<table>
      <tr><td class="vcss">第一卷</td></tr>
      <tr><td class="ccss"><a href="1.htm">第一章 开始</a></td><td class="ccss">&nbsp;</td></tr>
      <tr><td class="vcss">第二卷</td></tr>
      <tr><td class="ccss"><a href="2.htm">第一章 继续</a></td></tr></table>''',
        'https://cdn.test/novel/42/index.htm');
    });
    final chapters = await adapter.catalog(const NovelBook(sourceId: 'wenku8',
      url: 'https://initial.test/book/42.htm', title: '书'));
    expect(requests.last, 'https://mirror.test/novel/42/index.htm');
    expect(chapters.map((c) => c.volume), ['第一卷', '第二卷']);
    expect(chapters.map((c) => c.number), [1, 1]);
    expect(chapters.first.url, 'https://cdn.test/novel/42/1.htm');
  });

  test('wenku8 public detail remains readable when its header includes a login form', () async {
    var requests = 0;
    final adapter = XPathNovelAdapter(_rule('wenku8'), (url, method, headers, body) async {
      requests++;
      if (requests == 1) {
        return const NovelResponse('''<header><form action="/login.php">
          <input name="username"><input type="password" name="password"></form></header>
          <a href="/novel/4/4343/index.htm">小说目录</a>''',
          'https://www.wenku8.net/book/4343.htm');
      }
      return const NovelResponse('''<table><tr><td class="vcss">第一卷</td></tr>
        <tr><td class="ccss"><a href="177990.htm">序章</a></td></tr></table>''',
        'https://www.wenku8.net/novel/4/4343/index.htm');
    });
    final chapters = await adapter.catalog(const NovelBook(sourceId: 'wenku8',
      url: 'https://www.wenku8.net/book/4343.htm', title: '公开详情测试'));
    expect(requests, 2);
    expect(chapters.single.url, 'https://www.wenku8.net/novel/4/4343/177990.htm');
    expect(chapters.single.title, '序章');
  });

  test('wenku8 content retains text and image source order across br boundaries', () async {
    final adapter = XPathNovelAdapter(_rule('wenku8'), (url, method, headers, body) async =>
      const NovelResponse('''<div id="content">第一段<br>第二段<img src="../art/1.jpg">
        第三段<br><img src="/art/2.jpg"><script>unwanted</script>结尾</div>''',
        'https://cdn.test/novel/42/1.htm'));
    final blocks = await adapter.content(_chapter);
    expect(blocks.map((b) => b.image), [false, false, true, false, true, false]);
    expect(blocks.map((b) => b.value), ['第一段', '第二段',
      'https://cdn.test/novel/art/1.jpg', '第三段', 'https://cdn.test/art/2.jpg', '结尾']);
  });

  test('wenku8 login page is an explicit error rather than zero search results', () async {
    final adapter = XPathNovelAdapter(_rule('wenku8'), (url, method, headers, body) async =>
      const NovelResponse('<form><input type="password"></form>', 'https://www.wenku8.net/login.php'));
    await expectLater(adapter.search('书'), throwsA(isA<NovelLoginRequired>()));
  });

  test('syosetu API metadata row is skipped and ncode becomes lowercase URL', () async {
    final adapter = XPathNovelAdapter(_rule('syosetu'), (url, method, headers, body) async =>
      const NovelResponse('[{"allcount":1},{"title":"日本語の小説","ncode":"N1234AB","writer":"作家"}]',
        'https://api.syosetu.com/novelapi/api/'));
    final books = await adapter.search('小説');
    expect(books, hasLength(1));
    expect(books.single.title, '日本語の小説');
    expect(books.single.author, '作家');
    expect(books.single.url, 'https://ncode.syosetu.com/n1234ab/');
  });

  test('syosetu ruby keeps base text, removes reading text and preserves illustrations', () async {
    final adapter = XPathNovelAdapter(_rule('syosetu'), (url, method, headers, body) async =>
      const NovelResponse('''<div class="p-novel__text js-novel-text">
        <p><ruby>漢字<rp>（</rp><rt>かんじ</rt><rp>）</rp></ruby>を読む。</p>
        <p><img src="/image/1.png"></p><p>次の段落。</p></div>''',
        'https://ncode.syosetu.com/n1234ab/1/'));
    final blocks = await adapter.content(_chapter);
    expect(blocks.map((b) => b.value), ['漢字を読む。',
      'https://ncode.syosetu.com/image/1.png', '次の段落。']);
    expect(blocks.map((b) => b.image), [false, true, false]);
  });

  test('syosetu paginated catalog inherits the volume across page boundaries', () async {
    final requests = <String>[];
    final adapter = XPathNovelAdapter(_rule('syosetu'), (url, method, headers, body) async {
      requests.add(url);
      if (requests.length == 1) {
        return const NovelResponse('''<div><div class="p-eplist__chapter-title">第一部</div>
          <div class="p-eplist__sublist"><a class="p-eplist__subtitle" href="1/">第一話</a></div></div>
          <a class="c-pager__item--next" href="?p=2">次へ</a>''',
          'https://ncode.syosetu.com/n1234ab/');
      }
      return const NovelResponse('''<div>
        <div class="p-eplist__sublist"><a class="p-eplist__subtitle" href="2/">第二話</a></div>
        <div class="p-eplist__chapter-title">第二部</div>
        <div class="p-eplist__sublist"><a class="p-eplist__subtitle" href="3/">第三話</a></div></div>''',
        'https://ncode.syosetu.com/n1234ab/?p=2');
    });
    final chapters = await adapter.catalog(const NovelBook(sourceId: 'syosetu',
      url: 'https://ncode.syosetu.com/n1234ab/', title: '小説'));
    expect(requests.last, 'https://ncode.syosetu.com/n1234ab/?p=2');
    expect(chapters.map((c) => c.volume), ['第一部', '第一部', '第二部']);
    expect(chapters.map((c) => c.url), ['https://ncode.syosetu.com/n1234ab/1/',
      'https://ncode.syosetu.com/n1234ab/2/', 'https://ncode.syosetu.com/n1234ab/3/']);
  });
}
