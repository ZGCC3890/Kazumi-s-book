import 'package:flutter/material.dart';

class NovelReaderToolbar extends StatelessWidget
    implements PreferredSizeWidget {
  const NovelReaderToolbar({
    super.key,
    required this.visible,
    required this.child,
    this.fromBottom = false,
  });
  static const duration = Duration(milliseconds: 160);
  final bool visible, fromBottom;
  final Widget child;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: visible ? 1 : 0),
    duration: duration,
    curve: Curves.easeOutCubic,
    child: IgnorePointer(
      ignoring: !visible,
      child: ExcludeSemantics(excluding: !visible, child: child),
    ),
    builder: (_, value, child) => Offstage(
      offstage: value == 0,
      child: FractionalTranslation(
        translation: Offset(0, (fromBottom ? 1 : -1) * (1 - value)),
        child: child,
      ),
    ),
  );
}
