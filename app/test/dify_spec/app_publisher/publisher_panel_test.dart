// dify-spec: web/app/components/app/app-publisher/__tests__/publisher-panel.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/header/publisher/app_publisher.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// The Publish trigger (the popup is a dialog of the same name, and its publish button comes after).
SemanticsNode _trigger() => allNamed('workflow.common.publish').where(isButton).first;

void main() {
  setUp(useDifyTestTranslator);

  group('PublisherPanel', () {
    testWidgets('keeps the default outside-press dismissal outside deployment configuration', (t) async {
      final semantics = t.ensureSemantics();
      t.view.physicalSize = const Size(1600, 1400);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = 0.5;
      addTearDown(t.view.reset);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await renderWithSafeViewport(
        t,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DifyButton(onPressed: () {}, child: const Text('Outside control')),
            const SizedBox(width: 400),
            const AppPublisher(),
          ],
        ),
      );
      await t.tap(find.text('workflow.common.publish').first);
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      expect(find.text('workflow.common.notPublishedYet'), findsOneWidget);
      expect(isExpanded(_trigger()), isTrue);

      await t.tap(find.text('Outside control'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 16));
      await t.pump(const Duration(milliseconds: 200));
      await t.pump();
      expect(find.text('workflow.common.notPublishedYet'), findsNothing);
      expect(isExpanded(_trigger()), isFalse);
      semantics.dispose();
    });
  });
}
