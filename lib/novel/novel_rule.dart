import 'dart:convert';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:enough_convert/gbk.dart';
import 'package:json_path/json_path.dart';
import 'package:xpath_selector/xpath_selector.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';
import 'novel_locator.dart';
import 'novel_models.dart';

class NovelResponse {
  const NovelResponse(this.body, this.url);
  final String body, url;
}

typedef NovelFetch =
    Future<NovelResponse> Function(
      String url,
      String method,
      Map<String, String> headers,
      Map<String, String> body,
    );

class NovelLoginRequired implements Exception {
  const NovelLoginRequired();
  @override
  String toString() => '此书源需要登录，请在书源账号中登录并保存本机账号';
}

abstract interface class NovelSourceAdapter {
  Future<List<NovelBook>> search(String keyword);
  Future<NovelBook> bookFromUrl(String url);
  Future<List<NovelChapter>> catalog(NovelBook book);
  Future<List<NovelBlock>> content(NovelChapter chapter);
}

/// Versioned, declarative novel rules. No video-rule or script evaluation.
class NovelRule {
  NovelRule._(this.json);
  final NovelJson json;
  String get id => json['id'] as String;
  String get name => json['name'] as String;
  Uri get website => Uri.parse(json['websiteUrl'] as String? ??
    Uri.parse(headers['Referer'] ?? json['searchUrl'] as String).origin);
  String get directBookUrlPattern => json['directBookUrlPattern'] as String;
  Map<String, String> get headers =>
      Map<String, String>.from(json['headers'] as Map);
  Map<String, String> get imageHeaders => {
    ...headers,
    if (json.containsKey('imageHeaders'))
      ...Map<String, String>.from(json['imageHeaders'] as Map),
  };
  factory NovelRule.decode(String text) {
    final j = jsonDecode(text) as NovelJson;
    if (j['version'] != 1 || j['type'] != 'novel-xpath') {
      throw const FormatException('需要 version=1、type=novel-xpath 的小说规则');
    }
    for (final field in ['id', 'name', 'searchUrl']) {
      if ((j[field] as String).trim().isEmpty) {
        throw FormatException('小说规则缺少 $field');
      }
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(j['id'] as String)) {
      throw const FormatException('书源 id 仅支持字母、数字、下划线和连字符');
    }
    final uri = Uri.parse(j['searchUrl'] as String);
    if (!['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('搜索地址必须是 HTTP(S) URL');
    }
    if (j.containsKey('websiteUrl')) {
      final website = Uri.parse(j['websiteUrl'] as String);
      if (!['http', 'https'].contains(website.scheme) || website.host.isEmpty) {
        throw const FormatException('书源网站地址必须是 HTTP(S) URL');
      }
    }
    if (!['GET', 'POST'].contains(j['searchMethod'])) {
      throw const FormatException('searchMethod 必须是 GET 或 POST');
    }
    if (!['html', 'json'].contains(j['searchFormat'])) {
      throw const FormatException('searchFormat 必须是 html 或 json');
    }
    if (j['searchFormat'] == 'html' &&
        (j['search'] as NovelJson)['itemsMode'] != 'css') {
      throw const FormatException('HTML 搜索 itemsMode 必须是 css');
    }
    Map<String, String>.from(j['headers'] as Map);
    if (j.containsKey('imageHeaders')) {
      Map<String, String>.from(j['imageHeaders'] as Map);
    }
    if (!['utf-8', 'gbk'].contains(j['encoding'])) {
      throw const FormatException('encoding 必须显式指定 utf-8 或 gbk');
    }
    Map<String, String>.from(j['searchBody'] as Map);
    if (j.containsKey('requestEncoding') &&
        !['form', 'json'].contains(j['requestEncoding'])) {
      throw const FormatException('requestEncoding 必须是 form 或 json');
    }
    for (final spec in ['search', 'catalog', 'content']) {
      final fields = j[spec] as NovelJson;
      for (final value in fields.values) {
        value as String;
      }
    }
    for (final field in [
      'items',
      'title',
      'link',
      'linkAttribute',
      'author',
      'cover',
      'coverAttribute',
    ]) {
      (j['search'] as NovelJson)[field] as String;
    }
    for (final field in [
      'mode',
      'nodes',
      'volumeClass',
      'detailToCatalog',
      'title',
      'link',
      'linkAttribute',
      'next',
      'nextAttribute',
    ]) {
      (j['catalog'] as NovelJson)[field] as String;
    }
    for (final field in [
      'root',
      'remove',
      'imageAttribute',
      'next',
      'nextAttribute',
    ]) {
      (j['content'] as NovelJson)[field] as String;
    }
    return NovelRule._(j);
  }
  String encode() => const JsonEncoder.withIndent('  ').convert(json);
}

class XPathNovelAdapter implements NovelSourceAdapter {
  XPathNovelAdapter(this.rule, this.fetch);
  final NovelRule rule;
  final NovelFetch fetch;

  String _text(XPathNode<dom.Node> node, String xpath) => xpath.isEmpty
      ? ''
      : node.queryXPath(xpath).nodes.map((n) => n.text).join(' ').trim();
  String _link(
    XPathNode<dom.Node> node,
    String xpath,
    String attribute,
    String base,
  ) {
    if (xpath.isEmpty) return '';
    final String? value = node.queryXPath(xpath).node?.attributes[attribute];
    if (value == null || value.trim().isEmpty) {
      throw FormatException('规则未提取到链接：$xpath / @$attribute');
    }
    final uri = Uri.parse(base).resolve(value.trim());
    if (!['http', 'https'].contains(uri.scheme)) {
      throw FormatException('书源返回非 HTTP(S) 链接：$uri');
    }
    return uri.toString();
  }

  XPathNode<dom.Node> _root(NovelResponse response) {
    final root = HtmlNodeTree(html.parse(response.body).documentElement!);
    final loginUrl = rule.json['loginRequiredUrlPattern'] as String;
    final login = rule.json['loginRequiredXPath'] as String;
    if ((loginUrl.isNotEmpty && RegExp(loginUrl).hasMatch(response.url)) ||
        (login.isNotEmpty && root.queryXPath(login).nodes.isNotEmpty)) {
      throw const NovelLoginRequired();
    }
    if (rule.json.containsKey('errorXPath')) {
      final message = _text(root, rule.json['errorXPath'] as String);
      if (message.isNotEmpty) throw StateError(message);
    }
    return root;
  }

  NovelBook _detailBook(XPathNode<dom.Node> root, String url) {
    final spec = rule.json['search'] as NovelJson;
    final author = RegExp(
      spec['singleAuthorRegex'] as String,
    ).firstMatch(_text(root, spec['singleAuthor'] as String));
    if (author == null) throw const FormatException('单书详情作者规则未匹配');
    final title = _text(root, spec['singleTitle'] as String);
    if (title.isEmpty) throw const FormatException('单书详情缺少书名');
    return NovelBook(
      sourceId: rule.id,
      url: url,
      title: title,
      author: author.group(1)!,
      cover: _link(root, spec['singleCover'] as String, 'src', url),
    );
  }

  @override
  Future<NovelBook> bookFromUrl(String url) async {
    if (rule.directBookUrlPattern.isEmpty ||
        !RegExp(rule.directBookUrlPattern).hasMatch(url)) {
      throw const FormatException('当前书源不支持这个书籍详情页链接');
    }
    final response = await fetch(url, 'GET', rule.headers, {});
    return _detailBook(_root(response), response.url);
  }

  @override
  Future<List<NovelBook>> search(String keyword) async {
    final spec = rule.json['search'] as NovelJson;
    final encodedKeyword = rule.json['encoding'] == 'gbk'
        ? const GbkCodec(allowInvalid: false)
              .encode(keyword)
              .map((byte) => '%${byte.toRadixString(16).padLeft(2, '0')}')
              .join()
        : Uri.encodeQueryComponent(keyword);
    final url = (rule.json['searchUrl'] as String).replaceAll(
      '@keyword',
      encodedKeyword,
    );
    final body = Map<String, String>.from(
      rule.json['searchBody'] as Map,
    ).map((k, v) => MapEntry(k, v.replaceAll('@keyword', keyword)));
    final response = await fetch(
      url,
      rule.json['searchMethod'] as String,
      rule.headers,
      body,
    );
    if (rule.json['searchFormat'] == 'json') {
      final document = jsonDecode(response.body);
      String read(Object? value, String field) {
        final path = spec[field] as String;
        return path.isEmpty
            ? ''
            : JsonPath(path).readValues(value).single as String;
      }

      return JsonPath(spec['items'] as String).readValues(document).map((node) {
        var value = read(node, 'link');
        if (spec['linkTransform'] == 'lowercase') value = value.toLowerCase();
        return NovelBook(
          sourceId: rule.id,
          title: read(node, 'title'),
          author: read(node, 'author'),
          cover: read(node, 'cover'),
          url: (spec['urlTemplate'] as String).replaceAll('@value', value),
        );
      }).toList();
    }
    final root = _root(response);
    final singleDetect = spec['singleDetect'] as String;
    if (singleDetect.isNotEmpty &&
        root.queryXPath(singleDetect).nodes.isNotEmpty) {
      return [_detailBook(root, response.url)];
    }
    return (root.node as dom.Element)
        .querySelectorAll(spec['items'] as String)
        .map((element) {
          final node = HtmlNodeTree(element);
          final titleAttribute = spec['titleAttribute'] as String;
          final title = titleAttribute.isEmpty
              ? _text(node, spec['title'] as String)
              : node
                    .queryXPath(spec['title'] as String)
                    .node!
                    .attributes[titleAttribute]!;
          if (title.isEmpty) throw const FormatException('书源搜索结果缺少书名');
          var author = _text(node, spec['author'] as String);
          if ((spec['authorRegex'] as String).isNotEmpty) {
            final match = RegExp(
              spec['authorRegex'] as String,
            ).firstMatch(author);
            if (match == null) throw const FormatException('作者提取规则未匹配');
            author = match.group(1)!;
          }
          return NovelBook(
            sourceId: rule.id,
            title: title,
            url: _link(
              node,
              spec['link'] as String,
              spec['linkAttribute'] as String,
              response.url,
            ),
            author: author,
            cover: _link(
              node,
              spec['cover'] as String,
              spec['coverAttribute'] as String,
              response.url,
            ),
          );
        })
        .toList();
  }

  @override
  Future<List<NovelChapter>> catalog(NovelBook book) async {
    final spec = rule.json['catalog'] as NovelJson;
    if (spec['mode'] == 'json-volumes') return _jsonCatalog(book, spec);
    final visited = <String>{}, links = <String>{};
    final chapters = <NovelChapter>[];
    var url = book.url;
    var currentVolume = '';
    final detailLink = spec['detailToCatalog'] as String;
    if (detailLink.isNotEmpty) {
      final detail = await fetch(url, 'GET', rule.headers, {});
      url = _link(_root(detail), detailLink, 'href', detail.url);
    }
    while (url.isNotEmpty) {
      if (!visited.add(url)) throw const FormatException('目录分页形成循环');
      final response = await fetch(url, 'GET', rule.headers, {});
      final root = _root(response);
      if (spec['mode'] != 'sequence-css') {
        throw const FormatException('目录需要声明 sequence-css 有序卷章结构');
      }
      final entries = (root.node as dom.Element).querySelectorAll(
        spec['nodes'] as String,
      );
      for (final element in entries) {
        if (element.classes.contains(spec['volumeClass'] as String)) {
          currentVolume = element.text.trim();
          continue;
        }
        final node = HtmlNodeTree(element);
        final title = _text(node, spec['title'] as String);
        final link = _link(
          node,
          spec['link'] as String,
          spec['linkAttribute'] as String,
          response.url,
        );
        if (title.isEmpty || !links.add(link)) {
          throw FormatException('目录存在空标题或重复章节：$link');
        }
        final volume = currentVolume;
        chapters.add(
          NovelChapter(
            url: link,
            title: title,
            volume: volume,
            kind: NovelLocator.kindOf(title),
            number: NovelLocator.numberOf(title),
          ),
        );
      }
      url = _next(root, spec, response.url);
    }
    if (chapters.isEmpty) throw const FormatException('规则未提取到章节目录');
    return chapters;
  }

  Object? _jsonValue(Object? document, String path) =>
      JsonPath(path).readValues(document).single;

  Map<String, String> _jsonBody(String template, Map<String, String> values) {
    for (final entry in values.entries) {
      template = template.replaceAll('@${entry.key}', entry.value);
    }
    return Map<String, String>.from(jsonDecode(template) as Map);
  }

  Future<Object?> _jsonRequest(
    String url,
    String body,
    Map<String, String> values,
  ) async {
    final response = await fetch(
      url,
      'POST',
      rule.headers,
      _jsonBody(body, values),
    );
    final document = jsonDecode(response.body);
    if (_jsonValue(document, r'$.code') != 0) {
      throw FormatException('书源接口返回错误：${_jsonValue(document, r"$.code")}');
    }
    return document;
  }

  Future<List<NovelChapter>> _jsonCatalog(
    NovelBook book,
    NovelJson spec,
  ) async {
    final match = RegExp(spec['bookIdPattern'] as String).firstMatch(book.url);
    if (match == null) throw const FormatException('书籍链接未匹配目录规则');
    final bookId = match.group(1)!;
    final volumes = <Object?>[];
    var page = 1;
    while (true) {
      final document = await _jsonRequest(
        spec['volumesUrl'] as String,
        spec['volumesBody'] as String,
        {'book': bookId, 'page': '$page'},
      );
      final batch = JsonPath(
        spec['itemsPath'] as String,
      ).readValues(document).toList();
      volumes.addAll(batch);
      final next = _jsonValue(document, spec['hasNextPath'] as String);
      if (next == 0) break;
      if (next != 1 || batch.isEmpty) throw const FormatException('卷目录分页数据无效');
      page++;
    }
    final result = <NovelChapter>[];
    final volumeIds = <String>{}, links = <String>{};
    for (final volume in volumes) {
      final id = _jsonValue(volume, spec['volumeIdPath'] as String).toString();
      if (!volumeIds.add(id)) throw const FormatException('卷目录分页返回重复卷');
      final title =
          _jsonValue(volume, spec['volumeTitlePath'] as String) as String;
      page = 1;
      var count = 0;
      while (true) {
        final document = await _jsonRequest(
          spec['chaptersUrl'] as String,
          spec['chaptersBody'] as String,
          {'book': bookId, 'volume': id, 'page': '$page'},
        );
        final batch = JsonPath(
          spec['itemsPath'] as String,
        ).readValues(document).toList();
        for (final item in batch) {
          final chapterId = _jsonValue(
            item,
            spec['chapterIdPath'] as String,
          ).toString();
          final chapterTitle =
              _jsonValue(item, spec['chapterTitlePath'] as String) as String;
          final url = (spec['chapterUrl'] as String)
              .replaceAll('@book', bookId)
              .replaceAll('@chapter', chapterId);
          if (chapterTitle.isEmpty || !links.add(url))
            throw const FormatException('章节标题为空或目录分页重复');
          result.add(
            NovelChapter(
              url: url,
              title: chapterTitle,
              volume: title,
              kind: NovelLocator.kindOf(chapterTitle),
              number: NovelLocator.numberOf(chapterTitle),
            ),
          );
          count++;
        }
        final next = _jsonValue(document, spec['hasNextPath'] as String);
        if (next == 0) break;
        if (next != 1 || batch.isEmpty)
          throw const FormatException('章节目录分页数据无效');
        page++;
      }
      if (count != _jsonValue(volume, spec['volumeCountPath'] as String)) {
        throw const FormatException('章节数量与书源声明不一致，未取得完整目录');
      }
    }
    if (result.isEmpty) throw const FormatException('规则未提取到章节目录');
    return result;
  }

  String _next(XPathNode<dom.Node> root, NovelJson spec, String url) {
    final xpath = spec['next'] as String;
    if (xpath.isEmpty || root.queryXPath(xpath).nodes.isEmpty) return '';
    return _link(root, xpath, spec['nextAttribute'] as String, url);
  }

  @override
  Future<List<NovelBlock>> content(NovelChapter chapter) async {
    final spec = rule.json['content'] as NovelJson;
    final blocks = <NovelBlock>[], visited = <String>{};
    var url = chapter.url;
    while (url.isNotEmpty) {
      if (!visited.add(url)) throw const FormatException('正文分页形成循环');
      final NovelResponse response;
      if (spec['format'] == 'json-html') {
        final match = RegExp(
          spec['chapterIdPattern'] as String,
        ).firstMatch(url);
        if (match == null) throw const FormatException('章节链接未匹配正文规则');
        final document = await _jsonRequest(
          spec['url'] as String,
          spec['body'] as String,
          {'book': match.group(1)!, 'chapter': match.group(2)!},
        );
        final locked = _jsonValue(document, spec['lockedPath'] as String);
        if (locked == 1) throw StateError('此章节需要书源访问权限，无法匿名阅读，请选择其他公开章节或书源');
        if (locked != 0) throw const FormatException('书源未返回明确的章节访问状态');
        response = NovelResponse(
          _jsonValue(document, spec['htmlPath'] as String) as String,
          url,
        );
      } else {
        response = await fetch(url, 'GET', rule.headers, {});
      }
      final root = _root(response);
      final remove = spec['remove'] as String;
      if (remove.isNotEmpty) {
        for (final node in root.queryXPath(remove).nodes) {
          node.node.remove();
        }
      }
      for (final node in root.queryXPath(spec['root'] as String).nodes) {
        final buffer = StringBuffer();
        void flush() {
          final text = buffer.toString().trim();
          if (text.isNotEmpty) blocks.add(NovelBlock.text(text));
          buffer.clear();
        }

        void walk(dom.Node node) {
          if (node is dom.Text) {
            buffer.write(node.text);
            return;
          }
          if (node is! dom.Element) return;
          if (['script', 'style', 'noscript'].contains(node.localName)) return;
          if (node.localName == 'img') {
            flush();
            final value = node.attributes[spec['imageAttribute'] as String];
            if (value == null || value.isEmpty) {
              throw const FormatException('插图缺少规则指定的图片属性');
            }
            blocks.add(
              NovelBlock.image(
                Uri.parse(response.url).resolve(value).toString(),
              ),
            );
            return;
          }
          final boundary = [
            'p',
            'div',
            'br',
            'h1',
            'h2',
            'h3',
            'li',
          ].contains(node.localName);
          if (boundary) flush();
          for (final child in node.nodes) {
            walk(child);
          }
          if (boundary) flush();
        }

        walk(node.node);
        flush();
      }
      url = _next(root, spec, response.url);
    }
    if (blocks.isEmpty) throw const FormatException('规则未提取到正文');
    return blocks;
  }
}
