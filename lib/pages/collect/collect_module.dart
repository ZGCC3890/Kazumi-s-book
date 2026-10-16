import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/collect/collect_page.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/collect/collect_library_tabs.dart';
import 'package:kazumi/novel/novel_library_page.dart';
import 'package:kazumi/novel/novel_service.dart';

final collectModule = createModule(
  path: '/collect',
  register: (c) {
    c.route(
      '/',
      transition: TransitionType.none,
      child: (context, state) => CollectPage(
        controller: inject<CollectController>(),
        title: const CollectLibraryTabs(bookshelf: false),
      ),
    );
    c.route(
      '/novels/',
      transition: TransitionType.none,
      child: (context, state) => NovelLibraryPage(
        service: inject<NovelService>(),
        title: const CollectLibraryTabs(bookshelf: true),
      ),
    );
  },
);
