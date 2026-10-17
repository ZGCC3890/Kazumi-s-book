import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/pages/info/source_sheet.dart';
import 'package:kazumi/plugins/plugins_controller.dart';

/// Details and collection cards share the same source-selection/playback path.
class WatchEntry {
  static Future<void> open(
    BuildContext context,
    BangumiItem item, {
    InfoController? controller,
  }) async {
    if (inject<PluginsController>().pluginList.isEmpty) {
      KazumiDialog.showToast(
        message: '还没有规则，无法开始观看',
        showActionButton: true,
        actionLabel: '添加规则',
        onActionPressed: () {
          if (context.mounted) context.pushNamed('/settings/plugin/');
        },
        duration: const Duration(seconds: 4),
      );
      return;
    }
    final state = controller ?? InfoController(inject<CollectController>());
    state.bangumiItem = item;
    await showAdaptiveBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      maxHeightFactor: .88,
      builder: (_) => SourceSheet(infoController: state),
    );
  }
}
