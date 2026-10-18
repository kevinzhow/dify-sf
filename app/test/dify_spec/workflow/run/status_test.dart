// dify-spec: web/app/components/workflow/run/__tests__/status.spec.tsx
// dify-spec: web/app/components/workflow/run/__tests__/status-container.spec.tsx
// dify-spec: web/app/components/workflow/run/__tests__/meta.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/status.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'run_harness.dart';

int skeletons(WidgetTester t) => find.byType(SkeletonBar).evaluate().length;

void main() {
  group('Status', () {
    testWidgets('renders the running status and loading placeholders', (t) async {
      final calls = <String>[];
      await renderRun(
        t,
        StatusPanel(
          status: 'running',
          workflowRunId: 'run-1',
          fetchPausedDetails: (id) async {
            calls.add(id);
            return const [];
          },
        ),
      );
      expect(find.text('Running'), findsOneWidget);
      expect(skeletons(t), 2);
      // useWorkflowPausedDetails is enabled only while paused.
      expect(calls, isEmpty);
    });

    testWidgets('renders the listening label when the run is waiting for input', (t) async {
      await renderRun(t, const StatusPanel(status: 'running', isListening: true, workflowRunId: 'run-2'));
      expect(find.text('Listening'), findsOneWidget);
    });

    testWidgets('renders succeeded metadata values', (t) async {
      await renderRun(t, const StatusPanel(status: 'succeeded', time: 1.234, tokens: 8));
      expect(textContent(t, find.byType(StatusContainer)), contains('SUCCESS'));
      expect(find.text('1.234s'), findsOneWidget);
      expect(find.text('8 Tokens'), findsOneWidget);
    });

    testWidgets('renders stopped fallbacks when time and tokens are missing', (t) async {
      await renderRun(t, const StatusPanel(status: 'stopped'));
      expect(find.text('STOP'), findsOneWidget);
      expect(find.text('-'), findsOneWidget);
      expect(find.text('0 Tokens'), findsOneWidget);
    });

    testWidgets('renders failed details and the partial-success exception tip', (t) async {
      await renderRun(t, const StatusPanel(status: 'failed', error: 'Something broke', exceptionCounts: 2));
      expect(find.text('FAIL'), findsOneWidget);
      expect(find.text('Something broke'), findsOneWidget);
      expect(
        find.text(
          'There are 2 nodes in the process running abnormally, please go to TRACING to check the logs.',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders the partial-succeeded warning summary', (t) async {
      await renderRun(t, const StatusPanel(status: 'partial-succeeded', exceptionCounts: 3));
      expect(find.text('PARTIAL SUCCESS'), findsOneWidget);
      expect(
        find.text(
          'There are 3 nodes in the process running abnormally, please go to TRACING to check the logs.',
          findRichText: true,
        ),
        findsOneWidget,
      );
    });

    testWidgets('opens the tracing tab when clicking the TRACING link', (t) async {
      var opened = 0;
      await renderRun(
        t,
        StatusPanel(status: 'partial-succeeded', exceptionCounts: 3, onOpenTracingTab: () => opened++),
      );
      await tapSpan(t, 'TRACING');
      expect(opened, 1);
    });

    testWidgets('renders the exception learn-more link', (t) async {
      final opened = <String>[];
      await renderRun(t, StatusPanel(status: 'exception', error: 'Bad request', onOpenUrl: opened.add));
      expect(find.text('EXCEPTION'), findsOneWidget);
      await tapSpan(t, 'workflow.common.learnMore');
      expect(opened, ['https://docs.dify.ai/use-dify/debug/error-type']);
    });

    testWidgets('renders paused placeholders when pause details have not loaded yet', (t) async {
      final calls = <String>[];
      await renderRun(
        t,
        StatusPanel(
          status: 'paused',
          workflowRunId: 'run-3',
          fetchPausedDetails: (id) {
            calls.add(id);
            return Completer<List<Map<String, Object?>>>().future;
          },
        ),
      );
      expect(find.text('PENDING'), findsOneWidget);
      expect(find.text('WORKFLOW.NODES.HUMANINPUT.LOG.REASON'), findsOneWidget);
      expect(skeletons(t), 3);
      expect(calls, ['run-3']);
    });

    testWidgets('renders paused human-input reasons and backstage URLs', (t) async {
      final opened = <String>[];
      await renderRun(
        t,
        StatusPanel(
          status: 'paused',
          workflowRunId: 'run-4',
          onOpenUrl: opened.add,
          fetchPausedDetails: (_) async => [
            {
              'node_id': 'node-1',
              'node_title': 'Need review',
              'pause_type': {
                'type': 'human_input',
                'form_id': 'form-1',
                'backstage_input_url': 'https://example.com/a',
              },
            },
            {
              'node_id': 'node-2',
              'node_title': 'Need review 2',
              'pause_type': {
                'type': 'human_input',
                'form_id': 'form-2',
                'backstage_input_url': 'https://example.com/b',
              },
            },
          ],
        ),
      );
      await t.pump();
      expect(find.text('workflow.nodes.humanInput.log.reasonContent'), findsOneWidget);
      expect(find.text('WORKFLOW.NODES.HUMANINPUT.LOG.BACKSTAGEINPUTURL'), findsOneWidget);
      await t.tap(find.text('https://example.com/a'));
      await t.tap(find.text('https://example.com/b'));
      expect(opened, ['https://example.com/a', 'https://example.com/b']);
    });
  });

  group('StatusContainer', () {
    group('Status Variants', () {
      testWidgets('should render success styling for the light theme', (t) async {
        await renderRun(t, const StatusContainer(status: 'succeeded', child: Text('Finished')));
        expect(find.text('Finished'), findsOneWidget);
        final box = t.widget<Container>(
          find.descendant(of: find.byType(StatusContainer), matching: find.byType(Container)).first,
        );
        expect((box.decoration! as BoxDecoration).color, DifyColors.workflowDisplaySuccessBg);
        final style = DefaultTextStyle.of(t.element(find.text('Finished'))).style;
        expect(style.color, DifyColors.textSuccess);
        // The highlight and line art are painted behind the content.
        expect(
          find.descendant(of: find.byType(StatusContainer), matching: find.byType(CustomPaint)),
          findsWidgets,
        );
      });
    });

    testWidgets('copies the supplied content from the status action', (t) async {
      final copied = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await renderRun(
        t,
        const StatusContainer(status: 'failed', copyContent: 'Execution failed', child: Text('Execution failed')),
      );
      await hover(t, find.text('Execution failed'));
      await t.tap(find.bySemanticsLabel('app-overview.overview.appInfo.embedded.copy'));
      expect(copied, ['Execution failed']);
    });
  });

  group('Meta', () {
    testWidgets('renders loading placeholders while the run is in progress', (t) async {
      await renderRun(t, const RunMetaData(status: 'running'));
      expect(skeletons(t), 6);
      expect(find.text('SUCCESS'), findsNothing);
      expect(find.text('run-log.meta.steps'), findsOneWidget);
    });

    for (final (status, label) in const [
      ('succeeded', 'SUCCESS'),
      ('partial-succeeded', 'PARTIAL SUCCESS'),
      ('exception', 'EXCEPTION'),
      ('failed', 'FAIL'),
      ('stopped', 'STOP'),
      ('paused', 'PENDING'),
    ]) {
      testWidgets('renders the %s status label', (t) async {
        await renderRun(t, RunMetaData(status: status));
        expect(find.text(label), findsOneWidget);
      });
    }

    testWidgets('renders explicit metadata values and hides steps when requested', (t) async {
      final calls = <int>[];
      await renderRun(
        t,
        RunMetaData(
          status: 'succeeded',
          executor: 'Alice',
          startTime: 1700000000000,
          time: 1.2349,
          tokens: 42,
          steps: 3,
          showSteps: false,
          formatTime: (v, f) {
            calls.add(v);
            return 'formatted:$v';
          },
        ),
      );
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('formatted:1700000000000'), findsOneWidget);
      expect(find.text('1.235s'), findsOneWidget);
      expect(find.text('42 Tokens'), findsOneWidget);
      expect(find.text('run-log.meta.steps'), findsNothing);
      expect(calls, [1700000000000]);
    });

    testWidgets('falls back to default values when metadata is missing', (t) async {
      final calls = <int>[];
      await renderRun(
        t,
        RunMetaData(
          status: 'failed',
          formatTime: (v, f) {
            calls.add(v);
            return '';
          },
        ),
      );
      expect(find.text('N/A'), findsOneWidget);
      expect(find.text('-'), findsNWidgets(2));
      expect(find.text('0 Tokens'), findsOneWidget);
      final row = find.ancestor(of: find.text('run-log.meta.steps'), matching: find.byType(Row)).first;
      expect(textContent(t, row), contains('1'));
      expect(calls, isEmpty);
    });
  });
}
