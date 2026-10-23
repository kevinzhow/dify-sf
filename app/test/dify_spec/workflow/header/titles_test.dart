// dify-spec: web/app/components/workflow/header/__tests__/restoring-title.spec.tsx
// dify-spec: web/app/components/workflow/header/__tests__/running-title.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/header/format.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/header/titles.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

DifyJson createVersion([DifyJson overrides = const {}]) => {
  'id': 'version-1',
  'graph': {'nodes': [], 'edges': []},
  'created_at': 1700000000,
  'created_by': {'id': 'user-1', 'name': 'Alice', 'email': 'alice@example.com'},
  'hash': 'hash-1',
  'updated_at': 1700000100,
  'updated_by': {'id': 'user-2', 'name': 'Bob', 'email': 'bob@example.com'},
  'tool_published': false,
  'version': 'v1',
  'marked_name': 'Release 1',
  'marked_comment': '',
  ...overrides,
};

void main() {
  group('RestoringTitle', () {
    late List<List<Object?>> formatTimeCalls, fromNowCalls;
    WorkflowHeaderData data() {
      formatTimeCalls = [];
      fromNowCalls = [];
      return WorkflowHeaderData(
        formatters: HeaderFormatters(
          formatTime: (s, f) {
            formatTimeCalls.add([s, f]);
            return '09:30:00';
          },
          formatTimeFromNow: (ms) {
            fromNowCalls.add([ms]);
            return '3 hours ago';
          },
        ),
      );
    }

    testWidgets('should render draft metadata when the current version is a draft', (t) async {
      final v = createVersion({'version': 'draft'});
      await renderWorkflowComponent(
        t,
        const RestoringTitle(),
        data: data(),
        initialStoreState: (s) => s.setCurrentVersion(v),
      );
      expect(fromNowCalls, [
        [1700000100 * 1000],
      ]);
      expect(formatTimeCalls, [
        [1700000000, 'HH:mm:ss'],
      ]);
      final text = textContent(t);
      expect(text, contains('workflow.versionHistory.currentDraft'));
      expect(text, contains('WORKFLOW.COMMON.VIEWONLY'));
      expect(text, contains('workflow.common.unpublished'));
      expect(text, contains('3 hours ago 09:30:00'));
      expect(text, contains('Alice'));
    });

    testWidgets('should render published metadata and fallback version name when the marked name is empty', (t) async {
      final v = createVersion({'marked_name': ''});
      await renderWorkflowComponent(
        t,
        const RestoringTitle(),
        data: data(),
        initialStoreState: (s) => s.setCurrentVersion(v),
      );
      expect(fromNowCalls, [
        [1700000000 * 1000],
      ]);
      final text = textContent(t);
      expect(text, contains('workflow.versionHistory.defaultName'));
      expect(text, contains('workflow.common.published'));
      expect(text, contains('Alice'));
    });

    testWidgets('should render the version number when the marked name is empty', (t) async {
      final v = createVersion({'marked_name': '', 'version_number': 5});
      await renderWorkflowComponent(
        t,
        const RestoringTitle(),
        data: data(),
        initialStoreState: (s) => s.setCurrentVersion(v),
      );
      final text = textContent(t);
      expect(text, contains('# 5'));
      expect(text, isNot(contains('workflow.versionHistory.defaultName')));
    });

    testWidgets('should render an empty creator name when the version creator name is missing', (t) async {
      final v = createVersion({
        'created_by': {'id': 'user-1', 'name': '', 'email': 'alice@example.com'},
      });
      await renderWorkflowComponent(
        t,
        const RestoringTitle(),
        data: data(),
        initialStoreState: (s) => s.setCurrentVersion(v),
      );
      final text = textContent(t);
      expect(text, contains('workflow.common.published'));
      expect(text, isNot(contains('Alice')));
    });
  });

  group('RunningTitle', () {
    late List<int?> calls;
    WorkflowHeaderData data({bool chat = false}) {
      calls = [];
      return WorkflowHeaderData(
        isChatMode: chat,
        formatters: HeaderFormatters(
          formatWorkflowRunIdentifier: (finishedAt, [_ = 'Running']) {
            calls.add(finishedAt);
            return ' (14:30:25)';
          },
        ),
      );
    }

    testWidgets('should render the test run title in workflow mode', (t) async {
      await renderWorkflowComponent(
        t,
        const RunningTitle(),
        data: data(),
        initialStoreState: (s) =>
            s.setHistoryWorkflowData({'id': 'history-1', 'status': 'succeeded', 'finished_at': 1700000000}),
      );
      expect(calls, [1700000000]);
      expect(textContent(t), contains('Test Run (14:30:25)'));
      expect(textContent(t), contains('WORKFLOW.COMMON.VIEWONLY'));
    });

    testWidgets('should render the test chat title in chat mode', (t) async {
      await renderWorkflowComponent(
        t,
        const RunningTitle(),
        data: data(chat: true),
        initialStoreState: (s) => s.setHistoryWorkflowData({'id': 'history-2', 'status': 'running'}),
      );
      expect(calls, [null]);
      expect(textContent(t), contains('Test Chat (14:30:25)'));
    });

    testWidgets('should handle missing workflow history data', (t) async {
      await renderWorkflowComponent(t, const RunningTitle(), data: data());
      expect(calls, [null]);
      expect(textContent(t), contains('Test Run (14:30:25)'));
    });
  });
}
