import 'dart:async';

import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/workflow_editor/run/debug_chat.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_stream.dart';
import 'package:dify_sf_app/src/workflow_editor/run/server_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/unavailable_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_spec/dify_test_i18n.dart';

const conversation = 'a88b0c84-4146-4e83-b51d-bcbf37379fc5';
const accepted = '637b0cf1-a428-43c3-ae49-d395036859ab';

class _Service extends MockWorkflowRunService {
  _Service() : super(graph: () => const StaticRunGraph());
  var draftRequests = 0;
  @override
  Stream<RunEvent> runWorkflowDraft(WorkflowDraftRunRequest request) async* {
    draftRequests++;
  }
}

class _Run extends WorkflowRunController {
  _Run(WorkflowStore store, WorkflowRunService service, {super.toast})
    : super(store: store, service: service, graph: const StaticRunGraph());
  final requests = <DifyJson>[];
  bool accept = false;

  @override
  Future<void> handleRun(DifyJson? params, {RunCallbacks? callback, HandleRunOptions? options}) async {
    requests.add(params!);
    if (accept) {
      callback?.onData?.call('ok', true, (
        event: 'message',
        conversationId: conversation,
        taskId: 'run',
        messageId: accepted,
        errorMessage: null,
        errorCode: null,
      ));
    }
    callback?.onCompleted?.call(!accept, accept ? null : 'Node configuration is incomplete');
  }
}

void main() {
  setUp(useDifyTestTranslator);

  test('a rejected first turn cannot send a local answer ID as its next parent', () async {
    final store = WorkflowStore();
    final service = _Service();
    final run = _Run(store, service);
    final chat = DebugChatController(run: run, service: service, store: store);
    addTearDown(chat.dispose);
    expect(chat.handleSend({'query': 'first', 'inputs': <String, Object?>{}}), isTrue);
    final failed = chat.chatList.last;
    expect('${failed['id']}', startsWith('answer-placeholder-'));
    expect(
      chat.handleSend({'query': 'retry', 'inputs': <String, Object?>{}, 'parent_message_id': failed['id']}),
      isTrue,
    );
    expect(run.requests.last['parent_message_id'], isNull);
    expect(chat.isResponding, isFalse);
  });

  test('a rejected follow-up retains the last accepted parent and regenerate can branch from it', () async {
    final store = WorkflowStore();
    final service = _Service();
    final run = _Run(store, service)..accept = true;
    final chat = DebugChatController(run: run, service: service, store: store);
    addTearDown(chat.dispose);
    chat.handleSend({'query': 'first', 'inputs': <String, Object?>{}});
    run.accept = false;
    chat.handleSend({'query': 'bad follow-up', 'inputs': <String, Object?>{}, 'parent_message_id': accepted});
    final failed = chat.chatList.last;
    chat.handleSend({'query': 'fixed follow-up', 'inputs': <String, Object?>{}, 'parent_message_id': failed['id']});
    expect(run.requests.last['parent_message_id'], accepted);
    expect(chat.conversationId, conversation);
    run.accept = true;
    chat.handleSend({'query': 'regenerate', 'inputs': <String, Object?>{}, 'parent_message_id': accepted});
    expect(run.requests.last['parent_message_id'], accepted);
  });

  test('chat validation reports the named node before adding a phantom turn or sending a request', () async {
    final store = WorkflowStore();
    store.checklistItems.value = [
      {
        'id': 'agent',
        'title': 'Research agent',
        'type': 'agent',
        'canNavigate': true,
        'errorMessages': ['Select an agent strategy'],
        'unConnected': true,
      },
    ];
    final service = _Service();
    final messages = <String>[];
    final run = _Run(store, service, toast: (_, text) => messages.add(text));
    final chat = DebugChatController(run: run, service: service, store: store);
    addTearDown(chat.dispose);
    expect(chat.handleSend({'query': 'Hi', 'inputs': <String, Object?>{}}), isFalse);
    expect(run.requests, isEmpty);
    expect(chat.chatList, isEmpty);
    expect(messages.single, contains('Research agent'));
    expect(messages.single, contains('Select an agent strategy'));
    store.checklistItems.value = [];
    expect(chat.handleSend({'query': 'Hi', 'inputs': <String, Object?>{}}), isTrue);
  });

  test('workflow validation also refuses an invalid graph before creating running state', () async {
    final store = WorkflowStore();
    store.checklistItems.value = [
      {
        'id': 'llm',
        'title': 'Draft writer',
        'canNavigate': true,
        'errorMessages': ['Choose a model'],
      },
    ];
    final service = _Service();
    final messages = <String>[];
    final run = WorkflowRunController(
      store: store,
      service: service,
      graph: const StaticRunGraph(),
      toast: (_, message) => messages.add(message),
    );
    await run.handleRun({'inputs': <String, Object?>{}});
    await Future<void>.delayed(Duration.zero);
    expect(service.draftRequests, 0);
    expect(store.workflowRunningData.value, isNull);
    expect(messages.single, contains('Draft writer'));
  });

  test('run validation reads the current graph even while the displayed checklist is stale', () async {
    final store = WorkflowStore();
    final oldIssue = <String, Object?>{'id': 'llm', 'title': 'Draft writer', 'canNavigate': true,
      'errorMessages': ['Choose a model']};
    store.checklistItems.value = [oldIssue];
    var current = <DifyJson>[];
    store.computeRunChecklist = () => current;
    final service = _Service();
    final run = _Run(store, service, toast: (_, _) {});
    final chat = DebugChatController(run: run, service: service, store: store);
    addTearDown(chat.dispose);
    // The node was fixed, but the displayed snapshot still contains its old error.
    expect(chat.handleSend({'query': 'fixed now', 'inputs': <String, Object?>{}}), isTrue);
    expect(run.requests, hasLength(1));
    // Conversely a newly broken node must be caught before the displayed snapshot catches up.
    current = [oldIssue];
    store.checklistItems.value = [];
    expect(chat.handleSend({'query': 'broken now', 'inputs': <String, Object?>{}}), isFalse);
    expect(run.requests, hasLength(1));
  });

  test('unsupported graph types are named instead of claiming Chatflow is unavailable', () async {
    final service = ServerRunService(
      runtime: ServerWorkflowRuntime(
        api: FakeWorkflowRunApi(),
        singleNodeRun: const {},
        draftRun: const {'start', 'answer'},
        chatflow: true,
      ),
      appId: 'app',
      fallback: const UnavailableWorkflowRunService(),
      nodeTypeOf: (_) => 'agent',
      graphNodeTypes: () => ['start', 'agent', 'answer'],
    );
    await expectLater(
      service.sendChatMessage(const ChatMessageRequest({'query': 'Hi'})).toList(),
      throwsA(isA<RunServiceException>().having((e) => e.message, 'specific type', contains('agent'))),
    );
  });
}
