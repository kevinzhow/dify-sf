// dify-spec: web/app/components/workflow-app/components/workflow-header/__tests__/features-trigger.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/checklist_item.dart';
import 'package:dify_sf_app/src/workflow_editor/header/features_trigger.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/header/publisher/app_publisher.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late List<(HeaderToastType, String)> toasts;
  late int checks, syncs, resets, refreshed;
  late List<({String title, String releaseNotes})> publishes;
  late Future<bool> Function() checkResult, syncResult;
  late Future<DifyJson?> Function() publishResult;

  setUp(() {
    toasts = [];
    checks = syncs = resets = refreshed = 0;
    publishes = [];
    checkResult = () async => true;
    syncResult = () async => true;
    publishResult = () async => {'created_at': 1704067200};
  });

  WorkflowPublishHooks hooks() => WorkflowPublishHooks(
    checkBeforePublish: () {
      checks++;
      return checkResult();
    },
    syncWorkflowDraft: () {
      syncs++;
      return syncResult();
    },
    publishWorkflow: ({title = '', releaseNotes = ''}) {
      publishes.add((title: title, releaseNotes: releaseNotes));
      return publishResult();
    },
    onPublished: () => refreshed++,
  );

  WorkflowHeaderData data({
    bool chat = false,
    List<HeaderNode> nodes = const [],
    bool hasUserInputNode = false,
    List<ChecklistItem> checklist = const [],
    bool canEdit = true,
  }) => WorkflowHeaderData(
    isChatMode: chat,
    canEdit: canEdit,
    graph: ValueNotifier(WorkflowGraphFacts(nodes: nodes, hasUserInputNode: hasUserInputNode, checklist: checklist)),
    toast: (type, m) => toasts.add((type, m)),
    resetWorkflowVersionHistory: () => resets++,
  );

  Future<WorkflowStore> render(WidgetTester t, WorkflowHeaderData d, {void Function(WorkflowStore)? state}) =>
      renderWorkflowComponent(
        t,
        FeaturesTrigger(hooks: hooks()),
        data: d,
        initialStoreState: state,
      );

  AppPublisher publisher(WidgetTester t) => t.widget<AppPublisher>(find.byType(AppPublisher));

  group('FeaturesTrigger', () {
    group('Rendering', () {
      testWidgets('should not render the features button when not in chat mode', (t) async {
        await render(t, data());
        expect(find.text('workflow.common.features'), findsNothing);
      });

      testWidgets('should render the features button when in chat mode', (t) async {
        await render(t, data(chat: true));
        expect(find.text('workflow.common.features'), findsOneWidget);
      });

      testWidgets('should apply dark theme styling when theme is dark', (t) async {
        DifyColors.useDark(true);
        addTearDown(() => DifyColors.useDark(false));
        await render(t, data(chat: true));
        // `bg-white/10 inset-ring-black/5 backdrop-blur-xs` over the secondary button.
        final look = t
            .widget<DifyButtonSurface>(
              find.ancestor(of: find.text('workflow.common.features'), matching: find.byType(DifyButtonSurface)),
            )
            .look;
        expect(look.background, const Color(0x1AFFFFFF));
        expect(look.ring, const Color(0x0D000000));
        expect(look.blur, 4);
      });
    });

    group('User Interactions', () {
      testWidgets('should toggle features panel when clicked and nodes are editable', (t) async {
        final s = await render(t, data(chat: true));
        await t.tap(find.text('workflow.common.features'));
        expect(s.showFeaturesPanel.value, isTrue);
      });
    });

    group('Edge Cases', () {
      testWidgets('should not toggle features panel when nodes are read-only and not restoring', (t) async {
        final s = await render(t, data(chat: true, canEdit: false));
        await t.tap(find.text('workflow.common.features'));
        expect(s.showFeaturesPanel.value, isFalse);
      });
    });

    group('Props', () {
      testWidgets('should disable AppPublisher when there are no workflow nodes', (t) async {
        await render(t, data());
        expect(publisher(t).disabled, isTrue);
      });
    });

    group('Computed Props', () {
      testWidgets('should pass outputs from every end node to AppPublisher', (t) async {
        const aaa = {
          'variable': 'aaa',
          'value_type': 'string',
          'value_selector': ['source-1', 'value'],
        };
        const bbb = {
          'variable': 'bbb',
          'value_type': 'number',
          'value_selector': ['source-2', 'value'],
        };
        List<DifyJson>? outputs;
        await renderWorkflowComponent(
          t,
          FeaturesTrigger(hooks: hooks(), onConfigureWorkflowTool: (_, o) => outputs = o),
          data: data(
            nodes: const [
              HeaderNode(
                id: 'end-1',
                type: 'end',
                title: 'Success End',
                data: {
                  'outputs': [aaa],
                },
              ),
              HeaderNode(
                id: 'end-2',
                type: 'end',
                title: 'Fallback End',
                data: {
                  'outputs': [bbb],
                },
              ),
            ],
          ),
        );
        publisher(t).onConfigureWorkflowTool!();
        expect(outputs, [
          {
            ...aaa,
            'source': {'nodeId': 'end-1', 'nodeTitle': 'Success End', 'outputIndex': 0},
          },
          {
            ...bbb,
            'source': {'nodeId': 'end-2', 'nodeTitle': 'Fallback End', 'outputIndex': 0},
          },
        ]);
      });
    });

    group('Callbacks', () {
      testWidgets('should sync workflow draft when AppPublisher toggles on', (t) async {
        await render(t, data());
        publisher(t).onToggle!(true);
        expect(syncs, 1);
      });

      testWidgets('should not sync workflow draft when AppPublisher toggles off', (t) async {
        await render(t, data());
        publisher(t).onToggle!(false);
        expect(syncs, 0);
      });
    });

    group('Publishing', () {
      testWidgets('should wait for the draft save barrier before publishing', (t) async {
        final barrier = Completer<bool>();
        syncResult = () => barrier.future;
        await render(t, data());
        final done = publisher(t).onPublish!();
        await t.pump();
        expect(syncs, 1);
        expect(publishes, isEmpty);
        barrier.complete(true);
        await done;
        expect(publishes, hasLength(1));
      });

      testWidgets('should not publish when the draft save barrier fails', (t) async {
        syncResult = () async => false;
        await render(t, data());
        await expectLater(publisher(t).onPublish!(), throwsStateError);
        expect(syncs, 1);
        expect(publishes, isEmpty);
      });

      testWidgets('should notify error and reject publish when checklist has warning nodes', (t) async {
        await render(
          t,
          data(
            checklist: const [ChecklistItem(id: 'warning', type: 'code', title: 'W', canNavigate: true)],
          ),
        );
        await expectLater(publisher(t).onPublish!(), throwsStateError);
        expect(toasts, [(HeaderToastType.error, 'workflow.panel.checklistTip')]);
        expect(publishes, isEmpty);
      });

      testWidgets('should reject publish when checklist before publish fails', (t) async {
        checkResult = () async => false;
        await render(t, data());
        await expectLater(publisher(t).onPublish!(), throwsStateError);
        expect(checks, 1);
        expect(publishes, isEmpty);
      });

      testWidgets('should publish workflow and update related stores when validation passes', (t) async {
        final s = await render(
          t,
          data(
            nodes: const [HeaderNode(id: 'start', type: 'start')],
            hasUserInputNode: true,
          ),
        );
        await publisher(t).onPublish!();
        expect(publishes, [(title: '', releaseNotes: '')]);
        expect(refreshed, 1);
        expect(s.publishedAt.value, 1704067200 * 1000);
        expect(s.lastPublishedHasUserInput.value, isTrue);
        expect(resets, 1);
        expect(toasts, [(HeaderToastType.success, 'common.api.actionSuccess')]);
      });

      testWidgets('should not show a success toast when the publisher requests a silent publish', (t) async {
        final s = await render(t, data());
        await FeaturesTrigger.publish(store: s, data: data(), hooks: hooks(), showSuccessToast: false);
        expect(publishes, hasLength(1));
        expect(toasts, isEmpty);
      });

      testWidgets('should pass publish params to workflow publish mutation', (t) async {
        final s = await render(t, data());
        await FeaturesTrigger.publish(
          store: s,
          data: data(),
          hooks: hooks(),
          title: 'Release title',
          releaseNotes: 'Release notes',
        );
        expect(publishes, [(title: 'Release title', releaseNotes: 'Release notes')]);
      });

      testWidgets('should skip success side effects when publish mutation returns no workflow version', (t) async {
        publishResult = () async => null;
        final s = await render(t, data());
        await publisher(t).onPublish!();
        expect(publishes, hasLength(1));
        expect(refreshed, 0);
        expect(resets, 0);
        expect(s.publishedAt.value, 0);
        expect(toasts, isEmpty);
      });
    });
  });
}
