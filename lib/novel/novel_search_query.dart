/// Only used to derive the initial novel query from an anime title.
String novelQueryFromAnime(String title) {
  final suffix = RegExp(
    r'[\s:：\-–—·]*[\[（(]?(?:第\s*[0-9０-９一二三四五六七八九十百]+\s*(?:季|期|部(?:分)?)|(?:season|part|cour)\s*[.:\-]?\s*(?:[0-9]+|[ivx]+)|[0-9]+(?:st|nd|rd|th)\s+season)[\]）)]?[\s.!！]*$',
    caseSensitive: false,
  );
  var query = title.trim();
  while (true) {
    final next = query.replaceFirst(suffix, '').trim();
    if (next.isEmpty || next == query) return query;
    query = next;
  }
}
