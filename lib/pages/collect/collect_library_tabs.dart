import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

class CollectLibraryTabs extends StatelessWidget {
  const CollectLibraryTabs({super.key, required this.bookshelf});
  final bool bookshelf;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    initialIndex: bookshelf ? 1 : 0,
    child: SizedBox(
      width: 220,
      child: TabBar(
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        dividerColor: Colors.transparent,
        labelStyle: Theme.of(
          context,
        ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        tabs: const [
          Tab(text: '追番'),
          Tab(text: '书架'),
        ],
        onTap: (index) => context.navigate(
          index == 0 ? '/tab/collect/' : '/tab/collect/novels/',
        ),
      ),
    ),
  );
}
