import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'novel_layout.dart';
import 'novel_locator.dart';
import 'novel_models.dart';
import 'novel_reader_store.dart';
import 'novel_conflicts.dart';
import 'novel_illustrations.dart';
import 'novel_chapter_list.dart';
import 'novel_reader_toolbar.dart';
import 'novel_reader_image.dart';
import 'novel_reader_window.dart';
import 'package:kazumi/utils/device.dart';
import 'package:window_manager/window_manager.dart';

class NovelReaderPage extends StatefulWidget {
  const NovelReaderPage({
    super.key,
    required this.service,
    required this.editionId,
    required this.book,
    this.onLeave,
    this.onChangeSource,
    this.shelfAction,
    this.registerSave,
  });
  final NovelReaderStore service;
  final String editionId;
  final NovelBook book;
  final Future<void> Function(Set<String> chapters)? onLeave;
  final Future<NovelBook?> Function(BuildContext context, NovelBook book)? onChangeSource;
  final Widget? shelfAction;
  final void Function(Future<bool> Function()? save)? registerSave;
  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelReaderPageState extends State<NovelReaderPage>
    with WidgetsBindingObserver {
  NovelReaderStore get service => widget.service;
  late NovelBook _book;
  List<NovelChapter> _chapters = [];
  List<NovelBlock> _blocks = [];
  final Map<int, Future<Uint8List>> _images = {};
  final Set<int> _failedImages = {};
  NovelPosition? _pendingImageRestore;
  Object? _imageRestoreError;
  NovelLayout? _layout;
  String? _layoutKey, _error;
  String? _saveError;
  late NovelJson _prefs;
  NovelPosition? _location, _savedLocation;
  int _chapterIndex = 0, _fragment = 0, _generation = 0, _restoreRevision = 0;
  bool _busy = true, _chrome = false, _restoring = true, _leaving = false;
  bool _exitPending = false;
  bool _changingSource = false;
  final Set<String> _readChapters = {};
  bool _initialSavePending = false,
      _orientationChanged = false,
      _startAtEnd = false;
  Timer? _saveTimer;
  ScrollController? _scroll;
  PageController? _pages;
  int? _restoreImageBlock;
  late String _normalizedText, _chapterDigest, _serviceStatus;
  final Map<int, String> _imageHashes = {};
  late NovelIllustrations _illustrations;
  final _window = NovelReaderWindow();
  String get _text => _blocks.where((b) => !b.image).map((b) => b.value).join();
  // The former standalone night preset now uses paper white in app light mode.
  int get _dayTheme => _prefs['theme'] == 3 ? 0 : _prefs['theme'] as int;

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    _prefs = service.preferences;
    _illustrations = _createIllustrations();
    _serviceStatus = _status;
    WidgetsBinding.instance.addObserver(this);
    service.addListener(_serviceChanged);
    widget.registerSave?.call(_save);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(_open());
  }

  NovelIllustrations _createIllustrations() => NovelIllustrations(
    (chapter, refresh) => service.content(_book.sourceId, chapter, refresh: refresh),
    (url) => service.image(_book.sourceId, url),
  );

  String get _status => '${service.state.revisions('position/${widget.editionId}').length > 1}/${service.syncError}';
  void _serviceChanged() {
    if (_serviceStatus == _status) return;
    _serviceStatus = _status;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    widget.registerSave?.call(null);
    _window.dispose();
    service.removeListener(_serviceChanged);
    WidgetsBinding.instance.removeObserver(this);
    _scroll?.dispose();
    _pages?.dispose();
    _illustrations.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(_save());
    }
  }

  Future<void> _open({bool refresh = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _chapters = await service.catalog(_book, refresh: refresh);
      if (NovelConflicts.has(service.state, 'position/${widget.editionId}')) {
        _fail(StateError('阅读进度有冲突，请选择要继续的进度。'));
        return;
      }
      final position = service.position(widget.editionId);
      if (!mounted) return;
      if (position == null) {
        await _load(0, refresh: refresh);
        return;
      }
      await _restoreChapter(position, refresh: refresh);
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _restoreChapter(
    NovelPosition position, {
    bool refresh = false,
  }) async {
    if (!await NovelConflicts.ensure(context, service,
        () => [service.chapterMappingKey(position, _book)])) {
      _fail(StateError('章节对应尚未选择，原进度已保留。'));
      return;
    }
    final mapped = service.mappedChapter(position, _book);
    final currentMapping = mapped == null
        ? <NovelChapter>[]
        : _chapters.where((chapter) => chapter.url == mapped.url).toList();
    final candidates = mapped == null
        ? NovelLocator.candidates(position, _book.sourceId, _chapters)
        : currentMapping;
    final needsConfirmation = candidates.length != 1;
    final chapter = needsConfirmation
        ? await _chooseChapter(
            candidates.isEmpty ? _chapters : candidates,
            title: mapped != null && currentMapping.isEmpty
                ? '先前确认的章节已从目录移除，请重新选择'
                : '无法唯一对应原进度，请选择章节',
          )
        : candidates.single;
    if (chapter == null) {
      _fail(StateError('尚未确认章节，已保留原阅读进度'));
      return;
    }
    await _load(
      _chapters.indexOf(chapter),
      restore: position,
      confirmMapping: needsConfirmation,
      refresh: refresh,
    );
  }

  void _fail(Object error) {
    if (mounted)
      setState(() {
        _error = error.toString();
        _busy = false;
        _chrome = true;
      });
  }

  Future<void> _load(
    int index, {
    NovelPosition? restore,
    bool refresh = false,
    bool startAtEnd = false,
    bool confirmMapping = false,
  }) async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _restoring = true;
      _error = null;
    });
    try {
      final chapter = _chapters[index];
      final blocks = await service.content(
        _book.sourceId,
        chapter,
        refresh: refresh,
      );
      if (!mounted || generation != _generation) return;
      _startAtEnd = startAtEnd;
      _initialSavePending = true;
      _blocks = blocks;
      _normalizedText = NovelLocator.normalize(_text);
      _chapterDigest = NovelLocator.digest(_text);
      _imageHashes.clear();
      _images.clear();
      _failedImages.clear();
      _pendingImageRestore = null;
      _imageRestoreError = null;
      _chapterIndex = index;
      _illustrations.select(_chapters, index, refresh: refresh);
      _restoreImageBlock = null;
      var fresh = restore == null;
      var offset = 0;
      var proven = restore == null;
      if (restore != null) {
        final found = NovelLocator.locate(restore, _text);
        if (restore.imageHash == null && restore.imageUrl == null) {
          proven = found != null;
        } else {
          final sameChapter =
              restore.sourceId == _book.sourceId &&
              restore.chapter.url == chapter.url;
          final image = sameChapter
              ? blocks.indexWhere(
                  (block) => block.image && block.value == restore.imageUrl,
                )
              : -1;
          proven =
              image >= 0 && found != null && _textBeforeImage(image) == found;
          if (proven) {
            _restoreImageBlock = image;
          } else if (restore.imageHash != null) {
            _pendingImageRestore = restore;
          }
        }
        if (proven) offset = found!;
        if (!proven) fresh = true;
      }
      if (!mounted || generation != _generation) return;
      if (confirmMapping) {
        if (!await NovelConflicts.ensure(
          context,
          service,
          () => service.chapterMappingWriteKeys(restore!, _book, chapter),
        )) {
          _fail(StateError('章节对应尚未选择，原进度已保留。'));
          return;
        }
        await service.confirmChapterMapping(restore!, _book, chapter);
      }
      if (!mounted || generation != _generation) return;
      if (fresh) _restoreImageBlock = blocks.first.image ? 0 : null;
      _location =
          _pendingImageRestore ??
          NovelLocator.capture(
            editionId: widget.editionId,
            sourceId: _book.sourceId,
            bookUrl: _book.url,
            chapter: chapter,
            text: _text,
            offset: offset,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            imageHash: proven ? restore?.imageHash : null,
            imageUrl: _restoreImageBlock == null
                ? null
                : blocks[_restoreImageBlock!].value,
          );
      // Preserve the saved bookmark until its image evidence is resolved or the user moves.
      if (_pendingImageRestore != null) _savedLocation = _location;
      final readIdentity = await service.chapterReadIdentity(
        widget.editionId,
        _book,
        chapter,
        restore,
      );
      if (!mounted || generation != _generation) return;
      _readChapters.add(readIdentity);
      setState(() {
        _busy = false;
        _layoutKey = null;
      });
      if (_pendingImageRestore != null) {
        unawaited(_restoreIllustration(_pendingImageRestore!, generation));
      } else if (restore != null && !proven) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已定位到对应章节，从本章开头继续阅读')));
      }
    } catch (error) {
      if (generation == _generation) _fail(error);
    }
  }

  void _moved(int fragment, {bool force = false}) {
    if (_restoring || _layout == null || fragment < 0) return;
    if (!force && fragment == _fragment) return;
    _pendingImageRestore = null;
    if (_imageRestoreError != null) setState(() => _imageRestoreError = null);
    _fragment = fragment;
    final f = _layout!.fragments[fragment];
    _restoreImageBlock = f.image ? f.block : null;
    _location = NovelLocator.capturePrepared(
      editionId: widget.editionId,
      sourceId: _book.sourceId,
      bookUrl: _book.url,
      chapter: _chapters[_chapterIndex],
      normalized: _normalizedText,
      chapterDigest: _chapterDigest,
      offset: f.offset,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      imageHash: f.image ? _imageHashes[f.block] : null,
      imageUrl: f.image ? _blocks[f.block].value : null,
    );
    _saveTimer ??= Timer(const Duration(milliseconds: 600), () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  Future<bool> _save() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final position = _location;
    if (position == null) return true;
    if (service.state.revisions('position/${widget.editionId}').length > 1)
      return false;
    // A remote revision may arrive while this viewport stays unchanged.
    // Leaving must not publish this reader's already-saved old position again.
    if (identical(position, _savedLocation)) return true;
    if (_restoring) return false;
    try {
      await service.savePosition(position);
      _savedLocation = position;
      if (mounted && _saveError != null) setState(() => _saveError = null);
      return true;
    } catch (error) {
      if (mounted) setState(() => _saveError = error.toString());
      return false;
    }
  }

  Future<void> _leave() async {
    if (_leaving || _exitPending) return;
    _exitPending = true;
    try {
      var leaveWithoutWriting = false;
      if (service.state.revisions('position/${widget.editionId}').length > 1) {
        leaveWithoutWriting = _location == null || identical(_location, _savedLocation);
        if (!leaveWithoutWriting) {
          final discard = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('阅读进度有冲突'),
              content: const Text('当前页面的新位置尚未保存。退出会放弃这一位置，保留所有已有冲突候选。'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('返回阅读')),
                TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('放弃未保存位置并退出')),
              ],
            ),
          );
          if (discard != true || !mounted) return;
          leaveWithoutWriting = true;
        }
      }
      if (!leaveWithoutWriting && !await _save()) return;
      await widget.onLeave?.call(Set.unmodifiable(_readChapters));
      if (_window.used) await _window.restore();
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (_orientationChanged) await SystemChrome.setPreferredOrientations([]);
      if (mounted) setState(() => _leaving = true);
      // Restore the shell's insets before the reverse route transition exposes it.
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      _exitPending = false;
    }
  }

  Future<void> _refresh() async {
    if (await _save()) await _open(refresh: true);
  }

  Future<void> _changeSource() async {
    setState(() => _changingSource = true);
    try {
      if (!await _save() || !mounted) return;
      final book = await widget.onChangeSource!(context, _book);
      if (book == null || !mounted) return;
      _generation++;
      _illustrations.dispose();
      setState(() {
        _book = book;
        _illustrations = _createIllustrations();
      });
      await _open();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _changingSource = false);
    }
  }

  Future<void> _resolvePosition({bool reopen = false}) async {
    final key = 'position/${widget.editionId}';
    if (!await NovelConflicts.choose(context, service, key) || !mounted ||
        NovelConflicts.has(service.state, key)) return;
    _location = service.position(widget.editionId);
    _savedLocation = _location;
    if (reopen && mounted) await _open();
  }

  void _setOrientation(List<DeviceOrientation> orientations) {
    _orientationChanged = true;
    SystemChrome.setPreferredOrientations(orientations);
  }

  Future<NovelChapter?> _chooseChapter(
    List<NovelChapter> chapters, {
    String title = '目录',
  }) => showModalBottomSheet<NovelChapter>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height * .8,
        child: Column(
          children: [
            ListTile(title: Text(title)),
            Expanded(
              child: NovelChapterList(
                chapters: chapters,
                current: _chapters[_chapterIndex],
                onSelected: (chapter) => Navigator.pop(ctx, chapter),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Future<void> _catalog() async {
    final selected = await _chooseChapter(_chapters);
    if (selected == null) return;
    if (await _save()) await _load(_chapters.indexOf(selected));
  }

  Future<void> _chapter(int delta) async {
    final next = _chapterIndex + delta;
    if (next < 0 || next >= _chapters.length || _busy) return;
    if (await _save()) await _load(next, startAtEnd: delta < 0);
  }

  Future<void> _progress() async {
    final layout = _layout!;
    final paged = _prefs['mode'] == 'page';
    var chapter = _chapterIndex.toDouble();
    var fraction = paged
        ? (layout.pages.length == 1
              ? 0.0
              : _pages!.page! / (layout.pages.length - 1))
        : (_scroll!.position.maxScrollExtent == 0
              ? 0.0
              : _scroll!.offset / _scroll!.position.maxScrollExtent);
    final selected = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('阅读进度'),
                Text('本章 ${(fraction * 100).round()}%'),
                Slider(
                  key: const ValueKey('novel-chapter-progress'),
                  value: fraction.clamp(0, 1),
                  onChanged: (value) => update(() => fraction = value),
                  onChangeEnd: (value) {
                    if (paged) {
                      _pages!.jumpToPage(
                        (value * (layout.pages.length - 1)).round(),
                      );
                    } else {
                      _scroll!.jumpTo(
                        value * _scroll!.position.maxScrollExtent,
                      );
                    }
                  },
                ),
                Text(
                  '${_chapters[chapter.round()].volume} ${_chapters[chapter.round()].title}',
                ),
                if (_chapters.length > 1)
                  Slider(
                    key: const ValueKey('novel-book-progress'),
                    value: chapter,
                    max: (_chapters.length - 1).toDouble(),
                    divisions: _chapters.length - 1,
                    label: '${chapter.round() + 1}/${_chapters.length}',
                    onChanged: (value) => update(() => chapter = value),
                  ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, chapter.round()),
                  child: const Text('前往章节'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null && selected != _chapterIndex && await _save()) {
      await _load(selected);
    }
  }

  void _turn(int direction) {
    if (_prefs['mode'] == 'scroll') {
      final scroll = _scroll!;
      final next =
          scroll.offset + direction * scroll.position.viewportDimension * .9;
      if (scroll.offset >= scroll.position.maxScrollExtent && direction > 0) {
        unawaited(_chapter(1));
      } else if (scroll.offset <= 0 && direction < 0) {
        unawaited(_chapter(-1));
      } else {
        unawaited(
          scroll.animateTo(
            next.clamp(0, scroll.position.maxScrollExtent),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          ),
        );
      }
    } else {
      final page = _pages!.page!.round() + direction;
      if (page < 0) {
        unawaited(_chapter(-1));
      } else if (page >= _layout!.pages.length) {
        unawaited(_chapter(1));
      } else {
        unawaited(
          _pages!.animateToPage(
            page,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          ),
        );
      }
    }
  }

  Future<void> _bookmark() async {
    if (_location == null) return;
    final controller = TextEditingController();
    final dialog = DialogRoute<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加书签'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '备注（可留空）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final note = await Navigator.of(context).push(dialog);
    await dialog.completed;
    controller.dispose();
    if (note != null) await service.addBookmark(_location!, note);
  }

  Future<void> _bookmarks() async {
    final selected = await showModalBottomSheet<NovelPosition>(
      context: context,
      builder: (ctx) => ListenableBuilder(
        listenable: service,
        builder: (_, _) {
          final marks = service.bookmarks(widget.editionId);
          final conflicts = NovelConflicts.bookmarkKeys(service.state, widget.editionId);
          return SafeArea(
            child: ListView(
              children: [
                const ListTile(title: Text('我的书签')),
                if (marks.isEmpty && conflicts.isEmpty) const ListTile(title: Text('还没有书签')),
                for (final key in conflicts)
                  NovelConflictTile(store: service, recordKey: key),
                for (final mark in marks)
                  ListTile(
                    title: Text(
                      (mark['note'] as String).isEmpty
                          ? (mark['position'] as NovelJson)['chapter']['title']
                                as String
                          : mark['note'] as String,
                    ),
                    subtitle: Text(
                      (mark['position'] as NovelJson)['quote'] as String,
                    ),
                    trailing: IconButton(
                      tooltip: '删除书签',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _bookmarkAction(() async {
                        final id = mark['id'] as String;
                        if (await NovelConflicts.ensure(ctx, service, () => ['bookmark/$id'])) {
                          await service.deleteBookmark(id);
                        }
                      }),
                    ),
                    onTap: () => _bookmarkAction(() async {
                      final id = mark['id'] as String;
                      if (!await NovelConflicts.ensure(ctx, service, () => ['bookmark/$id']) || !ctx.mounted) return;
                      final current = service.bookmarks(widget.editionId)
                          .where((value) => value['id'] == id).firstOrNull;
                      if (current != null) Navigator.pop(ctx,
                          NovelPosition.fromJson(current['position'] as NovelJson));
                    }),
                  ),
              ],
            ),
          );
        },
      ),
    );
    if (selected == null) return;
    if (await _save()) {
      try {
        await _restoreChapter(selected);
      } catch (error) {
        _fail(error);
      }
    }
  }

  Future<void> _bookmarkAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _settings() async {
    if (!await _save()) return;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          void change(String key, Object value) {
            update(() => _prefs[key] = value);
            setState(() {
              _prefs[key] = value;
              if (const {'fontSize', 'lineHeight', 'margin', 'font', 'mode'}
                  .contains(key)) {
                _layoutKey = null;
              }
            });
            unawaited(service.savePreferences(_prefs));
          }

          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('阅读设置', style: TextStyle(fontSize: 20)),
                    Text('字号 ${(_prefs['fontSize'] as num).round()}'),
                    Slider(
                      value: (_prefs['fontSize'] as num).toDouble(),
                      min: 14,
                      max: 36,
                      divisions: 22,
                      onChanged: (v) => change('fontSize', v),
                    ),
                    const Text('行距'),
                    Slider(
                      value: (_prefs['lineHeight'] as num).toDouble(),
                      min: 1.2,
                      max: 2.6,
                      divisions: 14,
                      onChanged: (v) => change('lineHeight', v),
                    ),
                    const Text('页边距'),
                    Slider(
                      value: (_prefs['margin'] as num).toDouble(),
                      min: 12,
                      max: 56,
                      divisions: 11,
                      onChanged: (v) => change('margin', v),
                    ),
                    const Text('日间纸色（深色模式下随应用配色）'),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (var i = 0; i < 3; i++)
                          ChoiceChip(
                            label: Text(['纸白', '护眼', '羊皮纸'][i]),
                            selected: _dayTheme == i,
                            onSelected: (_) => change('theme', i),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'scroll', label: Text('滚动')),
                        ButtonSegment(value: 'page', label: Text('左右翻页')),
                      ],
                      selected: {_prefs['mode'] as String},
                      onSelectionChanged: (v) => change('mode', v.single),
                    ),
                    DropdownButton<String>(
                      value: _prefs['font'] as String,
                      isExpanded: true,
                      items: const [
                        DropdownMenuItem(value: 'system', child: Text('系统字体')),
                        DropdownMenuItem(value: 'serif', child: Text('衬线字体')),
                      ],
                      onChanged: (v) => change('font', v!),
                    ),
                    const Text('阅读亮度（当前阅读页）'),
                    Slider(
                      value: (_prefs['brightness'] as num).toDouble(),
                      min: 0,
                      max: .7,
                      onChanged: (v) => change('brightness', v),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () =>
                              _setOrientation([DeviceOrientation.portraitUp]),
                          child: const Text('竖屏'),
                        ),
                        TextButton(
                          onPressed: () => _setOrientation([
                            DeviceOrientation.landscapeLeft,
                            DeviceOrientation.landscapeRight,
                          ]),
                          child: const Text('横屏'),
                        ),
                        TextButton(
                          onPressed: () =>
                              SystemChrome.setPreferredOrientations([]),
                          child: const Text('跟随系统'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  int _textBeforeImage(int index) => NovelLocator.normalize(
    _blocks
        .take(index)
        .where((block) => !block.image)
        .map((block) => block.value)
        .join(),
  ).length;

  Future<Uint8List> _image(int index) => _images.putIfAbsent(index, () async {
    final generation = _generation;
    try {
      final bytes = await service.image(
        _book.sourceId,
        _blocks[index].value,
      );
      if (!mounted || generation != _generation) return bytes;
      _imageHashes[index] = sha256.convert(bytes).toString();
      if (_pendingImageRestore == null &&
          _restoreImageBlock == index &&
          !_restoring) {
        _moved(_fragment, force: true);
        unawaited(_save());
      }
      return bytes;
    } catch (_) {
      if (mounted && generation == _generation) _failedImages.add(index);
      rethrow;
    }
  });

  Future<void> _restoreIllustration(
    NovelPosition restore,
    int generation,
  ) async {
    try {
      await Future.wait([
        for (var i = 0; i < _blocks.length; i++)
          if (_blocks[i].image) _image(i),
      ]);
      if (!mounted ||
          generation != _generation ||
          _pendingImageRestore != restore) {
        return;
      }
      final found = NovelLocator.locate(restore, _text);
      final matches = _imageHashes.entries
          .where((entry) => entry.value == restore.imageHash)
          .toList();
      final proven =
          found != null &&
          matches.length == 1 &&
          _textBeforeImage(matches.single.key) == found;
      _pendingImageRestore = null;
      _restoreImageBlock = proven
          ? matches.single.key
          : (_blocks.first.image ? 0 : null);
      _location = NovelLocator.capture(
        editionId: widget.editionId,
        sourceId: _book.sourceId,
        bookUrl: _book.url,
        chapter: _chapters[_chapterIndex],
        text: _text,
        offset: proven ? found : 0,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        imageHash: _imageHashes[_restoreImageBlock],
        imageUrl: _restoreImageBlock == null
            ? null
            : _blocks[_restoreImageBlock!].value,
      );
      setState(() {
        _restoreRevision++;
        _initialSavePending = true;
      });
      if (!proven) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已定位到对应章节，从本章开头继续阅读')));
      }
    } catch (error) {
      if (mounted &&
          generation == _generation &&
          _pendingImageRestore == restore) {
        setState(() => _imageRestoreError = error);
      }
    }
  }

  void _retryIllustrationRestore() {
    for (final index in _failedImages) {
      _images.remove(index);
    }
    _failedImages.clear();
    setState(() => _imageRestoreError = null);
    unawaited(_restoreIllustration(_pendingImageRestore!, _generation));
  }

  Widget _fragmentWidget(NovelFragment f, TextStyle style) {
    if (!f.image) {
      return SizedBox(
        height: f.height,
        child: Text(
          f.text,
          style: style,
          maxLines: 1,
          softWrap: false,
          textDirection: TextDirection.ltr,
        ),
      );
    }
    return SizedBox(
      height: f.height,
      child: NovelReaderImage(
        key: ValueKey('$_generation/${f.block}'),
        bytes: _image(f.block),
        retry: () {
          if (_imageRestoreError != null) {
            _retryIllustrationRestore();
          } else {
            setState(() {
              _images.remove(f.block);
              _failedImages.remove(f.block);
            });
          }
        },
      ),
    );
  }

  Widget _readerGestures(Widget child) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapUp: (details) {
      final width = MediaQuery.sizeOf(context).width;
      if (_prefs['mode'] == 'page' && details.localPosition.dx < width * .25) {
        _turn(-1);
      } else if (_prefs['mode'] == 'page' &&
          details.localPosition.dx > width * .75) {
        _turn(1);
      } else {
        setState(() => _chrome = !_chrome);
      }
    },
    child: child,
  );

  Widget _body(double width, double height, TextStyle style, double inset) {
    final scaler = MediaQuery.textScalerOf(context);
    final key =
        '$width/$height/${_prefs['fontSize']}/${_prefs['lineHeight']}/'
        '${_prefs['font']}/${_prefs['mode']}/${scaler.scale(style.fontSize!)}/$_chapterIndex/$_generation/$_restoreRevision';
    if (_layoutKey != key) {
      _restoring = true;
      _layoutKey = key;
      _layout = NovelLayout(
        blocks: _blocks,
        style: style,
        width: width,
        height: height,
        textScaler: scaler,
      );
      final startAtEnd = _startAtEnd;
      _fragment = _layout!.fragmentAt(
        _location!.textOffset,
        imageBlock: _restoreImageBlock,
      );
      if (_startAtEnd) {
        _fragment = _prefs['mode'] == 'page'
            ? _layout!.pages.last.first
            : _layout!.atPixels(
                (_layout!.pixelsBefore(_layout!.fragments.length) - height)
                    .clamp(0, double.infinity),
              );
        _startAtEnd = false;
      }
      final oldScroll = _scroll, oldPages = _pages;
      _scroll = ScrollController(
        initialScrollOffset: _layout!.pixelsBefore(_fragment),
      );
      _pages = PageController(initialPage: _layout!.pageOf(_fragment));
      _scroll!.addListener(() => _moved(_layout!.atPixels(_scroll!.offset)));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        oldScroll?.dispose();
        oldPages?.dispose();
        if (!mounted) return;
        if (_prefs['mode'] == 'scroll') {
          final position = _scroll!.position;
          // Resolve the restored viewport boundary before enabling progress updates.
          _scroll!.jumpTo(
            position.pixels.clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        }
        _restoring = false;
        // Reflow preserves the exact semantic anchor; only user movement updates it.
        if (_initialSavePending) {
          _initialSavePending = false;
          if (startAtEnd) _moved(_fragment, force: true);
          if (_pendingImageRestore == null &&
              _restoreImageBlock != null &&
              _imageHashes.containsKey(_restoreImageBlock)) {
            _moved(_fragment, force: true);
          }
          unawaited(_save());
        }
      });
    }
    if (_prefs['mode'] == 'scroll') {
      return SelectionArea(
        child: _readerGestures(
          CustomScrollView(
            key: ValueKey(key),
            controller: _scroll,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: SliverVariedExtentList.builder(
                  itemCount: _layout!.fragments.length,
                  itemExtentBuilder: (index, _) =>
                      _layout!.fragments[index].height,
                  itemBuilder: (_, index) =>
                      _fragmentWidget(_layout!.fragments[index], style),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: _chapterIndex > 0
                            ? () => _chapter(-1)
                            : null,
                        child: const Text('上一章'),
                      ),
                      TextButton(
                        onPressed: _chapterIndex + 1 < _chapters.length
                            ? () => _chapter(1)
                            : null,
                        child: const Text('下一章'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return _readerGestures(
      PageView.builder(
        key: ValueKey(key),
        controller: _pages,
        itemCount: _layout!.pages.length,
        onPageChanged: (page) => _moved(_layout!.pages[page].first),
        itemBuilder: (_, page) => Padding(
          padding: EdgeInsets.symmetric(horizontal: inset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final i in _layout!.pages[page])
                _fragmentWidget(_layout!.fragments[i], style),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = <(Color, Color)>[
      (const Color(0xfffaf9f6), const Color(0xff27251f)),
      (const Color(0xffdce9d5), const Color(0xff253323)),
      (const Color(0xffefe2c4), const Color(0xff433420)),
    ];
    final colors = theme.brightness == Brightness.dark
        ? (theme.colorScheme.surface, theme.colorScheme.onSurface)
        : palette[_dayTheme];
    final style = TextStyle(
      inherit: false,
      fontSize: (_prefs['fontSize'] as num).toDouble(),
      height: (_prefs['lineHeight'] as num).toDouble(),
      color: colors.$2,
      fontFamily: _prefs['font'] == 'serif' ? 'serif' : null,
    );
    final conflict =
        service.state.revisions('position/${widget.editionId}').length > 1;
    return CallbackShortcuts(
      bindings: {
        if (isDesktop()) const SingleActivator(LogicalKeyboardKey.f11): _window.toggle,
        if (isDesktop()) const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_window.fullscreen) unawaited(_window.toggle());
        },
      },
      child: PopScope(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Theme(
        data: theme,
        child: Scaffold(
          backgroundColor: colors.$1,
          extendBody: true,
          extendBodyBehindAppBar: true,
          appBar: NovelReaderToolbar(
            visible: _chrome,
            child: GestureDetector(
              onPanStart: isDesktop() ? (_) => windowManager.startDragging() : null,
              child: AppBar(
              backgroundColor: colors.$1,
              foregroundColor: colors.$2,
              leading: BackButton(onPressed: _leave),
              title: Text(_book.title),
              actions: [
                if (isDesktop()) ListenableBuilder(listenable: _window,
                  builder: (_, _) => IconButton(
                    tooltip: '切换全屏（F11）',
                    onPressed: _window.toggle,
                    icon: Icon(_window.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                  )),
                IconButton(
                  tooltip: '刷新目录与正文',
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: '添加书签',
                  onPressed: _busy ? null : _bookmark,
                  icon: const Icon(Icons.bookmark_add_outlined),
                ),
                NovelIllustrationToggle(
                  gallery: _illustrations,
                  enabled: !_busy,
                ),
                IconButton(
                  tooltip: '阅读设置',
                  onPressed: _busy ? null : _settings,
                  icon: const Icon(Icons.text_fields_rounded),
                ),
                if (widget.onChangeSource != null)
                  IconButton(
                    tooltip: '更换书源',
                    onPressed: _busy || _changingSource ? null : _changeSource,
                    icon: const Icon(Icons.swap_horiz_rounded),
                  ),
                if (isDesktop()) CloseButton(onPressed: () => windowManager.close()),
              ],
            )),
          ),
          // Overlay controls must not become additional body padding.
          body: MediaQuery(
            data: MediaQuery.of(context),
            // Keep body semantics separate from overlay controls and modal routes.
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  SafeArea(
                    child: _busy
                        ? const Center(child: CircularProgressIndicator())
                        : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(_error!),
                                  TextButton(
                                    onPressed: () => _open(refresh: true),
                                    child: const Text('重新加载'),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : CallbackShortcuts(
                            bindings: {
                              const SingleActivator(
                                LogicalKeyboardKey.arrowRight,
                              ): () =>
                                  _turn(1),
                              const SingleActivator(
                                LogicalKeyboardKey.pageDown,
                              ): () =>
                                  _turn(1),
                              const SingleActivator(
                                LogicalKeyboardKey.space,
                              ): () =>
                                  _turn(1),
                              const SingleActivator(
                                LogicalKeyboardKey.arrowLeft,
                              ): () =>
                                  _turn(-1),
                              const SingleActivator(
                                LogicalKeyboardKey.pageUp,
                              ): () =>
                                  _turn(-1),
                            },
                            child: Focus(
                              autofocus: true,
                              child: DecoratedBox(
                                position: DecorationPosition.foreground,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(
                                    alpha: (_prefs['brightness'] as num)
                                        .toDouble(),
                                  ),
                                ),
                                child: LayoutBuilder(
                                  builder: (_, c) {
                                    final column = c.maxWidth.clamp(0.0, 900.0);
                                    final width =
                                        column -
                                        2 *
                                            (_prefs['margin'] as num)
                                                .toDouble();
                                    return _body(
                                      width,
                                      c.maxHeight,
                                      style,
                                      (c.maxWidth - width) / 2,
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                  ),
                  AnimatedPositioned(
                    duration: NovelReaderToolbar.duration,
                    curve: Curves.easeOutCubic,
                    top: _chrome ? kToolbarHeight : 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      bottom: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!_busy)
                            NovelIllustrationBar(gallery: _illustrations),
                          if (_imageRestoreError != null)
                            MaterialBanner(
                              content: Text(
                                '插图未能完整加载，暂时无法定位原插图书签：$_imageRestoreError',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: _retryIllustrationRestore,
                                  child: const Text('重试定位'),
                                ),
                              ],
                            ),
                          if (conflict)
                            MaterialBanner(
                              content: const Text('多设备进度有冲突，自动保存已暂停。'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      _resolvePosition(reopen: true),
                                  child: const Text('选择进度'),
                                ),
                              ],
                            ),
                          if (_saveError != null)
                            MaterialBanner(
                              content: Text('本地保存失败：$_saveError'),
                              actions: [
                                TextButton(
                                  onPressed: _save,
                                  child: const Text('重试保存'),
                                ),
                              ],
                            ),
                          if (service.syncError != null)
                            MaterialBanner(
                              content: Text('云同步未完成：${service.syncError}'),
                              actions: [
                                TextButton(
                                  onPressed: service.retrySync,
                                  child: const Text('重试'),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          bottomNavigationBar: !_busy && _error == null
              ? NovelReaderToolbar(
                  visible: _chrome,
                  fromBottom: true,
                  child: Material(
                    color: colors.$1,
                    child: SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              '${_chapters[_chapterIndex].volume} ${_chapters[_chapterIndex].title}  ·  '
                              '${_chapterIndex + 1}/${_chapters.length}',
                              style: TextStyle(color: colors.$2, fontSize: 12),
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              IconButton(
                                tooltip: '上一章',
                                onPressed: _chapterIndex > 0
                                    ? () => _chapter(-1)
                                    : null,
                                icon: const Icon(Icons.skip_previous_rounded),
                              ),
                              TextButton.icon(
                                onPressed: _catalog,
                                icon: const Icon(Icons.list),
                                label: const Text('目录'),
                              ),
                              if (widget.shelfAction != null) widget.shelfAction!,
                              IconButton(
                                tooltip: '书签',
                                onPressed: _bookmarks,
                                icon: const Icon(Icons.bookmarks_outlined),
                              ),
                              IconButton(
                                tooltip: '阅读进度',
                                onPressed: _progress,
                                icon: const Icon(Icons.tune),
                              ),
                              IconButton(
                                tooltip: '下一章',
                                onPressed: _chapterIndex + 1 < _chapters.length
                                    ? () => _chapter(1)
                                    : null,
                                icon: const Icon(Icons.skip_next_rounded),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : null,
        ),
      ),
    ));
  }
}
