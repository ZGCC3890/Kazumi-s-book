import 'package:flutter/foundation.dart';
import 'novel_models.dart';
import 'novel_sync_state.dart';

/// Reader contract, independent of network transports and native player hooks.
abstract interface class NovelReaderStore implements Listenable {
  NovelJson get preferences;
  NovelSyncState get state;
  String? get syncError;
  NovelPosition? position(String editionId);
  Future<List<NovelChapter>> catalog(NovelBook book, {bool refresh = false});
  Future<List<NovelBlock>> content(
    String sourceId,
    NovelChapter chapter, {
    bool refresh = false,
  });
  Future<Uint8List> image(String sourceId, String url);
  Future<void> savePosition(NovelPosition position);
  Future<void> savePreferences(NovelJson value);
  Future<void> addBookmark(NovelPosition position, String note);
  Future<void> deleteBookmark(String id);
  List<NovelJson> bookmarks(String editionId);
  Future<void> resolve(String key, NovelRevision selected);
  Future<void> syncAutomatically();
}
