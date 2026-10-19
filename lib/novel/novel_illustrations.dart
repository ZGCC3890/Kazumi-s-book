import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'novel_image_viewer.dart';
import 'novel_models.dart';

/// An explicit illustration chapter in the current contiguous catalog volume.
/// Body references such as “（插图006）” do not participate in this gallery.
class NovelIllustrations extends ChangeNotifier {
  NovelIllustrations(this.readChapter, this.readImage);
  final Future<List<NovelBlock>> Function(NovelChapter, bool refresh) readChapter;
  final Future<Uint8List> Function(String) readImage;
  static final _title = RegExp(
    r'^(?:插图|插圖|插画|插畫|彩页|彩頁|イラスト|挿絵)(?:[0-9一二三四五六七八九十]+)?$',
  );
  List<NovelChapter> _chapters = [];
  final Map<String, Future<Uint8List>> _images = {};
  List<String> urls = [];
  Object? error;
  bool busy = false, loaded = false, _open = false;
  int _generation = 0, _groupStart = -1;
  bool get available => _chapters.isNotEmpty;
  bool get visible => _open && available;

  void select(List<NovelChapter> catalog, int current, {bool refresh = false}) {
    final volume = catalog[current].volume;
    var first = current, last = current;
    while (first > 0 && catalog[first - 1].volume == volume) { first--; }
    while (last + 1 < catalog.length && catalog[last + 1].volume == volume) { last++; }
    final chapters = catalog.sublist(first, last + 1).where((chapter) =>
      _title.hasMatch(chapter.title.replaceAll(RegExp(r'\s'), ''))).toList();
    if (!refresh && first == _groupStart && listEquals(
        chapters.map((c) => c.url).toList(), _chapters.map((c) => c.url).toList())) { return; }
    _generation++;
    _groupStart = first;
    _chapters = chapters;
    _images.clear();
    urls = [];
    error = null;
    busy = loaded = false;
    if (visible) { unawaited(load(refresh: refresh)); }
    else { notifyListeners(); }
  }

  void toggle() {
    _open = !_open;
    if (visible && !loaded && !busy) { unawaited(load()); }
    else { notifyListeners(); }
  }

  Future<void> load({bool refresh = false}) async {
    final generation = ++_generation;
    busy = true;
    error = null;
    notifyListeners();
    try {
      final result = <String>[];
      for (final chapter in _chapters) {
        final blocks = await readChapter(chapter, refresh);
        if (generation != _generation) return;
        result.addAll(blocks.where((block) => block.image).map((block) => block.value));
      }
      urls = result;
      loaded = true;
    } catch (failure) {
      if (generation != _generation) return;
      error = failure;
    }
    busy = false;
    notifyListeners();
  }

  Future<Uint8List> image(String url) => _images.putIfAbsent(url, () => readImage(url));
  void retryImage(String url) { _images.remove(url); notifyListeners(); }

  @override
  void dispose() { _generation++; super.dispose(); }
}

class NovelIllustrationToggle extends StatelessWidget {
  const NovelIllustrationToggle({super.key, required this.gallery, this.enabled = true});
  final NovelIllustrations gallery;
  final bool enabled;
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: gallery,
    builder: (_, _) => gallery.available ? IconButton(
      tooltip: gallery.visible ? '隐藏插图栏' : '显示插图栏',
      isSelected: gallery.visible,
      onPressed: enabled ? gallery.toggle : null,
      icon: const Icon(Icons.photo_library_outlined),
      selectedIcon: const Icon(Icons.photo_library),
    ) : const SizedBox.shrink(),
  );
}

class NovelIllustrationBar extends StatelessWidget {
  const NovelIllustrationBar({super.key, required this.gallery});
  final NovelIllustrations gallery;

  Widget _failure(Object error, VoidCallback retry) => Tooltip(
    message: error.toString(), child: TextButton.icon(
      onPressed: retry, icon: const Icon(Icons.broken_image_outlined),
      label: const Text('加载失败，重试', style: TextStyle(fontSize: 12)),
    ),
  );

  Widget _thumbnail(BuildContext context, int index) {
    final url = gallery.urls[index];
    return SizedBox(width: 112, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: FutureBuilder<Uint8List>(future: gallery.image(url), builder: (context, snapshot) {
        if (snapshot.hasError) return _failure(snapshot.error!, () => gallery.retryImage(url));
        if (!snapshot.hasData) return const SizedBox.expand();
        return Semantics(label: '本卷插图 ${index + 1}，点击放大', button: true,
          child: InkWell(onTap: () => showNovelImage(context, snapshot.data!), child: Image.memory(
            snapshot.data!, fit: BoxFit.contain,
            cacheWidth: (112 * MediaQuery.devicePixelRatioOf(context)).round(),
            errorBuilder: (_, error, _) => _failure(error, () => gallery.retryImage(url)),
          )),
        );
      })),
      ExcludeSemantics(child: Text('${index + 1}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 12))),
    ]));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: gallery, builder: (_, _) {
    if (!gallery.visible) return const SizedBox.shrink();
    return Material(color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.only(left: 16), child: Row(children: [
          Expanded(child: Text('本卷插图', maxLines: 1, overflow: TextOverflow.ellipsis)),
          IconButton(tooltip: '收起插图栏', onPressed: gallery.toggle, icon: const Icon(Icons.close)),
        ])),
        SizedBox(height: 88 + MediaQuery.textScalerOf(context).scale(12), child:
          gallery.busy ? const Center(child: CircularProgressIndicator()) :
          gallery.error != null ? Row(children: [
            Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('插图章加载失败：${gallery.error}', maxLines: 2, overflow: TextOverflow.ellipsis))),
            TextButton(onPressed: () => gallery.load(refresh: true), child: const Text('重试插图章')),
          ]) : gallery.urls.isEmpty ? const Center(child: Text('插图章未包含图片')) :
          Semantics(identifier: 'novel-illustration-strip', child: ListView.separated(
            key: const ValueKey('novel-illustration-strip'),
            scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: gallery.urls.length, separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) => _thumbnail(context, index),
          )),
        ),
        const SizedBox(height: 8),
      ]),
    );
  });
}
