import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_service.dart';
import 'package:kazumi/novel/novel_sync_lifecycle.dart';
import 'package:kazumi/services/sync/webdav.dart';

class _Service extends NovelService {
  _Service() : super(WebDav());
  int calls = 0;
  Completer<void>? pending;
  @override Future<void> syncAutomatically() async {
    calls++;
    await pending?.future;
  }
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('startup once; desktop focus, minimize and resume never upload; close waits once', () async {
    final service = _Service();
    final lifecycle = NovelSyncLifecycle(service, desktop: true);
    await lifecycle.start();
    await lifecycle.start();
    for (final state in AppLifecycleState.values) {
      lifecycle.didChangeAppLifecycleState(state);
    }
    expect(service.calls, 1);
    service.pending = Completer<void>();
    var closed = false;
    final first = lifecycle.close()..then((_) => closed = true);
    expect(lifecycle.close(), same(first));
    await Future<void>.value();
    expect(closed, isFalse);
    expect(service.calls, 2);
    service.pending!.complete();
    await first;
    expect(closed, isTrue);
    lifecycle.dispose();
  });
  test('mobile only syncs once per background episode, not inactive or hidden', () async {
    final service = _Service();
    final lifecycle = NovelSyncLifecycle(service, desktop: false);
    await lifecycle.start();
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.inactive);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.hidden);
    expect(service.calls, 1);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.detached);
    await lifecycle.close();
    expect(service.calls, 2);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(service.calls, 2);
    lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    await lifecycle.close();
    expect(service.calls, 3);
    lifecycle.dispose();
  });
}
