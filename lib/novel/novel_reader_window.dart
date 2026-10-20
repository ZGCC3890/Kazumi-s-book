import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/utils/async_serial_queue.dart';

/// Owns only fullscreen changes made by this reader session.
class NovelReaderWindow extends ChangeNotifier {
  bool? _originalFullscreen;
  bool fullscreen = false;
  bool used = false;
  final _operations = AsyncSerialQueue();

  Future<void> toggle() {
    used = true;
    return _operations.run(() async {
      final current = await windowManager.isFullScreen();
      _originalFullscreen ??= current;
      await windowManager.setFullScreen(!current);
      fullscreen = !current;
      notifyListeners();
    });
  }

  Future<void> restore() => _operations.run(() async {
    final original = _originalFullscreen;
    if (original == null) return;
    await windowManager.setFullScreen(original);
    _originalFullscreen = null;
    used = false;
    fullscreen = original;
  });
}
