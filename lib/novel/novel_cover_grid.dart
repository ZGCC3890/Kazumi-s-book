import 'package:flutter/material.dart';

/// Shared responsive cover sizing for search and the bookshelf.
class NovelCoverGrid extends StatelessWidget {
  const NovelCoverGrid({super.key, required this.itemCount, required this.itemBuilder,
    this.actionHeight = 0});
  final int itemCount;
  final Widget Function(BuildContext, int, double) itemBuilder;
  final double actionHeight;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final columns = ((constraints.maxWidth + 12) / 152).floor().clamp(2, 7);
    final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
    final titleHeight = MediaQuery.textScalerOf(context).scale(14) * 3 + 16;
    return GridView.builder(
      primary: false,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns, crossAxisSpacing: 12, mainAxisSpacing: 16,
        mainAxisExtent: width * 1.45 + titleHeight + actionHeight,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) => itemBuilder(context, index, width),
    );
  });
}
