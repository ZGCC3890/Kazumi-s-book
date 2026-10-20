import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:kazumi/utils/device.dart';
import 'novel_service.dart';

/// Event-based synchronization; reading and focus changes never schedule uploads.
class NovelSyncLifecycle with WidgetsBindingObserver {
  NovelSyncLifecycle(this.service, {bool? desktop}) : desktop = desktop ?? isDesktop();
  final NovelService service;
  final bool desktop;
  bool _started = false;
  Future<void>? _closing;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    await service.syncAutomatically();
  }

  Future<void> close() => _closing ??= service.syncAutomatically();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (desktop) return;
    if (state == AppLifecycleState.resumed) _closing = null;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(close());
    }
  }

  void dispose() => WidgetsBinding.instance.removeObserver(this);
}
