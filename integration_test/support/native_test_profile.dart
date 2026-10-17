import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Keeps native application data inside the test artifacts, away from user data.
class NativeTestProfile extends PathProviderPlatform {
  NativeTestProfile(this.root);

  final Directory root;

  Future<String> _directory(String name) async =>
      (await Directory('${root.path}/$name').create(recursive: true)).path;

  @override
  Future<String?> getApplicationSupportPath() => _directory('support');

  @override
  Future<String?> getTemporaryPath() => _directory('temp');

  @override
  Future<String?> getApplicationCachePath() => _directory('cache');

  @override
  Future<String?> getApplicationDocumentsPath() => _directory('documents');

  @override
  Future<String?> getDownloadsPath() => _directory('downloads');
}
