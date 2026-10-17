import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../integration_test/support/native_test_profile.dart';

void main() {
  test('native test paths keep every write inside one isolated profile', () async {
    final sandbox = await Directory.systemTemp.createTemp('book-profile-test-');
    addTearDown(() => sandbox.delete(recursive: true));
    final personalData = File(p.join(sandbox.path, 'personal-data.txt'));
    await personalData.writeAsString('existing personal data');
    final profileRoot = Directory(p.join(sandbox.path, 'test-profile'));
    final profile = NativeTestProfile(profileRoot);
    final paths = await Future.wait([
      profile.getApplicationSupportPath(),
      profile.getTemporaryPath(),
      profile.getApplicationCachePath(),
      profile.getApplicationDocumentsPath(),
      profile.getDownloadsPath(),
    ]);
    expect(paths.toSet(), hasLength(5));
    for (final path in paths) {
      expect(path, isNotNull);
      expect(p.isWithin(profileRoot.path, path!), isTrue);
      expect(await Directory(path).exists(), isTrue);
      final marker = File(p.join(path, 'test-write.txt'));
      await marker.writeAsString('isolated write');
      expect(await marker.readAsString(), 'isolated write');
    }
    expect(await personalData.readAsString(), 'existing personal data');
    expect(await profile.getApplicationSupportPath(), paths.first);
  });
}
