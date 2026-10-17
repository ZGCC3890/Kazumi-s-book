import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/menu/menu.dart';

void main() {
  for (final size in [const Size(480, 900), const Size(1280, 800)]) {
    testWidgets('production menu exposes navigation outside the outlet $size', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final module = createModule(
          register: (root) {
            root.module(
              createModule(
                path: '/tab',
                register: (tabs) {
                  tabs.route(
                    '/',
                    child: (_, state) => ScaffoldMenu(location: state.uri.path),
                    children: (pages) {
                      for (final path in [
                        'popular',
                        'timeline',
                        'collect',
                        'my',
                      ]) {
                        pages.route(
                          '/$path/',
                          child: (_, _) => Scaffold(
                            body: Center(child: Text('content-$path')),
                          ),
                        );
                      }
                    },
                  );
                },
              ),
            );
          },
        );
        await tester.pumpWidget(
          ModularApp(
            module: module,
            initialRoute: '/tab/popular/',
            navigatorObservers: [rootRouteObserver],
            child: Builder(
              builder: (context) => MaterialApp.router(
                routerConfig: ModularApp.routerConfigOf(context),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        void expectNavigation() {
          final nodes = tester.semantics
              .simulatedAccessibilityTraversal()
              .toList();
          for (final label in ['推荐', '时间表', '追番', '我的']) {
            expect(
              nodes.where((node) => node.label.contains(label)),
              hasLength(1),
            );
          }
          if (size.width > size.height) {
            expect(nodes.where((node) => node.tooltip == '搜索'), hasLength(1));
          }
        }

        expectNavigation();
        await tester.tap(find.bySemanticsLabel(RegExp('追番')));
        await tester.pumpAndSettle();
        expect(find.text('content-collect'), findsOneWidget);
        expectNavigation();

        // A root modal still excludes the shell; the outlet boundary must not
        // leak background destinations into an active dialog's accessibility.
        final dialog = showDialog<void>(
          context: tester.element(find.byType(ScaffoldMenu)),
          builder: (context) => AlertDialog(
            title: const Text('Root dialog'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close dialog'),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.semantics.simulatedAccessibilityTraversal().where(
            (node) => node.label.contains('追番'),
          ),
          isEmpty,
        );
        await tester.tap(find.text('Close dialog'));
        await tester.pumpAndSettle();
        await dialog;
        expectNavigation();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        semantics.dispose();
      }
    });
  }
}
