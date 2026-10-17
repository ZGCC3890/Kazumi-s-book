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

  test('novel editions and paired subtitles use the shared work title', () {
    for (final title in [
      '辉夜大小姐想让我告白～天才们的恋爱头脑战～',
      '辉夜大小姐想让我告白小说版 ～秀知院学园的七大不可思议～',
      '辉夜大小姐想让我告白 小説版 ~秀知院学園七不思議~',
    ]) {
      expect(novelQueryFromAnime(title), '辉夜大小姐想让我告白');
    }
    expect(novelQueryFromAnime('辉夜姬想让人告白 小說版'), '辉夜姬想让人告白');
    expect(novelQueryFromAnime('～'), '～');
    expect(novelQueryFromAnime('小说版'), '小说版');
  });
}
