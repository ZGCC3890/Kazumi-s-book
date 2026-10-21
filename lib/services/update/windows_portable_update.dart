import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

/// Stages a verified release before handing replacement to a separate process.
class WindowsPortableUpdate {
  WindowsPortableUpdate._(this.directory);

  final Directory directory;

  static Future<WindowsPortableUpdate> prepare({
    required String archivePath,
    required String executablePath,
    required int processId,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'kazumis-book-update-',
    );
    final updater = WindowsPortableUpdate._(directory);
    await File(path.join(directory.path, 'update.ps1')).writeAsString(
      await rootBundle.loadString('assets/update/windows_portable_update.ps1'),
    );
    await File(path.join(directory.path, 'update.json')).writeAsString(
      jsonEncode({
        'archive': path.absolute(archivePath),
        'executable': path.absolute(executablePath),
        'processId': processId,
      }),
    );
    final result = await Process.run(
      'powershell.exe',
      updater._arguments('Prepare'),
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        const [],
        '${result.stderr}',
        result.exitCode,
      );
    }
    return updater;
  }

  List<String> _arguments(String phase) => [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-WindowStyle',
    'Hidden',
    '-File',
    path.join(directory.path, 'update.ps1'),
    '-Phase',
    phase,
    '-StageDirectory',
    directory.path,
  ];

  Future<void> install({
    required Future<void> Function() beforeExit,
    void Function(int) exitProcess = exit,
  }) async {
    await beforeExit();
    final helper = await Process.run('powershell.exe', _arguments('Launch'));
    if (helper.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        const [],
        '${helper.stderr}',
        helper.exitCode,
      );
    }
    final ready = File(path.join(directory.path, 'ready'));
    final failure = File(path.join(directory.path, 'error.txt'));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await ready.exists()) {
      if (await failure.exists()) {
        throw StateError(await failure.readAsString());
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('更新程序未就绪，应用未退出。日志目录：${directory.path}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await File(path.join(directory.path, 'apply-approved')).writeAsString('');
    exitProcess(0);
  }
}
