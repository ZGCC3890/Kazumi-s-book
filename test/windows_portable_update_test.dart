@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/update/windows_portable_update.dart';
import 'package:path/path.dart' as path;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sandbox;
  late Directory installation;
  late File archive;
  late File executable;
  final updaterDirectories = <Directory>[];

  Future<ProcessResult> powershell(String script) => Process.run(
    'powershell.exe',
    [
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      base64Encode(script.codeUnits.expand((c) => [c & 255, c >> 8]).toList()),
    ],
  );
  String quote(String value) => "'${value.replaceAll("'", "''")}'";
  Future<void> waitFor(File file) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!await file.exists()) {
      if (DateTime.now().isAfter(deadline)) fail('Missing file: ${file.path}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<WindowsPortableUpdate> prepare(int processId) async {
    final updater = await WindowsPortableUpdate.prepare(
      archivePath: archive.path,
      executablePath: executable.path,
      processId: processId,
    );
    updaterDirectories.add(updater.directory);
    return updater;
  }

  setUpAll(() async {
    // Use the checkout drive, not C:, including shell metacharacters and Unicode.
    sandbox = await Directory(
      'build',
    ).createTemp("portable 更新 [test] O'Brien & ");
    installation = await Directory(
      path.join(sandbox.path, 'installed'),
    ).create();
    final payload = await Directory(
      path.join(sandbox.path, 'package'),
    ).create();
    executable = File(path.join(installation.path, 'kazumis_book.exe'));
    archive = File(path.join(sandbox.path, 'release.zip'));
    final fixtureCode = r'''
using System;
using System.IO;
using System.Threading;
public static class UpdateFixture {
  public static void Main(string[] args) {
    var root = AppDomain.CurrentDomain.BaseDirectory;
    if (args.Length > 0) { Thread.Sleep(60000); return; }
    File.WriteAllText(Path.Combine(root, "restarted.txt"), File.ReadAllText(Path.Combine(root, "version.txt")));
  }
}
''';
    final compilerDirectory = await Directory.systemTemp.createTemp(
      'update-fixture-',
    );
    final compilerOutput = File(
      path.join(compilerDirectory.path, 'fixture.exe'),
    );
    final compiled = await powershell(
      'Add-Type -TypeDefinition ${quote(fixtureCode)} '
      '-OutputAssembly ${quote(compilerOutput.path)} -OutputType WindowsApplication',
    );
    expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
    await compilerOutput.copy(executable.path);
    await compilerOutput.delete();
    await executable.copy(path.join(payload.path, 'kazumis_book.exe'));
    await File(
      path.join(payload.path, 'flutter_windows.dll'),
    ).writeAsString('new-dll');
    final assets = await Directory(
      path.join(payload.path, 'data', 'flutter_assets'),
    ).create(recursive: true);
    await File(path.join(assets.path, 'new.txt')).writeAsString('new-asset');
    await File(path.join(payload.path, 'version.txt')).writeAsString('new');
    final zipped = await powershell(
      'Add-Type -AssemblyName System.IO.Compression.FileSystem; '
      '[IO.Compression.ZipFile]::CreateFromDirectory(${quote(payload.absolute.path)}, ${quote(archive.absolute.path)})',
    );
    expect(zipped.exitCode, 0, reason: '${zipped.stderr}');
  });

  tearDownAll(() async {
    for (final dir in [...updaterDirectories, sandbox]) {
      for (final entity in dir.listSync(recursive: true).whereType<File>()) {
        await entity.delete();
      }
    }
  });

  test(
    'stages without replacing; waits for exit, updates original drive and restarts',
    () async {
      await File(
        path.join(installation.path, 'version.txt'),
      ).writeAsString('old');
      final unrelated = await File(
        path.join(installation.path, 'my-notes.txt'),
      ).writeAsString('keep');
      final parent = await Process.start(executable.absolute.path, ['wait']);
      addTearDown(() => parent.kill());
      final updater = await prepare(parent.pid);
      expect(
        await File(path.join(installation.path, 'version.txt')).readAsString(),
        'old',
      );
      var saved = false;
      await updater.install(
        beforeExit: () async {
          saved = true;
        },
        exitProcess: (code) {
          expect(saved, isTrue);
          expect(code, 0);
          expect(
            File(
              path.join(installation.path, 'version.txt'),
            ).readAsStringSync(),
            'old',
          );
          parent.kill();
        },
      );
      await waitFor(File(path.join(installation.path, 'restarted.txt')));
      await waitFor(File(path.join(updater.directory.path, 'result.txt')));
      expect(
        await File(
          path.join(installation.path, 'restarted.txt'),
        ).readAsString(),
        'new',
      );
      expect(
        await File(
          path.join(installation.path, 'data', 'flutter_assets', 'new.txt'),
        ).readAsString(),
        'new-asset',
      );
      expect(await unrelated.readAsString(), 'keep');
    },
  );

  test('failed save never starts replacement or exits', () async {
    final updater = await prepare(pid);
    await expectLater(
      updater.install(
        beforeExit: () async => throw StateError('save failed'),
        exitProcess: (_) => fail('must not exit'),
      ),
      throwsStateError,
    );
    expect(
      File(path.join(updater.directory.path, 'ready')).existsSync(),
      isFalse,
    );
  });

  test(
    'helper cannot attach to old process: reports error without exiting',
    () async {
      final updater = await prepare(2147483647);
      await expectLater(
        updater.install(
          beforeExit: () async {},
          exitProcess: (_) => fail('must not exit'),
        ),
        throwsStateError,
      );
    },
  );

  test('invalid ZIP is rejected before exit', () async {
    final invalid = await File(
      path.join(sandbox.path, 'invalid.zip'),
    ).writeAsString('not zip');
    await expectLater(
      WindowsPortableUpdate.prepare(
        archivePath: invalid.path,
        executablePath: executable.path,
        processId: pid,
      ),
      throwsA(isA<ProcessException>()),
    );
  });

  test('launcher failure never closes the application', () async {
    final updater = await prepare(pid);
    await File(
      path.join(updater.directory.path, 'update.ps1'),
    ).writeAsString("throw 'launch failed'");
    await expectLater(
      updater.install(
        beforeExit: () async {},
        exitProcess: (_) => fail('must not exit'),
      ),
      throwsA(isA<ProcessException>()),
    );
  });

  test(
    'helper that never becomes ready times out without authorizing replacement',
    () async {
      final updater = await prepare(pid);
      await File(
        path.join(updater.directory.path, 'update.ps1'),
      ).writeAsString('exit 0');
      await expectLater(
        updater.install(
          beforeExit: () async {},
          exitProcess: (_) => fail('must not exit'),
        ),
        throwsStateError,
      );
      expect(
        File(path.join(updater.directory.path, 'apply-approved')).existsSync(),
        isFalse,
      );
    },
  );

  test('archive with missing executable is rejected', () async {
    await expectLater(
      WindowsPortableUpdate.prepare(
        archivePath: archive.path,
        executablePath: path.join(installation.path, 'missing.exe'),
        processId: pid,
      ),
      throwsA(isA<ProcessException>()),
    );
  });

  test('missing installation directory is reported before exiting', () async {
    await expectLater(
      WindowsPortableUpdate.prepare(
        archivePath: archive.path,
        executablePath: path.join(sandbox.path, 'missing', 'kazumis_book.exe'),
        processId: pid,
      ),
      throwsA(isA<ProcessException>()),
    );
  });
}
