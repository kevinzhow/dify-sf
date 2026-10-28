import 'dart:async';

import 'package:dify_sf_app/src/agents/canvas_progress.dart';
import 'package:dify_sf_app/src/agents/progress_image.dart';
import 'package:dify_sf_app/src/canvas/run_view.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_events.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_observation.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> event(String name, Map<String, Object?> data) => {'event': name, 'data': data};
Map<String, Object?> entry(int cursor, String kind, Map<String, Object?> data) => {
  'node_id': 'agent',
  'message_id': 'operation:$cursor',
  'label': kind,
  'status': 'success',
  'metadata': {'event': kind},
  'data': data,
};
void snapshot(StreamController<RunEvent> stream, {String run = 'run'}) {
  stream.add(
    RunEvent.fromJson({
      'event': 'workflow_started',
      'workflow_run_id': run,
      'task_id': run,
      'data': {'id': run},
    }),
  );
  stream.add(
    RunEvent.fromJson(
      event('node_started', {'id': 'execution', 'node_id': 'agent', 'node_type': 'agent', 'title': 'Render agent'}),
    ),
  );
  stream.add(RunEvent.fromJson(event('agent_log', entry(1, 'run_started', {'max_turns': 200}))));
  stream.add(RunEvent.fromJson(event('agent_log', entry(2, 'model_call', {'call_index': 65}))));
}

void main() {
  setUpAll(() => DifyI18n.load('en-US'));
  test('late viewer hydrates the running Agent and reconnect does not double count', () async {
    final store = WorkflowStore();
    final streams = <StreamController<RunEvent>>[];
    final reads = <String>[];
    final observation = WorkflowRunObservation(
      store: store,
      service: ReadOnlyRunService((id) {
        reads.add(id);
        final stream = StreamController<RunEvent>();
        streams.add(stream);
        return stream.stream;
      }),
    );
    observation.follow('run');
    snapshot(streams.single);
    await Future<void>.delayed(Duration.zero);
    expect(NodeRunView.fromRunData(store.nodeRunDataOf('agent')).agentProgress?.calls, 65);
    await streams.single.close();
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(reads, ['run', 'run']);
    snapshot(streams.last);
    await Future<void>.delayed(Duration.zero);
    expect((store.workflowRunningData.value!['tracing'] as List), hasLength(1));
    expect(NodeRunView.fromRunData(store.nodeRunDataOf('agent')).agentProgress?.calls, 65);
    observation.dispose();
    expect(streams.last.hasListener, isFalse);
    store.dispose();
    await streams.last.close();
  });
  test('refused observer read does not mark the underlying run failed', () async {
    final store = WorkflowStore()
      ..workflowRunningData.value = {
        'result': {'status': 'running'},
      };
    final stream = StreamController<RunEvent>();
    final observation = WorkflowRunObservation(store: store, service: ReadOnlyRunService((_) => stream.stream));
    observation.follow('run');
    stream.add(RunEvent.fromJson(event('error', {'message': 'Forbidden', 'code': 'forbidden'})));
    await Future<void>.delayed(Duration.zero);
    expect((store.workflowRunningData.value!['result'] as Map)['status'], isNot('failed'));
    observation.dispose();
    store.dispose();
    await stream.close();
  });
  for (final width in [390.0, 300.0]) {
    testWidgets(
      'already-running record on ${width.toInt()}px follows progress and projects selected history to the canvas',
      (t) async {
        await t.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => t.binding.setSurfaceSize(null));
        final parent = WorkflowStore()..historyWorkflowData.value = {'id': 'run'};
        final stream = StreamController<RunEvent>();
        var reads = 0, tracingReads = 0;
        await t.pumpWidget(
          MaterialApp(
            home: WorkflowStoreScope(
              store: parent,
              child: RunPanel(
                runId: 'run',
                activeTab: RunPanelTabType.tracing,
                fetchRunDetail: (_) async => {'id': 'run', 'status': 'running', 'created_at': 1},
                fetchTracingList: (_) async {
                  tracingReads++;
                  return [];
                },
                observeService: ReadOnlyRunService((_) {
                  reads++;
                  return stream.stream;
                }),
              ),
            ),
          ),
        );
        await t.pump();
        expect(reads, 1);
        snapshot(stream);
        await t.pump();
        expect(find.text('RENDER AGENT'), findsOneWidget);
        await t.tap(find.text('Agent activity').first);
        await t.pump();
        expect(find.byType(AgentCanvasProgress), findsOneWidget);
        expect(find.text('Model calls 65 / 200'), findsOneWidget);
        expect(NodeRunView.fromRunData(parent.nodeRunDataOf('agent')).agentProgress?.calls, 65);
        expect(tracingReads, 1); // Switching to the live tab must not overwrite SSE with stale REST.
        stream.add(
          RunEvent.fromJson(
            event(
              'agent_log',
              entry(3, 'progress', {
                'caption': 'First comparison',
                'file_unavailable': true,
              }),
            ),
          ),
        );
        await t.pump();
        expect(find.byType(AgentProgressImage), findsOneWidget);
        expect(find.text('First comparison'), findsOneWidget);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox.shrink());
        expect(stream.hasListener, isFalse);
        expect(parent.nodeRunData.value, isEmpty);
        unawaited(stream.close());
        parent.dispose();
      },
    );
  }
  testWidgets('switching records cancels only the old observer and ignores a late old snapshot', (t) async {
    final parent = WorkflowStore();
    final streams = <String, StreamController<RunEvent>>{};
    final fetches = <String, Completer<Map<String, Object?>>>{};
    Widget view(String id) => MaterialApp(
      home: WorkflowStoreScope(
        store: parent,
        child: RunPanel(
          runId: id,
          fetchRunDetail: (id) => (fetches[id] ??= Completer()).future,
          fetchTracingList: (_) async => [],
          observeService: ReadOnlyRunService((id) => (streams[id] = StreamController<RunEvent>()).stream),
        ),
      ),
    );
    await t.pumpWidget(view('first'));
    await t.pumpWidget(view('second'));
    fetches['first']!.complete({'id': 'first', 'status': 'running'});
    await t.pump();
    expect(streams.containsKey('first'), isFalse);
    fetches['second']!.complete({'id': 'second', 'status': 'running'});
    await t.pump();
    expect(streams.containsKey('second'), isTrue);
    await t.pumpWidget(const SizedBox.shrink());
    expect(streams['second']!.hasListener, isFalse);
    unawaited(streams['second']!.close());
    parent.dispose();
  });
  testWidgets(
    'closing history restores the canvas while other editor listeners stay mounted',
    (t) async {
      final parent = WorkflowStore()..historyWorkflowData.value = {'id': 'run'};
      final visible = ValueNotifier(true);
      final stream = StreamController<RunEvent>();
      await t.pumpWidget(
        MaterialApp(
          home: WorkflowStoreScope(
            store: parent,
            child: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, show, _) => Column(
                children: [
                  if (show)
                    Expanded(
                      child: RunPanel(
                        runId: 'run',
                        fetchRunDetail: (_) async => {
                          'id': 'run',
                          'status': 'running',
                        },
                        fetchTracingList: (_) async => [],
                        observeService: ReadOnlyRunService(
                          (_) => stream.stream,
                        ),
                      ),
                    ),
                  ValueListenableBuilder(
                    valueListenable: parent.workflowRunningData,
                    builder: (_, data, _) => Text(
                      data == null ? 'Original canvas' : 'History canvas',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pump();
      snapshot(stream);
      await t.pump();
      expect(find.text('History canvas'), findsOneWidget);
      visible.value = false;
      await t.pump();
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.text('Original canvas'), findsOneWidget);
      expect(parent.nodeRunData.value, isEmpty);
      expect(stream.hasListener, isFalse);
      await t.pumpWidget(const SizedBox());
      unawaited(stream.close());
      visible.dispose();
      parent.dispose();
    },
  );
}
