// dify-spec: packages/dify-ui/src/drawer/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('Drawer wrapper', () {
    group('User Interactions', () {
      testWidgets('should open a portalled drawer and close it with the default close button', (t) async {
        final semantics = t.ensureSemantics();
        await render(
          t,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDifyDrawer<void>(
                context,
                builder: (context, close) => DifyDrawerPopup(
                  label: 'Settings',
                  scopesRoute: true,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Settings'),
                        const Text('Configure the current workspace.'),
                        const Text('Workspace controls'),
                        DifyDrawerCloseButton(onPressed: close),
                      ],
                    ),
                  ),
                ),
              ),
              child: const Text('Open settings'),
            ),
          ),
        );
        expect(allByRole(SemanticsRole.dialog), isEmpty);

        await t.tap(find.text('Open settings'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));

        // In the overlay (the portal), not below the trigger.
        expect(allByRole(SemanticsRole.dialog), hasLength(1));
        expect(find.ancestor(of: find.text('Workspace controls'), matching: find.byType(TextButton)), findsNothing);
        expect(find.text('Workspace controls'), findsOneWidget);
        expect(find.text('Configure the current workspace.'), findsOneWidget);
        // The backdrop: the route's modal barrier.
        expect(find.byType(ModalBarrier), findsWidgets);

        await t.tap(find.bySemanticsLabel('Close drawer'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 250));
        expect(allByRole(SemanticsRole.dialog), isEmpty);
        expect(find.text('Workspace controls'), findsNothing);
        semantics.dispose();
      });
    });
  });
}
