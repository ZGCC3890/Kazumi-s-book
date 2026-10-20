import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/novel/novel_reader_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  for (final initial in [false, true]) {
    test('fullscreen toggles serialize and restore the original state $initial', () async {
      var fullscreen = initial;
      final applied = <bool>[];
      final pending = Completer<void>();
      var first = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'isFullScreen') return fullscreen;
          if (call.method == 'setFullScreen') {
            if (first) { first = false; await pending.future; }
            fullscreen = (call.arguments as Map)['isFullScreen'] as bool;
            applied.add(fullscreen);
            return null;
          }
          throw StateError('Unexpected native call');
        });
      final controller = NovelReaderWindow();
      await controller.restore();
      expect(applied, isEmpty);
      final one = controller.toggle();
      final two = controller.toggle();
      final restore = controller.restore();
      pending.complete();
      await Future.wait([one, two, restore]);
      expect(applied, [!initial, initial, initial]);
      expect(fullscreen, initial);
      await controller.restore();
      expect(applied, hasLength(3));
      controller.dispose();
    });
  }
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
}
