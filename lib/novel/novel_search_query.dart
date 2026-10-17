/// Shared work title used for novel queries and anime title/alias comparisons.
String novelQueryFromAnime(String title) {
  final suffix = RegExp(
    r'[\s:：\-–—·]*[\[（(]?(?:第\s*[0-9０-９一二三四五六七八九十百]+\s*(?:季|期|部(?:分)?)|(?:season|part|cour)\s*[.:\-]?\s*(?:[0-9]+|[ivx]+)|[0-9]+(?:st|nd|rd|th)\s+season)[\]）)]?[\s.!！]*$',
    caseSensitive: false,
  );
  var query = novelTitleVariants(title).first;
  while (true) {
    final next = query
        .replaceFirst(suffix, '')
        .replaceFirst(RegExp(r'\s*[～~][^～~]+[～~]\s*$'), '')
        .replaceFirst(RegExp(r'\s*(?:小说版|小説版|小說版)\s*$'), '')
        .trim();
    if (next.isEmpty || next == query) return query;
    query = next;
  }
}

/// Source catalogs can put an alternate full title in trailing parentheses.
/// Short volume/edition notes are not alternate work names.
List<String> novelTitleVariants(String title) {
  final value = title.trim();
  final alias = RegExp(r'^(.{4,}?)[（(]([^()（）]{4,})[）)]$').firstMatch(value);
  return alias == null
      ? [value]
      : [alias.group(1)!.trim(), alias.group(2)!.trim()];
}
