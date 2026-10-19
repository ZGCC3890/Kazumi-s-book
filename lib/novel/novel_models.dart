typedef NovelJson = Map<String, dynamic>;

/// Identity is confirmed by the reader, never inferred from an anime title.
class NovelWork {
  const NovelWork(this.id, this.title, this.author);
  final String id, title, author;
  NovelJson toJson() => {'id': id, 'title': title, 'author': author};
  factory NovelWork.fromJson(NovelJson j) =>
      NovelWork(j['id'] as String, j['title'] as String, j['author'] as String);
}

class NovelEdition {
  const NovelEdition(this.id, this.workId, this.label, this.language);
  final String id, workId, label, language;
  NovelJson toJson() => {
    'id': id,
    'workId': workId,
    'label': label,
    'language': language,
  };
  factory NovelEdition.fromJson(NovelJson j) => NovelEdition(
    j['id'] as String,
    j['workId'] as String,
    j['label'] as String,
    j['language'] as String,
  );
}

class NovelBook {
  const NovelBook({
    required this.sourceId,
    required this.url,
    required this.title,
    this.author = '',
    this.cover = '',
  });
  final String sourceId, url, title, author, cover;
  NovelJson toJson() => {
    'sourceId': sourceId,
    'url': url,
    'title': title,
    'author': author,
    'cover': cover,
  };
  factory NovelBook.fromJson(NovelJson j) => NovelBook(
    sourceId: j['sourceId'] as String,
    url: j['url'] as String,
    title: j['title'] as String,
    author: j['author'] as String,
    cover: j['cover'] as String,
  );
}

class NovelChapter {
  const NovelChapter({
    required this.url,
    required this.title,
    required this.volume,
    required this.kind,
    this.number,
  });
  final String url, title, volume, kind;
  final int? number;
  NovelJson toJson() => {
    'url': url,
    'title': title,
    'volume': volume,
    'kind': kind,
    'number': number,
  };
  factory NovelChapter.fromJson(NovelJson j) => NovelChapter(
    url: j['url'] as String,
    title: j['title'] as String,
    volume: j['volume'] as String,
    kind: j['kind'] as String,
    number: j['number'] as int?,
  );
}

class NovelBlock {
  const NovelBlock.text(this.value) : image = false;
  const NovelBlock.image(this.value) : image = true;
  final bool image;
  final String value;
  NovelJson toJson() => {'image': image, 'value': value};
  factory NovelBlock.fromJson(NovelJson j) => (j['image'] as bool)
      ? NovelBlock.image(j['value'] as String)
      : NovelBlock.text(j['value'] as String);
}

/// Text offsets refer to normalized chapter text, not rendered pages/pixels.
class NovelPosition {
  const NovelPosition({
    required this.editionId,
    required this.sourceId,
    required this.chapter,
    required this.textOffset,
    required this.quote,
    required this.prefix,
    required this.suffix,
    required this.updatedAt,
    required this.chapterDigest,
    this.imageHash,
    this.imageUrl,
  });
  final String editionId, sourceId, quote, prefix, suffix;
  final NovelChapter chapter;
  final int textOffset, updatedAt;
  final String chapterDigest;
  final String? imageHash;
  final String? imageUrl;
  NovelJson toJson() => {
    'editionId': editionId,
    'sourceId': sourceId,
    'chapter': chapter.toJson(),
    'textOffset': textOffset,
    'quote': quote,
    'prefix': prefix,
    'suffix': suffix,
    'updatedAt': updatedAt,
    'chapterDigest': chapterDigest,
    'imageHash': imageHash,
    'imageUrl': imageUrl,
  };
  factory NovelPosition.fromJson(NovelJson j) => NovelPosition(
    editionId: j['editionId'] as String,
    sourceId: j['sourceId'] as String,
    chapter: NovelChapter.fromJson(j['chapter'] as NovelJson),
    textOffset: j['textOffset'] as int,
    quote: j['quote'] as String,
    prefix: j['prefix'] as String,
    suffix: j['suffix'] as String,
    updatedAt: j['updatedAt'] as int,
    chapterDigest: j['chapterDigest'] as String,
    imageHash: j['imageHash'] as String?,
    imageUrl: j['imageUrl'] as String?,
  );
}
