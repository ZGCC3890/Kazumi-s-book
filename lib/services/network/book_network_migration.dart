import 'package:hive_ce/hive.dart';

/// 0.1.0 inherited Kazumi's private mirror default without its credentials.
/// This is a one-time settings migration, never a failed-request fallback.
Future<void> migrateBookNetwork(Box<dynamic> settings) async {
  if (settings.get('bookPublicBangumiV1') == true) return;
  final mode = settings.get('bangumiAcceleration') as String?;
  final usedMirror =
      mode == 'mirror' ||
      ((mode == null || mode.isEmpty) &&
          settings.get('enableBangumiProxy', defaultValue: true) == true);
  if (settings.isNotEmpty && usedMirror) {
    await settings.putAll({
      'bangumiAcceleration': 'direct',
      'enableBangumiProxy': false,
      'bookNetworkNotice': true,
    });
  }
  await settings.put('bookPublicBangumiV1', true);
}
