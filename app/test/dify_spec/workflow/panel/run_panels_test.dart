// dify-spec: web/app/components/workflow/panel/__tests__/inputs-panel.spec.tsx
// dify-spec: web/app/components/workflow/panel/__tests__/workflow-preview.spec.tsx
// dify-spec: web/app/components/workflow/panel/__tests__/record.spec.tsx
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/resize_handle.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/human_input_content.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/result_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/tracing_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/workflow_preview.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../run/run_harness.dart';

DifyJson result([DifyJson o = const {}]) => {
  'status': 'running',
  'inputs_truncated': false,
  'process_data_truncated': false,
  'outputs_truncated': false,
  ...o,
};

DifyJson runningData({DifyJson? res, List<DifyJson> tracing = const [], DifyJson extra = const {}}) => {
  'result': res ?? result(),
  'tracing': tracing,
  ...extra,
};

Finder inputOf(String label) => find.descendant(
  of: find.ancestor(of: find.text(label).first, matching: find.byType(Column)).first,
  matching: find.byType(EditableText),
);

void main() {
  group('InputsPanel', () {
    final imageOn = {
      'file_upload': {
        'enabled': true,
        'image': {'enabled': true},
        'allowed_file_upload_methods': ['remote_url'],
        'number_limits': 3,
      },
    };

    Future<(WorkflowStore, List<DifyJson>, List<int>)> pump(
      WidgetTester t,
      List<DifyJson> variables, {
      void Function(WorkflowStore)? init,
      bool canRun = true,
      List<String>? toasts,
    }) async {
      final runs = <DifyJson>[], onRun = <int>[];
      final store = await renderRun(
        t,
        SingleChildScrollView(
          child: InputsPanel(
            panel: RunPanelContext(
              startVariables: variables,
              canRun: canRun,
              onRun: runs.add,
              toast: (type, m) => toasts?.add(m),
            ),
            onRun: () => onRun.add(1),
          ),
        ),
        initialStoreState: init,
        size: const Size(800, 900),
      );
      await t.pump();
      return (store, runs, onRun);
    }

    group('Rendering', () {
      testWidgets('should render current inputs, defaults, and the image uploader from the start node', (t) async {
        await pump(
          t,
          [
            {
              'type': 'text-input',
              'variable': 'question',
              'label': 'Question',
              'required': true,
              'default': 'default question',
            },
            {'type': 'number', 'variable': 'count', 'label': 'Count', 'required': false, 'default': '2'},
          ],
          init: (s) => s
            ..setInputs({'question': 'overridden question'})
            ..setFeatures(imageOn),
        );
        final question = t.widget<EditableText>(inputOf('Question'));
        expect(question.controller.text, 'overridden question');
        expect(question.focusNode.hasFocus, isTrue);
        expect(t.widget<EditableText>(inputOf('Count')).controller.text, '2');
        expect(find.text('common.imageUploader.pasteImageLink'), findsOneWidget);
      });
    });

    group('User Interactions', () {
      testWidgets('should update workflow inputs and image files when users edit the form', (t) async {
        final (store, _, _) = await pump(t, [
          {'type': 'text-input', 'variable': 'question', 'label': 'Question', 'required': true},
        ], init: (s) => s.setFeatures(imageOn));
        await t.enterText(inputOf('Question'), 'changed question');
        expect(store.inputs.value, {'question': 'changed question'});
        await t.tap(find.text('common.imageUploader.pasteImageLink'));
        await t.pumpAndSettle();
        expect(find.text('common.imageUploader.pasteImageLinkInputPlaceholder'), findsOneWidget);
        await t.enterText(find.byType(EditableText).last, 'https://example.com/image.png');
        await t.pump();
        await t.tap(find.text('common.operation.ok'));
        await t.pumpAndSettle();
        expect(store.files.value, [
          {
            'type': 'image',
            'transfer_method': 'remote_url',
            'url': 'https://example.com/image.png',
            'upload_file_id': '',
          },
        ]);
      });

      testWidgets('should not start a run when input validation fails', (t) async {
        final toasts = <String>[];
        final (_, runs, onRun) = await pump(t, [
          {'type': 'text-input', 'variable': 'question', 'label': 'Question', 'required': true},
        ], toasts: toasts);
        await t.tap(find.text('workflow.singleRun.startRun'));
        expect(toasts.single, contains('errorMessage.valueOfVarRequired'));
        expect(onRun, isEmpty);
        expect(runs, isEmpty);
      });

      testWidgets('should start a run with processed inputs when validation succeeds', (t) async {
        const uploaded = {'transfer_method': 'remote_url', 'upload_file_id': 'file-2'};
        final (_, runs, onRun) = await pump(
          t,
          [
            {'type': 'text-input', 'variable': 'question', 'label': 'Question', 'required': true},
            {'type': 'checkbox', 'variable': 'confirmed', 'label': 'Confirmed', 'required': false},
          ],
          init: (s) => s
            ..setInputs({'question': 'run this', 'confirmed': 'truthy'})
            ..setFiles([uploaded]),
        );
        await t.tap(find.text('workflow.singleRun.startRun'));
        expect(onRun, [1]);
        expect(runs.single, {
          'inputs': {'question': 'run this', 'confirmed': true},
          'files': [uploaded],
        });
      });
    });

    group('Disabled States', () {
      testWidgets('should disable the run button while a local file is still uploading', (t) async {
        final (_, runs, _) = await pump(
          t,
          const [],
          init: (s) => s.setFiles([
            {'transfer_method': 'local_file'},
          ]),
        );
        await t.tap(find.text('workflow.singleRun.startRun'));
        expect(runs, isEmpty);
      });

      testWidgets('should disable the run button while the workflow is already running', (t) async {
        final (_, runs, _) = await pump(t, const [], init: (s) => s.setWorkflowRunningData(runningData()));
        await t.tap(find.text('workflow.singleRun.startRun'));
        expect(runs, isEmpty);
      });

      testWidgets('should disable the run button and skip execution when test/run permission is missing', (t) async {
        final toasts = <String>[];
        final (_, runs, onRun) = await pump(t, const [], canRun: false, toasts: toasts);
        await t.tap(find.text('workflow.singleRun.startRun'));
        expect(toasts, isEmpty);
        expect(onRun, isEmpty);
        expect(runs, isEmpty);
      });
    });
  });

  group('WorkflowPreview', () {
    Future<(WorkflowStore, List<int>)> pump(
      WidgetTester t, {
      void Function(WorkflowStore)? init,
      void Function(DifyToastType, String)? toast,
      HumanInputFormSubmit? submit,
    }) async {
      final cancels = <int>[];
      final store = await renderRun(
        t,
        WorkflowPreview(
          panel: RunPanelContext(
            onCancel: () => cancels.add(1),
            toast: toast,
            onRun: (_) {},
            onHumanInputFormSubmit: submit,
          ),
        ),
        initialStoreState: init,
        size: const Size(1000, 900),
      );
      await t.pump();
      return (store, cancels);
    }

    testWidgets('resizes the run panel with the keyboard within the available canvas width', (t) async {
      final (store, _) = await pump(
        t,
        init: (s) => s
          ..setPreviewPanelWidth(480)
          ..setWorkflowCanvasWidth(1000),
      );
      t
          .widget<Focus>(find.descendant(of: find.byType(ResizeHandle), matching: find.byType(Focus)).first)
          .focusNode!
          .requestFocus();
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect(store.previewPanelWidth.value, 520);
      await t.sendKeyEvent(LogicalKeyboardKey.end);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.pump();
      expect(store.previewPanelWidth.value, 600);
      await t.sendKeyEvent(LogicalKeyboardKey.home);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(store.previewPanelWidth.value, 400);
    });

    testWidgets('should keep the input tab active, switch to result after running, and close the preview panel', (
      t,
    ) async {
      final (_, cancels) = await pump(
        t,
        init: (s) => s
          ..setShowInputsPanel(true)
          ..setShowDebugAndPreviewPanel(true)
          ..setPreviewPanelWidth(420),
      );
      expect(find.byType(InputsPanel), findsOneWidget);
      await t.tap(find.text('workflow.singleRun.startRun'));
      await t.pump();
      expect(find.byType(ResultText), findsOneWidget);
      await t.tap(find.bySemanticsLabel('common.operation.close'));
      expect(cancels, [1]);
    });

    testWidgets('should switch to detail when the workflow is listening', (t) async {
      await pump(
        t,
        init: (s) => s
          ..setIsListening(true)
          ..setWorkflowRunningData(runningData()),
      );
      expect(t.widget<ResultPanel>(find.byType(ResultPanel)).status, 'running');
    });

    testWidgets('should switch to detail when a finished run has no outputs or files', (t) async {
      await pump(
        t,
        init: (s) => s.setWorkflowRunningData(
          runningData(res: result({'status': 'succeeded', 'files': <Object?>[]}), extra: {'resultText': ''}),
        ),
      );
      expect(t.widget<ResultPanel>(find.byType(ResultPanel)).status, 'succeeded');
    });

    testWidgets('should render paused human input results and submit pending forms', (t) async {
      final submits = <(String, DifyJson)>[];
      await pump(
        t,
        submit: (token, data) async => submits.add((token, data)),
        init: (s) => s.setWorkflowRunningData(
          runningData(
            res: result({'status': 'paused', 'files': <Object?>[]}),
            extra: {
              'humanInputFormDataList': [
                {
                  'form_id': 'form-1',
                  'node_id': 'human-1',
                  'node_title': 'Approval',
                  'form_content': r'{{#$output.answer#}}',
                  'inputs': [
                    {
                      'type': 'paragraph',
                      'output_variable_name': 'answer',
                      'default': {'type': 'constant', 'value': '', 'selector': <Object?>[]},
                    },
                  ],
                  'actions': [
                    {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
                  ],
                  'form_token': 'form-token',
                  'display_in_ui': true,
                },
              ],
              'humanInputFilledFormDataList': [
                {
                  'node_id': 'human-0',
                  'node_title': 'Earlier',
                  'rendered_content': 'done',
                  'action_id': 'ok',
                  'action_text': 'OK',
                },
              ],
            },
          ),
        ),
      );
      // A paused run opens the RESULT tab with the pending forms and the filled ones.
      expect(t.widget<HumanInputFormList>(find.byType(HumanInputFormList)).humanInputFormDataList, hasLength(1));
      expect(
        t.widget<HumanInputFilledFormList>(find.byType(HumanInputFilledFormList)).humanInputFilledFormDataList,
        hasLength(1),
      );
      await t.enterText(
        find.descendant(of: find.byKey(const Key('content-item-textarea')), matching: find.byType(EditableText)),
        'ok',
      );
      await t.tap(find.text('Approve'));
      await t.pump();
      expect(submits.single.$1, 'form-token');
      expect(submits.single.$2, {
        'inputs': {'answer': 'ok'},
        'action': 'approve',
      });
    });

    testWidgets('should copy successful string output and show a success toast', (t) async {
      final copied = <String>[], toasts = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pump(
        t,
        toast: (type, m) => toasts.add(m),
        init: (s) => s.setWorkflowRunningData(
          runningData(
            res: result({'status': 'succeeded', 'files': <Object?>[]}),
            extra: {'resultText': 'final answer'},
          ),
        ),
      );
      await t.tap(find.text('run-log.result'));
      await t.pump();
      await t.tap(find.text('common.operation.copy'));
      expect(copied, ['final answer']);
      expect(toasts, ['common.actionMsg.copySuccessfully']);
    });

    testWidgets('should show a loading state for an empty detail panel', (t) async {
      await pump(t, init: (s) => s.setIsListening(true));
      expect(find.byType(RunLoading), findsOneWidget);
    });

    testWidgets('should show a loading state for an empty tracing panel', (t) async {
      await pump(t, init: (s) => s.setWorkflowRunningData(runningData()));
      await t.tap(find.text('run-log.tracing'));
      await t.pump();
      expect(find.byType(RunLoading), findsOneWidget);
    });

    testWidgets(
      'should keep inert tabs disabled without run data and switch among result, detail, and tracing when data exists',
      (t) async {
        final (store, _) = await pump(t, init: (s) => s.setShowInputsPanel(true));
        for (final tab in ['run-log.result', 'run-log.detail', 'run-log.tracing']) {
          await t.tap(find.text(tab));
        }
        await t.pump();
        expect(find.byType(InputsPanel), findsOneWidget);
        store.setWorkflowRunningData(
          runningData(
            res: result({'status': 'succeeded', 'files': <Object?>[]}),
            tracing: [createNodeTracing()],
            extra: {'resultText': 'ready'},
          ),
        );
        await t.pump();
        await t.tap(find.text('run-log.result'));
        await t.pump();
        expect(find.byType(ResultText), findsOneWidget);
        await t.tap(find.text('run-log.detail'));
        await t.pump();
        expect(find.byType(ResultPanel), findsOneWidget);
        await t.tap(find.text('run-log.tracing'));
        await t.pump();
        expect(t.widget<TracingPanel>(find.byType(TracingPanel)).list, hasLength(1));
        await t.tap(find.text('run-log.result'));
        await t.pump();
        // An empty text result links to the detail tab.
        t.widget<ResultText>(find.byType(ResultText)).onClick!();
        await t.pump();
        expect(find.byType(ResultPanel), findsOneWidget);
      },
    );

    testWidgets('should render a single merged reasoning panel above the result on the result tab', (t) async {
      await pump(
        t,
        init: (s) => s.setWorkflowRunningData(
          runningData(
            extra: {
              'resultText': '',
              'reasoningContent': {'llm-1': 'thinking a', 'llm-2': 'thinking b'},
            },
          ),
        ),
      );
      await t.tap(find.text('run-log.result'));
      await t.pump();
      final panels = t.widgetList<ReasoningPanel>(find.byType(ReasoningPanel));
      expect(panels, hasLength(1));
      expect(panels.single.content.keys, ['llm-1', 'llm-2']);
      expect(panels.single.done, isFalse);
    });

    testWidgets('should mark reasoning done once the answer starts streaming while still running', (t) async {
      await pump(
        t,
        init: (s) => s.setWorkflowRunningData(
          runningData(
            extra: {
              'resultText': 'the answer',
              'reasoningContent': {'llm-1': 'thinking a'},
            },
          ),
        ),
      );
      await t.tap(find.text('run-log.result'));
      await t.pump();
      expect(t.widget<ReasoningPanel>(find.byType(ReasoningPanel)).done, isTrue);
    });

    testWidgets('should not render a reasoning panel when there is no reasoning content', (t) async {
      await pump(
        t,
        init: (s) => s.setWorkflowRunningData(
          runningData(
            extra: {
              'resultText': '',
              'reasoningContent': {'llm': ''},
            },
          ),
        ),
      );
      await t.tap(find.text('run-log.result'));
      await t.pump();
      expect(find.byType(ReasoningPanel), findsNothing);
    });

    testWidgets('should switch to the tracing tab when result panel requests it', (t) async {
      await pump(
        t,
        init: (s) => s.setWorkflowRunningData(
          runningData(
            res: result({'status': 'partial-succeeded', 'files': <Object?>[]}),
            tracing: [createNodeTracing()],
            extra: {'resultText': 'ready'},
          ),
        ),
      );
      await t.tap(find.text('run-log.detail'));
      await t.pump();
      t.widget<ResultPanel>(find.byType(ResultPanel)).onOpenTracingTab!();
      await t.pump();
      expect(t.widget<TracingPanel>(find.byType(TracingPanel)).list, hasLength(1));
    });

    testWidgets('should resize the preview panel within the allowed workflow canvas bounds', (t) async {
      final (store, _) = await pump(
        t,
        init: (s) => s
          ..setPreviewPanelWidth(450)
          ..setWorkflowCanvasWidth(1000),
      );
      final handle = find.byType(ResizeHandle);
      final g = await t.startGesture(t.getCenter(handle));
      await g.moveBy(const Offset(-50, 0));
      await t.pump();
      await g.moveBy(const Offset(-600, 0));
      await t.pump();
      await g.up();
      await t.pump();
      // 450 + 50 = 500; 1100 exceeds the 600 limit and is ignored.
      expect(store.previewPanelWidth.value, 500);
    });
  });

  group('Record', () {
    testWidgets('renders the run title and passes run and trace URLs to the run panel', (t) async {
      final finished = DateTime(2026, 1, 1, 14, 30, 25).millisecondsSinceEpoch ~/ 1000;
      await renderRun(
        t,
        RunRecord(
          fetchRunDetail: (id) async => {'id': id, 'status': 'succeeded'},
          fetchTracingList: (id) async => const [],
        ),
        initialStoreState: (s) =>
            s.setHistoryWorkflowData({'id': 'run-1', 'status': 'succeeded', 'finished_at': finished}),
        size: const Size(800, 900),
      );
      await t.pump();
      expect(find.text('Test Run (02:30:25 PM)'), findsOneWidget);
      expect(t.widget<RunPanel>(find.byType(RunPanel)).runId, 'run-1');
    });
  });
}
