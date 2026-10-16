import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'novel_models.dart';

class NovelLocator {
  static String normalize(String text) => text
      .replaceAll(RegExp(r'[\s\u3000\p{P}\p{S}]', unicode: true), '')
      .toLowerCase();

  static int? numberOf(String title) {
    final match = RegExp(r'第?([0-9零〇一二两三四五六七八九十百千]+)[卷章节话回]').firstMatch(title);
    if (match == null) return null;
    return number(match.group(1)!);
  }

  static int number(String text) {
    final digits = int.tryParse(text);
    if (digits != null) return digits;
    const values = {
      '零': 0,
      '〇': 0,
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    const units = {'十': 10, '百': 100, '千': 1000};
    var sum = 0, current = 0;
    for (final c in text.split('')) {
      if (units.containsKey(c)) {
        sum += (current == 0 ? 1 : current) * units[c]!;
        current = 0;
      } else {
        current = current * 10 + values[c]!;
      }
    }
    return sum + current;
  }

  static String kindOf(String title) {
    for (final kind in ['序章', '终章', '后记', '插图', '番外', '间章']) {
      if (title.contains(kind)) return kind;
    }
    return '正文';
  }

  static String volumeKey(String volume) {
    final number = numberOf(volume);
    return number == null ? normalize(volume) : '卷$number';
  }

  static List<NovelChapter> candidates(
    NovelPosition position,
    String sourceId,
    List<NovelChapter> chapters,
  ) {
    if (sourceId == position.sourceId) {
      final exact = chapters
          .where((c) => c.url == position.chapter.url)
          .toList();
      if (exact.isNotEmpty) return exact;
    }
    final old = position.chapter;
    // No positional-index or global-percentage guesses across sources.
    final numbered = chapters
        .where(
          (c) =>
              volumeKey(c.volume) == volumeKey(old.volume) &&
              c.kind == old.kind &&
              c.number == old.number,
        )
        .toList();
    final titled = numbered
        .where((c) => titleKey(c.title) == titleKey(old.title))
        .toList();
    // Translations can rename a chapter without changing its volume/number.
    return titled.isNotEmpty || old.number == null ? titled : numbered;
  }

  static String titleKey(String title) => normalize(
    title.replaceFirst(RegExp(r'^\s*第?[0-9零〇一二两三四五六七八九十百千]+[章节话回]\s*'), ''),
  );
  static String digest(String text) =>
      sha256.convert(utf8.encode(normalize(text))).toString();

  static NovelPosition capture({
    required String editionId,
    required String sourceId,
    required NovelChapter chapter,
    required String text,
    required int offset,
    required int updatedAt,
    String? imageHash,
  }) {
    final normalized = normalize(text);
    final at = offset.clamp(0, normalized.length);
    return NovelPosition(
      editionId: editionId,
      sourceId: sourceId,
      chapter: chapter,
      textOffset: at,
      quote: normalized.substring(at, (at + 32).clamp(0, normalized.length)),
      prefix: normalized.substring((at - 24).clamp(0, normalized.length), at),
      suffix: normalized.substring(
        (at + 32).clamp(0, normalized.length),
        (at + 56).clamp(0, normalized.length),
      ),
      updatedAt: updatedAt,
      chapterDigest: digest(text),
      imageHash: imageHash,
    );
  }

  /// Null means the paragraph is unproven; resume at the matched chapter start.
  static int? locate(NovelPosition position, String text) {
    final normalized = normalize(text);
    if (position.chapterDigest == digest(text)) {
      return position.textOffset;
    }
    if (position.quote.isEmpty) {
      return position.textOffset == 0 && position.prefix.isEmpty ? 0 : null;
    }
    final anchor = position.prefix + position.quote + position.suffix;
    final first = normalized.indexOf(anchor);
    if (first < 0 || normalized.indexOf(anchor, first + 1) >= 0) return null;
    return first + position.prefix.length;
  }
}
