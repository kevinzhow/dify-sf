// dify-spec: web/app/components/app/workflow-log/__tests__/trigger-by-display.spec.tsx
import 'package:dify_sf_app/src/app_detail/logs/workflow_log.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  Finder image(String label) => find.bySemanticsLabel(label);

  group('TriggerByDisplay', () {
    testWidgets('labels the %s trigger source', (t) async {
      for (final (from, label) in [
        ('app-run', 'app-log.triggerBy.appRun'),
        ('debugging', 'app-log.triggerBy.debugging'),
        ('webhook', 'app-log.triggerBy.webhook'),
        ('schedule', 'app-log.triggerBy.schedule'),
        ('plugin', 'app-log.triggerBy.plugin'),
        ('rag-pipeline-run', 'app-log.triggerBy.ragPipelineRun'),
        ('rag-pipeline-debugging', 'app-log.triggerBy.ragPipelineDebugging'),
      ]) {
        await renderLog(t, TriggerByDisplay(triggeredFrom: from));
        expect(find.text(label), findsOneWidget, reason: from);
      }
    });

    testWidgets('uses plugin event metadata as the visible trigger name', (t) async {
      await renderLog(
        t,
        const TriggerByDisplay(triggeredFrom: 'plugin', triggerMetadata: {'event_name': 'Issue created'}),
      );
      expect(find.text('Issue created'), findsOneWidget);
    });

    testWidgets('uses the theme-specific plugin icon when available', (t) async {
      DifyColors.useDark(true);
      addTearDown(() => DifyColors.useDark(false));
      await renderLog(
        t,
        const TriggerByDisplay(
          triggeredFrom: 'plugin',
          triggerMetadata: {'icon': 'light.svg', 'icon_dark': 'dark.svg'},
        ),
      );
      expect(image('Plugin trigger icon'), findsOneWidget);
      expect(find.byKey(const ValueKey('trigger-plugin-icon-dark.svg')), findsOneWidget);
    });

    testWidgets('can render an icon-only trigger label', (t) async {
      await renderLog(t, const TriggerByDisplay(triggeredFrom: 'plugin', showText: false));
      expect(find.text('app-log.triggerBy.plugin'), findsNothing);
      expect(image('Default plugin trigger icon'), findsOneWidget);
    });
  });
}
