import 'package:flutter/painting.dart';
import 'novel_locator.dart';
import 'novel_models.dart';

class NovelFragment {
  const NovelFragment({
    required this.block,
    required this.text,
    required this.offset,
    required this.height,
    required this.image,
  });
  final int block, offset;
  final String text;
  final double height;
  final bool image;
}

/// Both reading modes render the same measured lines and semantic offsets.
class NovelLayout {
  NovelLayout({
    required List<NovelBlock> blocks,
    required TextStyle style,
    required double width,
    required double height,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    var offset = 0;
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      if (block.image) {
        fragments.add(
          NovelFragment(
            block: index,
            text: block.value,
            offset: offset,
            height: height * .88,
            image: true,
          ),
        );
        continue;
      }
      final painter = TextPainter(
        text: TextSpan(text: block.value, style: style),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout(maxWidth: width);
      var y = 0.0;
      for (final line in painter.computeLineMetrics()) {
        final at = painter.getPositionForOffset(Offset(0, y + line.height / 2));
        final range = painter.getLineBoundary(at);
        fragments.add(
          NovelFragment(
            block: index,
            text: block.value.substring(range.start, range.end),
            offset:
                offset +
                NovelLocator.normalize(
                  block.value.substring(0, range.start),
                ).length,
            height: line.height,
            image: false,
          ),
        );
        y += line.height;
      }
      painter.dispose();
      offset += NovelLocator.normalize(block.value).length;
      fragments.add(
        NovelFragment(
          block: index,
          text: '',
          offset: offset,
          height: textScaler.scale(style.fontSize!) * .65,
          image: false,
        ),
      );
    }
    var page = <int>[], used = 0.0;
    for (var i = 0; i < fragments.length; i++) {
      final fragment = fragments[i];
      _tops.add(_tops.last + fragment.height);
      if (page.isNotEmpty && used + fragment.height > height) {
        pages.add(page);
        page = [];
        used = 0;
      }
      page.add(i);
      used += fragment.height;
    }
    if (page.isNotEmpty) pages.add(page);
  }
  final List<NovelFragment> fragments = [];
  final List<List<int>> pages = [];
  final List<double> _tops = [0];

  int fragmentAt(int offset, {int? imageBlock}) {
    if (imageBlock != null) {
      return fragments.indexWhere((f) => f.image && f.block == imageBlock);
    }
    var result = 0;
    for (var i = 0; i < fragments.length; i++) {
      if (fragments[i].offset > offset) break;
      if (!fragments[i].image && fragments[i].text.isNotEmpty) result = i;
    }
    return result;
  }

  int pageOf(int fragment) => pages.indexWhere((p) => p.contains(fragment));
  double pixelsBefore(int fragment) => _tops[fragment];
  int atPixels(double pixels) {
    var low = 0, high = fragments.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (_tops[middle + 1] > pixels) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return low.clamp(0, fragments.length - 1);
  }
}
