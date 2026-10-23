import 'dart:async';

import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/workflow_editor/run/debug_chat.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/server_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/unavailable_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends FakeWorkflowRunApi {
  var chatCalls = 0;
  @override
  Stream<Map<String, Object?>> chatDraftRun(String appId, Map<String, Object?> body) async* {
    chatCalls++;
    yield {
      'event': 'workflow_started',
      'workflow_run_id': 'run',
      'task_id': 'run',
      'conversation_id': 'conversation',
      'message_id': 'message',
      'data': {'id': 'run'},
    };
    yield {'event': 'message', 'conversation_id': 'conversation', 'message_id': 'message', 'answer': 'real'};
    yield {
      'event': 'workflow_finished',
      'workflow_run_id': 'run',
      'data': {'id': 'run', 'status': 'succeeded'},
    };
    yield {'event': 'message_end', 'message_id': 'message'};
  }

  @override
  Future<List<Map<String, Object?>>> chatMessages(String appId, String conversationId) async => [
    {
      'id': 'm1',
      'query': 'first',
      'answer': 'one',
      'parent_message_id': null,
      'inputs': {'topic': 'remembered', 'absent': null},
      'message_files': [
        {
          'related_id': 'file-record',
          'filename': 'restored.png',
          'mime_type': 'image/png',
          'type': 'image',
          'transfer_method': 'local_file',
          'size': 68,
          'url': 'https://example.test/preview',
        },
      ],
    },
    {'id': 'm2', 'query': 'next', 'answer': 'two', 'parent_message_id': 'm1'},
    {'id': 'm3', 'query': 'regenerate', 'answer': 'three', 'parent_message_id': 'm1'},
  ];
}

ServerRunService _service(_Api api, {bool chatflow = true, String scope = 'server:owner'}) => ServerRunService(
  runtime: ServerWorkflowRuntime(
    api: api,
    singleNodeRun: const {},
    draftRun: const {'start', 'answer'},
    chatflow: chatflow,
    conversationStorageScope: scope,
  ),
  appId: 'app',
  fallback: const UnavailableWorkflowRunService(),
  nodeTypeOf: (_) => 'answer',
  graphNodeTypes: () => ['start', 'answer'],
);

class _DelayedHistoryService extends ServerRunService {
  _DelayedHistoryService(_Api api)
    : super(
        runtime: ServerWorkflowRuntime(
          api: api,
          singleNodeRun: const {},
          draftRun: const {'start', 'answer'},
          chatflow: true,
        ),
        appId: 'app',
        fallback: const UnavailableWorkflowRunService(),
        nodeTypeOf: (_) => 'answer',
        graphNodeTypes: () => ['start', 'answer'],
      );
  final recalled = Completer<String?>();
  var historyReads = 0;
  @override
  Future<String?> recalledChatConversation() => recalled.future;
  @override
  Future<List<DifyJson>> fetchChatMessages(String conversationId) async {
    historyReads++;
    return [
      {'id': 'old', 'query': 'old history', 'answer': 'old answer'},
    ];
  }
}

void main() {
  test('chat file inputs retain the picker upload identity and restored file links', () {
    final input = {'type': 'image', 'transfer_method': 'local_file', 'upload_file_id': 'opaque-upload'};
    final values = getProcessedInputs(
      {
        'single': input,
        'multiple': [input],
      },
      [
        {'variable': 'single', 'type': 'file'},
        {'variable': 'multiple', 'type': 'file-list'},
      ],
    );
    expect((values['single'] as Map)['upload_file_id'], 'opaque-upload');
    expect(((values['multiple'] as List).single as Map)['upload_file_id'], 'opaque-upload');
    final restored = processInputFileFromServer({
      'type': 'image',
      'transfer_method': 'local_file',
      'related_id': 'stored-record',
      'url': 'https://example.test/preview',
    });
    expect(restored['upload_file_id'], 'stored-record');
    expect(restored['url'], 'https://example.test/preview');
    final frozen = {
      'dify_model_identity': '__dify__file__',
      'transfer_method': 'remote_url',
      'reference': 'opaque-frozen-reference',
      'related_id': 'stored-remote',
      'url': 'https://example.test/preview',
    };
    expect(processInputFileFromServer(frozen), frozen);
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  test('only the explicit durable chat capability sends to the server', () async {
    final api = _Api();
    await expectLater(
      _service(api, chatflow: false).sendChatMessage(ChatMessageRequest({'query': 'q', 'inputs': {}})),
      emitsError(isA<RunServiceException>()),
    );
    expect(api.chatCalls, 0);
    final events = await _service(api).sendChatMessage(ChatMessageRequest({'query': 'q', 'inputs': {}})).toList();
    expect(events.map((e) => e.event), ['workflow_started', 'message', 'workflow_finished', 'message_end']);
    expect(api.chatCalls, 1);
  });
  test('remembered conversation is isolated by server, account and app', () async {
    final api = _Api();
    final service = _service(api);
    await service.rememberChatConversation('conversation');
    expect(await _service(api).recalledChatConversation(), 'conversation');
    expect(await _service(api, scope: 'server:other').recalledChatConversation(), isNull);
    expect(await _service(api, scope: 'other-server:owner').recalledChatConversation(), isNull);
    await service.rememberChatConversation('');
    expect(await service.recalledChatConversation(), '');
  });
  test('a new controller rebuilds the durable message branch tree', () async {
    final service = _service(_Api());
    await service.rememberChatConversation('conversation');
    final store = WorkflowStore();
    final run = WorkflowRunController(store: store, service: service, graph: const StaticRunGraph());
    final chat = DebugChatController(run: run, service: service, store: store, toast: (_, _) {});
    await Future<void>.delayed(Duration.zero);
    expect(chat.conversationId, 'conversation');
    expect(store.inputs.value, {'topic': 'remembered'});
    expect(chat.chatTree, hasLength(1));
    final restoredFile = (chat.chatTree.first['message_files'] as List).single as Map;
    expect(restoredFile['name'], 'restored.png');
    expect(restoredFile['uploadedId'], 'file-record');
    expect(restoredFile['url'], 'https://example.test/preview');
    final rootAnswer = (chat.chatTree.first['children'] as List).first as Map;
    expect(rootAnswer['id'], 'm1');
    expect(rootAnswer['children'], hasLength(2));
    expect(chat.threadMessages.where((m) => m['isAnswer'] == true).map((m) => m['content']), ['one', 'three']);
    chat.dispose();
    run.dispose();
    store.dispose();
  });
  test('a pending history lookup cannot replace a turn the user already sent', () async {
    final service = _DelayedHistoryService(_Api());
    final store = WorkflowStore();
    const graph = StaticRunGraph(
      nodes: [
        RunGraphNode(id: 'start', type: 'start'),
        RunGraphNode(id: 'answer', type: 'answer'),
      ],
    );
    final run = WorkflowRunController(store: store, service: service, graph: graph, isChatMode: () => true);
    final chat = DebugChatController(run: run, service: service, store: store, toast: (_, _) {});
    expect(chat.handleSend({'query': 'fresh message', 'inputs': <String, Object?>{}}), isTrue);
    await Future<void>.delayed(Duration.zero);
    service.recalled.complete('old-conversation');
    await Future<void>.delayed(Duration.zero);
    expect(service.historyReads, 0);
    expect(chat.chatTree.first['content'], 'fresh message');
    expect(chat.conversationId, isNot('old-conversation'));
    chat.dispose();
    run.dispose();
    store.dispose();
  });
}
