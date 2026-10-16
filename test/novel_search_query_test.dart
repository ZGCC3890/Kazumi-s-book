import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_search_query.dart';

void main() {
  test('anime sequel suffixes are removed from the initial novel query', () {
    for (final suffix in [
      ' 第二部分',
      ' 第二季',
      ' 第2期',
      ' Part 2',
      ' part.2',
      ' Season 2',
      ' 2nd Season',
      '（第二季）',
      ' Season II Part 2',
    ]) {
      expect(novelQueryFromAnime('测试作品$suffix'), '测试作品', reason: suffix);
    }
  });
  test('numbers and sequel words inside the actual title are preserved', () {
    for (final title in ['86 -不存在的战区-', '第二次的人生', 'Part of Me', '测试作品2']) {
      expect(novelQueryFromAnime(title), title);
    }
  });
}
