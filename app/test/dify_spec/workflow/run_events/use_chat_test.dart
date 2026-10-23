// dify-spec: web/app/components/workflow/panel/debug-and-preview/__tests__/hooks.spec.ts
// dify-spec: web/app/components/workflow/panel/debug-and-preview/__tests__/hooks/handle-send.spec.ts
// dify-spec: web/app/components/workflow/panel/debug-and-preview/__tests__/hooks/handle-stop-restart.spec.ts
// dify-spec: web/app/components/workflow/panel/debug-and-preview/__tests__/hooks/misc.spec.ts
// dify-spec: web/app/components/workflow/panel/debug-and-preview/__tests__/hooks/opening-statement.spec.ts
// dify-spec: web/app/components/workflow/panel/debug-and-preview/__tests__/hooks/sse-callbacks.spec.ts
// dify-spec: web/app/components/workflow/panel/debug-and-preview/__tests__/hooks/handle-resume.spec.ts
// Dify's mocks: `handleRun` (the run controller's, recorded), `sseGet` (the resume stream, recorded), the store
// (`workflowRunningData`, iter / loop times), `submitHumanInputForm` (the service), `fetchInspectVars`,
// `invalidAllLastRun`, `toast.info`.
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/run/debug_chat.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_events.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_stream.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';

class _Service extends MockWorkflowRunService {
  _Service() : super(graph: () => const StaticRunGraph());
  final submits = <(String, DifyJson)>[];
  @override
  Future<void> submitHumanInputForm(String formToken, DifyJson data) async => submits.add((formToken, data));
}

/// The run controller with `handleRun` mocked.
class _Run extends WorkflowRunController {
  _Run(WorkflowStore store, _Service service) : super(store: store, service: service, graph: const StaticRunGraph());
  final calls = <({DifyJson? params, RunCallbacks callbacks})>[];
  void Function(DifyJson? params, RunCallbacks callbacks)? impl;
  var invalidated = 0;

  @override
  Future<void> handleRun(DifyJson? params, {RunCallbacks? callback, HandleRunOptions? options}) async {
    calls.add((params: params, callbacks: callback!));
    impl?.call(params, callback);
  }

  @override
  void invalidAllLastRun() => invalidated++;
}

/// `{ abort: vi.fn() }`.
class _Abort extends RunStreamHandle {
  var count = 0;
  @override
  void abort() {
    count++;
    super.abort();
  }
}

RunDataInfo _info({String? conversationId, String? messageId, String? taskId}) => (
  event: 'message',
  conversationId: conversationId,
  taskId: taskId,
  messageId: messageId,
  errorMessage: null,
  errorCode: null,
);

class _Rig {
  _Rig() {
    run = _Run(store, service);
  }

  final store = WorkflowStore();
  final service = _Service();
  late final _Run run;
  var fetchInspectVars = 0;
  final toasts = <(DifyToastType, String)>[];
  final resumes = <(String, RunCallbacks)>[];
  RunStreamHandle Function(String id, RunCallbacks cb)? resumeImpl;
  var canRun = true;
  final stopped = <String>[];
  List<RunGraphNode> nodes = const [];

  DebugChatController chat([
    DifyJson? config,
    ChatFormSettings? formSettings,
    List<DifyJson>? prevChatTree,
    bool withStopChat = false,
  ]) => DebugChatController(
    run: run,
    service: service,
    store: store,
    config: config,
    formSettings: formSettings,
    prevChatTree: prevChatTree,
    stopChat: withStopChat ? stopped.add : null,
    graph: StaticRunGraph(nodes: nodes),
    canRun: () => canRun,
    fetchInspectVars: () => fetchInspectVars++,
    toast: (type, m) => toasts.add((type, m)),
    resumeStream: (id, cb) {
      resumes.add((id, cb));
      return resumeImpl?.call(id, cb) ?? RunStreamHandle();
    },
  );

  RunCallbacks get cb => run.calls.last.callbacks;
  RunCallbacks get resumed => resumes.last.$2;
}

DifyJson? _answer(DebugChatController c) =>
    c.chatList.where((i) => i['isAnswer'] == true && i['isOpeningStatement'] != true).firstOrNull;
DifyJson? _byId(DebugChatController c, String id) => c.chatList.where((i) => i['id'] == id).firstOrNull;
DifyJson _process(DifyJson? item) => (item!['workflowProcess'] as Map).cast<String, Object?>();
List<Map> _tracing(DifyJson? item) => ((_process(item)['tracing'] as List?) ?? const []).cast<Map>();
List<Map> _list(DifyJson? item, String key) => ((item![key] as List?) ?? const []).cast<Map>();

WorkflowStartedEvent _started({
  String runId = 'wfr-1',
  String taskId = 'task-1',
  String? conversationId,
  String? messageId,
}) => WorkflowStartedEvent({
  'workflow_run_id': runId,
  'task_id': taskId,
  'conversation_id': conversationId,
  'message_id': messageId,
});

void main() {
  setUp(useDifyTestTranslator);
  tearDown(() => DifyI18n.current = KeyEchoTranslator());

  group('useChat – handleSend', () {
    test('should call handleRun with processed params', () {
      final r = _Rig();
      r.chat({}).handleSend({'query': 'hello', 'inputs': <String, Object?>{}});
      expect(r.run.calls, hasLength(1));
      expect(r.run.calls.single.params!['query'], 'hello');
    });

    test('should return false and skip handleRun when test/run permission is missing', () {
      final r = _Rig()..canRun = false;
      final c = r.chat({});
      expect(c.handleSend({'query': 'hello', 'inputs': <String, Object?>{}}), isFalse);
      expect(r.run.calls, isEmpty);
      expect(c.chatList, isEmpty);
    });

    test('should show notification and return false when already responding', () {
      final r = _Rig();
      final c = r.chat({});
      c.handleSend({'query': 'first'});
      expect(c.handleSend({'query': 'second'}), isFalse);
      expect(r.toasts.single.$2, 'app-debug.errorMessage.waitForResponse');
    });

    test('should set isResponding to true after sending', () {
      final c = _Rig().chat({})..handleSend({'query': 'hello'});
      expect(c.isResponding, isTrue);
    });

    test('should add placeholder question and answer to chatList', () {
      final c = _Rig().chat({})..handleSend({'query': 'test question'});
      final question = c.chatList.where((i) => i['content'] == 'test question').firstOrNull;
      expect(question, isNotNull);
      expect(question!['isAnswer'], false);
      expect(
        c.chatList.where((i) => i['isAnswer'] == true && i['isOpeningStatement'] != true && i['content'] == ''),
        isNotEmpty,
      );
    });

    test('should strip url from local_file transfer method files', () {
      final r = _Rig();
      r.chat({}).handleSend({
        'query': 'hello',
        'files': [
          {
            'id': 'f1',
            'name': 'test.png',
            'size': 1024,
            'type': 'image/png',
            'progress': 100,
            'transferMethod': 'local_file',
            'supportFileType': 'image',
            'url': 'blob://local',
            'uploadedId': 'up1',
          },
          {
            'id': 'f2',
            'name': 'remote.png',
            'size': 2048,
            'type': 'image/png',
            'progress': 100,
            'transferMethod': 'remote_url',
            'supportFileType': 'image',
            'url': 'https://example.com/img.png',
            'uploadedId': '',
          },
        ],
      });
      final files = (r.run.calls.single.params!['files'] as List).cast<Map>();
      expect(files.firstWhere((f) => f['transfer_method'] == 'local_file')['url'], '');
      expect(files.firstWhere((f) => f['transfer_method'] == 'remote_url')['url'], 'https://example.com/img.png');
    });

    test('should abort previous workflowEventsAbortController before sending', () {
      final r = _Rig();
      final first = _Abort();
      r.run.impl = (_, cb) {
        cb.getAbortController!(first);
        cb.onCompleted!(false);
      };
      final c = r.chat({})..handleSend({'query': 'first'});
      r.run.impl = (_, cb) => cb.getAbortController!(_Abort());
      c.handleSend({'query': 'second'});
      expect(first.count, 1);
    });
  });

  group('useChat – handleStop', () {
    test('should set isResponding to false', () {
      final c = _Rig().chat({})..handleStop();
      expect(c.isResponding, isFalse);
    });

    test('should not call stopChat when taskId is empty even if stopChat is provided', () {
      final r = _Rig();
      r.chat({}, null, null, true).handleStop();
      expect(r.stopped, isEmpty);
    });

    test('should reset iter/loop times to defaults', () {
      final r = _Rig();
      r.store
        ..setIterTimes(5)
        ..setLoopTimes(5);
      r.chat({}).handleStop();
      expect(r.store.iterTimes.value, 1);
      expect(r.store.loopTimes.value, 1);
    });

    test('should abort workflowEventsAbortController when set', () {
      final r = _Rig();
      final abort = _Abort();
      r.run.impl = (_, cb) => cb.getAbortController!(abort);
      r.chat({})
        ..handleSend({'query': 'test'})
        ..handleStop();
      expect(abort.count, 1);
    });

    test('should abort suggestedQuestionsAbortController when set', () async {
      final r = _Rig();
      var sqAborts = 0;
      final c = r.chat({
        'suggested_questions_after_answer': {'enabled': true},
      });
      c.handleSend(
        {'query': 'test'},
        onGetSuggestedQuestions: (id, getAbort) {
          getAbort(() => sqAborts++);
          return Future.value(['s']);
        },
      );
      r.cb.onCompleted!(false);
      await pumpEventQueue();
      c.handleStop();
      expect(sqAborts, 1);
    });

    test('should call stopChat with taskId when both are available', () {
      final r = _Rig();
      r.run.impl = (_, cb) =>
          cb.onData!('msg', true, _info(conversationId: 'c1', messageId: 'msg-1', taskId: 'task-stop'));
      r.chat({}, null, null, true)
        ..handleSend({'query': 'test'})
        ..handleStop();
      expect(r.stopped, ['task-stop']);
    });
  });

  group('useChat – handleRestart', () {
    test('should clear suggestedQuestions and set isResponding to false', () {
      final c = _Rig().chat({'opening_statement': 'Hello'})..handleRestart();
      expect(c.suggestedQuestions, isEmpty);
      expect(c.isResponding, isFalse);
    });

    test('restart stops the accepted task before clearing its id', () {
      final r = _Rig();
      r.run.impl = (_, cb) =>
          cb.onData!('msg', true, _info(conversationId: 'c1', messageId: 'm1', taskId: 'task-restart'));
      r.chat({}, null, null, true)
        ..handleSend({'query': 'test'})
        ..handleRestart();
      expect(r.stopped, ['task-restart']);
    });

    test('should reset iter/loop times to defaults', () {
      final r = _Rig();
      r.store
        ..setIterTimes(3)
        ..setLoopTimes(3);
      r.chat({}).handleRestart();
      expect(r.store.iterTimes.value, 1);
      expect(r.store.loopTimes.value, 1);
    });
  });

  group('useChat – handleSwitchSibling', () {
    test('should call handleResume when target has workflow_run_id and pending humanInputFormData', () async {
      final r = _Rig();
      final c = r.chat({})..handleSend({'query': 'test'});
      r.cb.onWorkflowStarted!(_started(runId: 'wfr-switch', messageId: 'msg-switch'));
      r.cb.onHumanInputRequired!(
        const HumanInputRequiredEvent({
          'data': {'node_id': 'human-n', 'form_token': 'ft-1'},
        }),
      );
      r.cb.onCompleted!(false);
      await pumpEventQueue();
      c.handleSwitchSibling('msg-switch');
      expect(r.resumes, isNotEmpty);
    });

    test('should not call handleResume when target has no humanInputFormDataList', () async {
      final r = _Rig();
      final c = r.chat({})..handleSend({'query': 'test'});
      r.cb.onWorkflowStarted!(_started(runId: 'wfr-switch', messageId: 'msg-switch'));
      r.cb.onCompleted!(false);
      await pumpEventQueue();
      c.handleSwitchSibling('msg-switch');
      expect(r.resumes, isEmpty);
    });

    test('should return undefined from findMessageInTree when not found', () {
      final r = _Rig();
      r.chat({}).handleSwitchSibling('nonexistent-id');
      expect(r.resumes, isEmpty);
    });

    test('should search children recursively in findMessageInTree', () async {
      final r = _Rig();
      final c = r.chat({})..handleSend({'query': 'parent'});
      r.cb.onWorkflowStarted!(_started(messageId: 'msg-parent'));
      r.cb.onCompleted!(false);
      await pumpEventQueue();
      c.handleSend({'query': 'child', 'parent_message_id': 'msg-parent'});
      r.cb.onWorkflowStarted!(_started(runId: 'wfr-2', taskId: 'task-2', messageId: 'msg-child'));
      r.cb.onHumanInputRequired!(
        const HumanInputRequiredEvent({
          'data': {'node_id': 'h-child', 'form_token': 'ft-c'},
        }),
      );
      r.cb.onCompleted!(false);
      await pumpEventQueue();
      c.handleSwitchSibling('msg-child');
      expect(r.resumes, isNotEmpty);
    });
  });

  group('useChat – handleSubmitHumanInputForm', () {
    test('should call submitHumanInputForm with token and data', () async {
      final r = _Rig();
      await r.chat({}).handleSubmitHumanInputForm('token-123', {
        'inputs': {'field': 'value'},
        'action': 'approve',
      });
      expect(r.service.submits.single.$1, 'token-123');
      expect(r.service.submits.single.$2, {
        'inputs': {'field': 'value'},
        'action': 'approve',
      });
    });
  });

  group('useChat – getHumanInputNodeData', () {
    test('should return the custom node matching the given nodeID', () {
      final r = _Rig()
        ..nodes = const [
          RunGraphNode(id: 'node-1', type: 'human-input', title: 'Human Input'),
          RunGraphNode(id: 'node-2', type: 'human-input', title: 'Other'),
        ];
      final node = r.chat({}).getHumanInputNodeData('node-1');
      expect(node?.id, 'node-1');
      expect(node?.title, 'Human Input');
    });

    test('should return undefined when no matching node', () {
      final r = _Rig()..nodes = const [RunGraphNode(id: 'node-2', type: 'human-input')];
      expect(r.chat({}).getHumanInputNodeData('nonexistent'), isNull);
    });

    test('should filter out non-custom nodes', () {
      final r = _Rig()
        ..nodes = const [
          RunGraphNode(id: 'node-1', type: '', rfType: 'default'),
          RunGraphNode(id: 'node-1', type: 'human-input', data: {'found': true}),
        ];
      expect(r.chat({}).getHumanInputNodeData('node-1')?.data, {'found': true});
    });
  });

  group('useChat – conversationId and setTargetMessageId', () {
    test('should initially be an empty string', () {
      expect(_Rig().chat({}).conversationId, '');
    });

    test('setTargetMessageId should change chatList thread path', () {
      final tree = <DifyJson>[
        {
          'id': 'q1',
          'content': 'question 1',
          'isAnswer': false,
          'children': [
            {
              'id': 'a1',
              'content': 'answer 1',
              'isAnswer': true,
              'children': [
                {
                  'id': 'q2-branch-a',
                  'content': 'branch A question',
                  'isAnswer': false,
                  'children': [
                    {'id': 'a2-branch-a', 'content': 'branch A answer', 'isAnswer': true, 'children': <DifyJson>[]},
                  ],
                },
                {
                  'id': 'q2-branch-b',
                  'content': 'branch B question',
                  'isAnswer': false,
                  'children': [
                    {'id': 'a2-branch-b', 'content': 'branch B answer', 'isAnswer': true, 'children': <DifyJson>[]},
                  ],
                },
              ],
            },
          ],
        },
      ];
      final c = _Rig().chat({}, null, tree);
      expect(c.chatList.any((i) => i['id'] == 'a1'), isTrue);
      c.setTargetMessageId('a2-branch-a');
      expect(c.chatList.any((i) => i['id'] == 'a2-branch-a'), isTrue);
      expect(c.chatList.any((i) => i['id'] == 'a2-branch-b'), isFalse);
      c.setTargetMessageId('a2-branch-b');
      expect(c.chatList.any((i) => i['id'] == 'a2-branch-b'), isTrue);
      expect(c.chatList.any((i) => i['id'] == 'a2-branch-a'), isFalse);
    });
  });

  group('useChat – updateCurrentQAOnTree with parent_message_id', () {
    test('should handle follow-up message with parent_message_id', () async {
      final r = _Rig();
      final c = r.chat({})..handleSend({'query': 'first'});
      final first = r.cb;
      first.onData!('answer1', true, _info(conversationId: 'c1', messageId: 'msg-1', taskId: 't1'));
      first.onCompleted!(false);
      await pumpEventQueue();
      c.handleSend({'query': 'follow up', 'parent_message_id': 'msg-1'});
      expect(r.run.calls, hasLength(2));
      expect(c.chatList, isNotEmpty);
    });
  });

  group('workflow debug useChat – opening statement stability', () {
    test('should return empty chatList when config has no opening_statement', () {
      expect(_Rig().chat({}).chatList, isEmpty);
    });

    test('should return empty chatList when opening_statement is an empty string', () {
      expect(_Rig().chat({'opening_statement': ''}).chatList, isEmpty);
    });

    test('should use stable id "opening-statement" instead of Date.now()', () {
      expect(_Rig().chat({'opening_statement': 'Welcome!'}).chatList[0]['id'], 'opening-statement');
    });

    test('should preserve reference when inputs change but produce identical content', () {
      final c = _Rig().chat(
        {
          'opening_statement': 'Hello {{name}}',
          'suggested_questions': ['Ask {{name}}'],
        },
        (inputs: {'name': 'Alice'}, inputsForm: const []),
      );
      final before = c.chatList[0];
      expect(before['content'], 'Hello Alice');
      c.formSettings = (inputs: {'name': 'Alice'}, inputsForm: const []);
      expect(identical(c.chatList[0], before), isTrue);
    });

    test('should create new object when content actually changes', () {
      final c = _Rig().chat(
        {'opening_statement': 'Hello {{name}}', 'suggested_questions': <String>[]},
        (inputs: {'name': 'Alice'}, inputsForm: const []),
      );
      final before = c.chatList[0];
      expect(before['content'], 'Hello Alice');
      c.formSettings = (inputs: {'name': 'Bob'}, inputsForm: const []);
      expect(c.chatList[0]['content'], 'Hello Bob');
      expect(identical(c.chatList[0], before), isFalse);
    });

    test('should preserve reference for existing opening statement in prevChatTree', () {
      final config = {
        'opening_statement': 'Updated welcome',
        'suggested_questions': ['S1'],
      };
      final c = _Rig().chat(config, null, [
        {
          'id': 'opening-statement',
          'content': 'old',
          'isAnswer': true,
          'isOpeningStatement': true,
          'suggestedQuestions': <String>[],
        },
      ]);
      final before = c.chatList[0];
      expect(before['content'], 'Updated welcome');
      c.config = config;
      expect(identical(c.chatList[0], before), isTrue);
    });

    test('should include suggestedQuestions in opening statement when config has them', () {
      final c = _Rig().chat({
        'opening_statement': 'Welcome!',
        'suggested_questions': ['How are you?', 'What can you do?'],
      });
      expect(c.chatList[0]['suggestedQuestions'], ['How are you?', 'What can you do?']);
    });

    test('should not include suggestedQuestions when config has none', () {
      expect(_Rig().chat({'opening_statement': 'Welcome!'}).chatList[0]['suggestedQuestions'], isNull);
    });
  });

  group('useChat', () {
    test('resumes the workflow event stream when switching to a sibling with pending human input', () async {
      final r = _Rig();
      final c = r.chat({})..handleSend({'query': 'test'});
      r.cb.onWorkflowStarted!(_started(runId: 'workflow-run-1', messageId: 'message-1'));
      r.cb.onHumanInputRequired!(
        const HumanInputRequiredEvent({
          'data': {'node_id': 'human-node', 'form_token': 'form-token'},
        }),
      );
      r.cb.onCompleted!(false);
      await pumpEventQueue();
      c.handleSwitchSibling('message-1');
      expect(r.resumes, isNotEmpty);
    });

    test('submits human input forms through the workflow service', () async {
      final r = _Rig();
      await r.chat({}).handleSubmitHumanInputForm('token-123', {
        'inputs': {'field': 'value'},
        'action': 'approve',
      });
      expect(r.service.submits.single.$1, 'token-123');
    });

    test('returns the matching custom node for a human input request', () {
      final r = _Rig()
        ..nodes = const [
          RunGraphNode(id: 'node-1', type: 'human-input', title: 'Human Input'),
          RunGraphNode(id: 'node-2', type: 'human-input', title: 'Other'),
        ];
      final c = r.chat({});
      expect(c.getHumanInputNodeData('node-1')?.title, 'Human Input');
      expect(c.getHumanInputNodeData('missing'), isNull);
    });
  });

  group('useChat – handleSend SSE callbacks', () {
    late _Rig r;

    DebugChatController setupAndSend([DifyJson config = const {}]) {
      r = _Rig();
      return r.chat(config)..handleSend({'query': 'test'}, onGetSuggestedQuestions: (_, _) => Future.value(['q1']));
    }

    void startWorkflow({String runId = 'wfr-1', String taskId = 'task-1'}) =>
        r.cb.onWorkflowStarted!(_started(runId: runId, taskId: taskId));
    void startNode(String nodeId, String traceId, [DifyJson extra = const {}]) => r.cb.onNodeStarted!(
      NodeStartedEvent({
        'data': {'node_id': nodeId, 'id': traceId, ...extra},
      }),
    );

    group('onData', () {
      test('should append message content', () {
        final c = setupAndSend();
        r.cb.onData!('Hello', true, _info(conversationId: 'conv-1', messageId: 'msg-1', taskId: 'task-1'));
        expect(_answer(c)!['content'], contains('Hello'));
      });

      test('should set response id from messageId on first call', () {
        final c = setupAndSend();
        r.cb.onData!('Hi', true, _info(conversationId: 'conv-1', messageId: 'msg-123', taskId: 'task-1'));
        expect(_byId(c, 'msg-123'), isNotNull);
      });

      test('should set conversationId on first message with newConversationId', () {
        final c = setupAndSend();
        r.cb.onData!('Hi', true, _info(conversationId: 'new-conv-id', messageId: 'msg-1', taskId: 'task-1'));
        expect(c.conversationId, 'new-conv-id');
      });

      test('should not set conversationId when isFirstMessage is false', () {
        final c = setupAndSend();
        r.cb.onData!('Hi', false, _info(conversationId: 'conv-should-not-set', messageId: 'msg-1', taskId: 'task-1'));
        expect(c.conversationId, '');
      });

      test('should not update hasSetResponseId when messageId is empty', () {
        final c = setupAndSend();
        r.cb.onData!('msg1', true, _info(conversationId: '', messageId: '', taskId: 'task-1'));
        r.cb.onData!('msg2', false, _info(conversationId: '', messageId: 'late-id', taskId: 'task-1'));
        expect(_byId(c, 'late-id'), isNotNull);
      });

      test('should only set hasSetResponseId once', () {
        final c = setupAndSend();
        r.cb.onData!('msg1', true, _info(conversationId: 'c1', messageId: 'msg-first', taskId: 'task-1'));
        r.cb.onData!('msg2', false, _info(conversationId: 'c1', messageId: 'msg-second', taskId: 'task-1'));
        expect(c.chatList.firstWhere((i) => i['isAnswer'] != true)['id'], 'question-msg-first');
      });
    });

    group('onReasoning', () {
      ReasoningChunkEvent chunk(DifyJson data) => ReasoningChunkEvent({'data': data});

      test('should accumulate reasoning per node without leaking into content', () {
        final c = setupAndSend();
        r.cb.onReasoning!(chunk({'message_id': 'm-1', 'reasoning': 'let me ', 'node_id': 'llm'}));
        r.cb.onReasoning!(chunk({'message_id': 'm-1', 'reasoning': 'think', 'node_id': 'llm'}));
        final answer = _answer(c)!;
        expect(answer['reasoningContent'], {'llm': 'let me think'});
        expect(answer['reasoningFinished'], isNull);
        expect(answer['content'], '');
      });

      test('should key reasoning by node and fall back to "_" when node_id is absent', () {
        final c = setupAndSend();
        r.cb.onReasoning!(chunk({'message_id': 'm-1', 'reasoning': 'a', 'node_id': 'llm-1'}));
        r.cb.onReasoning!(chunk({'message_id': 'm-1', 'reasoning': 'b', 'node_id': 'llm-2'}));
        r.cb.onReasoning!(chunk({'message_id': 'm-1', 'reasoning': 'c'}));
        expect(_answer(c)!['reasoningContent'], {'llm-1': 'a', 'llm-2': 'b', '_': 'c'});
      });

      test('should ignore empty reasoning and mark finished when is_final is set', () {
        final c = setupAndSend();
        r.cb.onReasoning!(chunk({'message_id': 'm-1', 'reasoning': 'done', 'node_id': 'llm'}));
        r.cb.onReasoning!(chunk({'message_id': 'm-1', 'reasoning': '', 'node_id': 'llm', 'is_final': true}));
        expect(_answer(c)!['reasoningContent'], {'llm': 'done'});
        expect(_answer(c)!['reasoningFinished'], true);
      });
    });

    group('onCompleted', () {
      test('should set isResponding to false', () async {
        final c = setupAndSend();
        r.cb.onCompleted!(false);
        await pumpEventQueue();
        expect(c.isResponding, isFalse);
      });

      test('should call fetchInspectVars and invalidAllLastRun when not paused', () async {
        setupAndSend();
        r.cb.onCompleted!(false);
        await pumpEventQueue();
        expect(r.fetchInspectVars, 1);
        expect(r.run.invalidated, 1);
      });

      test('should not call fetchInspectVars when workflow is paused', () async {
        setupAndSend();
        r.store.setWorkflowRunningData({
          'result': {'status': 'paused'},
        });
        r.cb.onCompleted!(false);
        await pumpEventQueue();
        expect(r.fetchInspectVars, 0);
      });

      test('should set error content on response item when hasError with errorMessage', () async {
        final c = setupAndSend();
        r.cb.onData!('partial', true, _info(conversationId: 'c1', messageId: 'msg-err', taskId: 't1'));
        r.cb.onCompleted!(true, 'Something went wrong');
        await pumpEventQueue();
        expect(_byId(c, 'msg-err')!['content'], 'Something went wrong');
        expect(_byId(c, 'msg-err')!['isError'], true);
      });

      test('should not set error content when hasError is true but errorMessage is empty', () async {
        final c = setupAndSend();
        r.cb.onCompleted!(true);
        await pumpEventQueue();
        expect(c.isResponding, isFalse);
      });

      test('should fetch suggested questions when enabled and invoke abort controller callback', () async {
        r = _Rig();
        var called = 0;
        r
            .chat({
              'suggested_questions_after_answer': {'enabled': true},
            })
            .handleSend(
              {'query': 'test'},
              onGetSuggestedQuestions: (id, getAbort) {
                called++;
                getAbort(() {});
                return Future.value(['suggestion1']);
              },
            );
        r.cb.onCompleted!(false);
        await pumpEventQueue();
        expect(called, 1);
      });

      test('should set suggestedQuestions to empty array when fetch fails', () async {
        r = _Rig();
        final c = r.chat({
          'suggested_questions_after_answer': {'enabled': true},
        })..handleSend({'query': 'test'}, onGetSuggestedQuestions: (_, _) => Future.error(Exception('fail')));
        r.cb.onCompleted!(false);
        await pumpEventQueue();
        expect(c.suggestedQuestions, isEmpty);
      });
    });

    group('onError', () {
      test('should set isResponding to false', () {
        final c = setupAndSend();
        r.cb.onError!('');
        expect(c.isResponding, isFalse);
      });
    });

    group('onMessageEnd', () {
      test('should update citation and files', () {
        final c = setupAndSend();
        r.cb.onData!('response', true, _info(conversationId: 'c1', messageId: 'msg-1', taskId: 't1'));
        r.cb.onMessageEnd!(
          const MessageEndEvent({
            'metadata': {
              'retriever_resources': [
                {'id': 'r1'},
              ],
            },
            'files': <Object?>[],
          }),
        );
        expect(_byId(c, 'msg-1')!['citation'], [
          {'id': 'r1'},
        ]);
      });

      test('should default citation to empty array when no retriever_resources', () {
        final c = setupAndSend();
        r.cb.onData!('response', true, _info(conversationId: 'c1', messageId: 'msg-1', taskId: 't1'));
        r.cb.onMessageEnd!(const MessageEndEvent({'metadata': <String, Object?>{}, 'files': <Object?>[]}));
        expect(_byId(c, 'msg-1')!['citation'], isEmpty);
      });
    });

    group('onMessageReplace', () {
      test('should replace answer content on responseItem', () {
        final c = setupAndSend();
        r.cb.onData!('old', true, _info(conversationId: 'c1', messageId: 'msg-1', taskId: 't1'));
        r.cb.onMessageReplace!(const MessageReplaceEvent({'answer': 'replaced'}));
        r.cb.onMessageEnd!(const MessageEndEvent({'metadata': <String, Object?>{}, 'files': <Object?>[]}));
        expect(_byId(c, 'msg-1')!['content'], 'replaced');
      });
    });

    group('onWorkflowStarted', () {
      test('should create workflow process with Running status', () {
        final c = setupAndSend();
        r.cb.onWorkflowStarted!(_started(conversationId: 'conv-1', messageId: 'msg-1'));
        expect(_process(_answer(c))['status'], 'running');
        expect(_tracing(_answer(c)), isEmpty);
      });

      test('should set conversationId when provided', () {
        final c = setupAndSend();
        r.cb.onWorkflowStarted!(_started(conversationId: 'from-workflow'));
        expect(c.conversationId, 'from-workflow');
      });

      test('should not override existing conversationId when conversation_id is null', () {
        final c = setupAndSend();
        startWorkflow();
        expect(c.conversationId, '');
      });

      test('should resume existing workflow process when tracing exists', () {
        final c = setupAndSend();
        startWorkflow();
        startNode('n1', 'trace-1');
        startWorkflow(runId: 'wfr-2', taskId: 'task-2');
        expect(_process(_answer(c))['status'], 'running');
        expect(_tracing(_answer(c)), hasLength(1));
      });

      test('should replace placeholder answer id with real message_id from server', () {
        final c = setupAndSend();
        r.cb.onWorkflowStarted!(_started(messageId: 'wf-msg-id'));
        expect(_byId(c, 'wf-msg-id'), isNotNull);
      });
    });

    group('onWorkflowFinished', () {
      test('should update workflow process status', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onWorkflowFinished!(
          const WorkflowFinishedEvent({
            'data': {'status': 'succeeded'},
          }),
        );
        expect(_process(_answer(c))['status'], 'succeeded');
      });

      test('should store workflow finished error on workflow process', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onWorkflowFinished!(
          const WorkflowFinishedEvent({
            'data': {'status': 'failed', 'error': 'Invalid upload file'},
          }),
        );
        expect(_process(_answer(c))['status'], 'failed');
        expect(_process(_answer(c))['error'], 'Invalid upload file');
      });
    });

    group('onIterationStart / onIterationFinish', () {
      test('should push tracing entry on start', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onIterationStart!(
          const IterationStartedEvent({
            'data': {'id': 'iter-1', 'node_id': 'n-iter'},
          }),
        );
        final t = _tracing(_answer(c));
        expect(t, hasLength(1));
        expect(t[0]['id'], 'iter-1');
        expect(t[0]['node_id'], 'n-iter');
        expect(t[0]['status'], 'running');
      });

      test('should update matching tracing on finish', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onIterationStart!(
          const IterationStartedEvent({
            'data': {'id': 'iter-1', 'node_id': 'n-iter'},
          }),
        );
        r.cb.onIterationFinish!(
          const IterationCompletedEvent({
            'data': {'id': 'iter-1', 'node_id': 'n-iter', 'output': 'done'},
          }),
        );
        final t = _tracing(_answer(c)).firstWhere((t) => t['id'] == 'iter-1');
        expect(t['node_id'], 'n-iter');
        expect(t['output'], 'done');
      });

      test('should not update tracing on finish when id does not match', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onIterationStart!(
          const IterationStartedEvent({
            'data': {'id': 'iter-1', 'node_id': 'n-iter'},
          }),
        );
        r.cb.onIterationFinish!(
          const IterationCompletedEvent({
            'data': {'id': 'iter-nonexistent', 'node_id': 'n-other'},
          }),
        );
        expect(_tracing(_answer(c)), hasLength(1));
        expect(_tracing(_answer(c))[0]['output'], isNull);
      });
    });

    group('onLoopStart / onLoopFinish', () {
      test('should push tracing entry on start', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onLoopStart!(
          const LoopStartedEvent({
            'data': {'id': 'loop-1', 'node_id': 'n-loop'},
          }),
        );
        final t = _tracing(_answer(c));
        expect(t, hasLength(1));
        expect(t[0]['id'], 'loop-1');
        expect(t[0]['node_id'], 'n-loop');
        expect(t[0]['status'], 'running');
      });

      test('should update matching tracing on finish', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onLoopStart!(
          const LoopStartedEvent({
            'data': {'id': 'loop-1', 'node_id': 'n-loop'},
          }),
        );
        r.cb.onLoopFinish!(
          const LoopCompletedEvent({
            'data': {'id': 'loop-1', 'node_id': 'n-loop', 'output': 'done'},
          }),
        );
        final t = _tracing(_answer(c));
        expect(t, hasLength(1));
        expect(t[0]['id'], 'loop-1');
        expect(t[0]['node_id'], 'n-loop');
        expect(t[0]['output'], 'done');
      });

      test('should not update tracing on finish when id does not match', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onLoopStart!(
          const LoopStartedEvent({
            'data': {'id': 'loop-1', 'node_id': 'n-loop'},
          }),
        );
        r.cb.onLoopFinish!(
          const LoopCompletedEvent({
            'data': {'id': 'loop-nonexistent', 'node_id': 'n-other'},
          }),
        );
        expect(_tracing(_answer(c)), hasLength(1));
        expect(_tracing(_answer(c))[0]['output'], isNull);
      });
    });

    group('onNodeStarted / onNodeRetry / onNodeFinished', () {
      test('should add new tracing entry', () {
        final c = setupAndSend();
        startWorkflow();
        startNode('node-1', 'trace-1');
        final t = _tracing(_answer(c));
        expect(t, hasLength(1));
        expect(t[0]['id'], 'trace-1');
        expect(t[0]['node_id'], 'node-1');
        expect(t[0]['status'], 'running');
      });

      test('should update existing tracing entry with same node_id', () {
        final c = setupAndSend();
        startWorkflow();
        startNode('node-1', 'trace-1');
        startNode('node-1', 'trace-1-v2');
        final t = _tracing(_answer(c));
        expect(t, hasLength(1));
        expect(t[0]['id'], 'trace-1-v2');
        expect(t[0]['node_id'], 'node-1');
        expect(t[0]['status'], 'running');
      });

      test('should push retry data to tracing', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onNodeRetry!(
          const NodeRetryEvent({
            'data': {'node_id': 'node-1', 'id': 'retry-1', 'retry_index': 1},
          }),
        );
        final t = _tracing(_answer(c));
        expect(t, hasLength(1));
        expect(t[0]['id'], 'retry-1');
        expect(t[0]['node_id'], 'node-1');
        expect(t[0]['retry_index'], 1);
      });

      test('should update tracing entry on finish by id', () {
        final c = setupAndSend();
        startWorkflow();
        startNode('node-1', 'trace-1');
        r.cb.onNodeFinished!(
          const NodeFinishedEvent({
            'data': {
              'node_id': 'node-1',
              'id': 'trace-1',
              'status': 'succeeded',
              'outputs': {'text': 'done'},
            },
          }),
        );
        final t = _tracing(_answer(c));
        expect(t, hasLength(1));
        expect(t[0]['id'], 'trace-1');
        expect(t[0]['status'], 'succeeded');
        expect(t[0]['outputs'], {'text': 'done'});
      });

      test('should not update tracing on finish when id does not match', () {
        final c = setupAndSend();
        startWorkflow();
        startNode('node-1', 'trace-1');
        r.cb.onNodeFinished!(
          const NodeFinishedEvent({
            'data': {'node_id': 'node-x', 'id': 'trace-x', 'status': 'succeeded'},
          }),
        );
        final t = _tracing(_answer(c));
        expect(t, hasLength(1));
        expect(t[0]['id'], 'trace-1');
        expect(t[0]['status'], 'running');
      });
    });

    group('onAgentLog', () {
      List agentLog(DebugChatController c) =>
          (_tracing(_answer(c)).firstWhere((t) => t['node_id'] == 'agent-node')['execution_metadata']
                  as Map)['agent_log']
              as List;
      AgentLogEvent log(String messageId, String content) => AgentLogEvent({
        'data': {'node_id': 'agent-node', 'message_id': messageId, 'content': content},
      });

      test('should create execution_metadata.agent_log when no execution_metadata exists', () {
        final c = setupAndSend();
        startWorkflow();
        startNode('agent-node', 'trace-agent');
        r.cb.onAgentLog!(log('log-1', 'init'));
        expect(agentLog(c), hasLength(1));
      });

      test('should create agent_log array when execution_metadata exists but no agent_log', () {
        final c = setupAndSend();
        startWorkflow();
        startNode('agent-node', 'trace-agent', {
          'execution_metadata': {'parallel_id': 'p1'},
        });
        r.cb.onAgentLog!(log('log-1', 'step1'));
        expect(agentLog(c), hasLength(1));
      });

      test('should update existing agent_log entry by message_id', () {
        final c = setupAndSend();
        startWorkflow();
        startNode('agent-node', 'trace-agent', {
          'execution_metadata': {
            'agent_log': [
              {'message_id': 'log-1', 'content': 'v1'},
            ],
          },
        });
        r.cb.onAgentLog!(log('log-1', 'v2'));
        expect(agentLog(c), hasLength(1));
        expect((agentLog(c)[0] as Map)['content'], 'v2');
      });

      test('should push new agent_log entry when message_id does not match', () {
        final c = setupAndSend();
        startWorkflow();
        startNode('agent-node', 'trace-agent', {
          'execution_metadata': {
            'agent_log': [
              {'message_id': 'log-1', 'content': 'v1'},
            ],
          },
        });
        r.cb.onAgentLog!(log('log-2', 'new'));
        expect(agentLog(c), hasLength(2));
      });
    });

    group('onHumanInputRequired', () {
      HumanInputRequiredEvent required(String nodeId, String token, [DifyJson extra = const {}]) =>
          HumanInputRequiredEvent({
            'data': {'node_id': nodeId, 'form_token': token, ...extra},
          });

      test('should add form data to humanInputFormDataList', () {
        final c = setupAndSend();
        startWorkflow();
        startNode('human-node', 'trace-human');
        r.cb.onHumanInputRequired!(
          required('human-node', 'token-1', {'form_content': '{{#\$output.answer#}}', 'inputs': <Object?>[]}),
        );
        final forms = _list(_answer(c), 'humanInputFormDataList');
        expect(forms, hasLength(1));
        expect(forms[0]['node_id'], 'human-node');
        expect(forms[0]['form_token'], 'token-1');
      });

      test('should update existing form for same node_id', () {
        final c = setupAndSend();
        startWorkflow();
        startNode('human-node', 'trace-human');
        r.cb.onHumanInputRequired!(
          required('human-node', 'token-1', {'form_content': '{{#\$output.answer#}}', 'inputs': <Object?>[]}),
        );
        r.cb.onHumanInputRequired!(required('human-node', 'token-2'));
        final forms = _list(_answer(c), 'humanInputFormDataList');
        expect(forms, hasLength(1));
        expect(forms[0]['form_token'], 'token-2');
      });

      test('should push new form data for different node_id', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onHumanInputRequired!(required('human-node-1', 'token-1'));
        r.cb.onHumanInputRequired!(required('human-node-2', 'token-2'));
        final forms = _list(_answer(c), 'humanInputFormDataList');
        expect(forms, hasLength(2));
        expect(forms[0]['node_id'], 'human-node-1');
        expect(forms[1]['node_id'], 'human-node-2');
      });

      test('should set tracing node status to Paused when tracing index found', () {
        final c = setupAndSend();
        startWorkflow();
        startNode('human-node', 'trace-human');
        r.cb.onHumanInputRequired!(required('human-node', 'token-1'));
        expect(_tracing(_answer(c)).firstWhere((t) => t['node_id'] == 'human-node')['status'], 'paused');
      });
    });

    group('onHumanInputFormFilled', () {
      test('should remove form and add to filled list', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onHumanInputRequired!(
          const HumanInputRequiredEvent({
            'data': {
              'node_id': 'human-node',
              'form_token': 'token-1',
              'form_content': '{{#\$output.answer#}}',
              'inputs': <Object?>[],
            },
          }),
        );
        r.cb.onHumanInputFormFilled!(
          const HumanInputFormFilledEvent({
            'data': {
              'node_id': 'human-node',
              'submitted_data': {'answer': 'yes'},
            },
          }),
        );
        final answer = _answer(c);
        expect(_list(answer, 'humanInputFormDataList'), isEmpty);
        final filled = _list(answer, 'humanInputFilledFormDataList');
        expect(filled, hasLength(1));
        expect(filled[0]['node_id'], 'human-node');
        expect(filled[0]['submitted_data'], {'answer': 'yes'});
        expect(filled[0]['form_content'], '{{#\$output.answer#}}');
        expect(filled[0]['inputs'], isEmpty);
      });
    });

    group('onHumanInputFormTimeout', () {
      test('should update expiration_time on form data', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onHumanInputRequired!(
          const HumanInputRequiredEvent({
            'data': {'node_id': 'human-node', 'form_token': 'token-1'},
          }),
        );
        r.cb.onHumanInputFormTimeout!(
          const HumanInputFormTimeoutEvent({
            'data': {'node_id': 'human-node', 'expiration_time': '2025-01-01T00:00:00Z'},
          }),
        );
        final form = _list(_answer(c), 'humanInputFormDataList').firstWhere((f) => f['node_id'] == 'human-node');
        expect(form['expiration_time'], '2025-01-01T00:00:00Z');
      });
    });

    group('onWorkflowPaused', () {
      test('should set status to Paused', () {
        final c = setupAndSend();
        startWorkflow();
        r.cb.onWorkflowPaused!(const WorkflowPausedEvent({'data': <String, Object?>{}}));
        expect(_process(_answer(c))['status'], 'paused');
      });
    });
  });

  group('useChat – handleResume', () {
    late _Rig r;

    /// `setupResumeWithTree()`.
    Future<DebugChatController> setupResumeWithTree({
      DifyJson config = const {},
      SuggestedQuestionsFetcher? fetch,
    }) async {
      r = _Rig();
      final c = r.chat(config)..handleSend({'query': 'test'});
      r.cb.onWorkflowStarted!(_started(messageId: 'msg-resume'));
      r.cb.onCompleted!(false);
      await pumpEventQueue();
      c.handleResume('msg-resume', 'wfr-1', onGetSuggestedQuestions: fetch);
      return c;
    }

    DifyJson? answer(DebugChatController c) => _byId(c, 'msg-resume');
    void resumeStarted() => r.resumed.onWorkflowStarted!(_started(runId: 'wfr-2', taskId: 'task-2'));

    test('should call sseGet with the correct URL', () {
      r = _Rig();
      r.chat({}).handleResume('msg-1', 'wfr-1');
      expect(r.resumes.single.$1, 'wfr-1');
    });

    test('should abort previous SSE connection when handleResume is called again', () {
      r = _Rig();
      final first = RunStreamHandle();
      r.resumeImpl = (_, cb) {
        cb.getAbortController!(first);
        return first;
      };
      final c = r.chat({})..handleResume('msg-1', 'wfr-1');
      r.resumeImpl = (_, cb) {
        final second = _Abort();
        cb.getAbortController!(second);
        return second;
      };
      c.handleResume('msg-1', 'wfr-2');
      expect(first.aborted, isTrue);
    });

    test('should abort previous workflowEventsAbortController before sseGet', () {
      r = _Rig();
      final abort = _Abort();
      final c = r.chat({})..handleSend({'query': 'test'});
      r.cb.getAbortController!(abort);
      c.handleResume('msg-1', 'wfr-1');
      expect(abort.count, 1);
    });

    group('onWorkflowStarted', () {
      test('should set isResponding and update workflow process', () async {
        final c = await setupResumeWithTree();
        resumeStarted();
        expect(c.isResponding, isTrue);
      });

      test('should resume existing workflow when tracing exists', () async {
        r = _Rig();
        final c = r.chat({})..handleSend({'query': 'test'});
        r.cb.onWorkflowStarted!(_started(messageId: 'msg-resume'));
        r.cb.onNodeStarted!(
          const NodeStartedEvent({
            'data': {'node_id': 'n1', 'id': 'trace-1'},
          }),
        );
        r.cb.onCompleted!(false);
        await pumpEventQueue();
        c.handleResume('msg-resume', 'wfr-1');
        resumeStarted();
        expect(_process(answer(c))['status'], 'running');
      });
    });

    group('onWorkflowFinished', () {
      test('should update workflow status', () async {
        final c = await setupResumeWithTree();
        resumeStarted();
        r.resumed.onWorkflowFinished!(
          const WorkflowFinishedEvent({
            'data': {'status': 'succeeded'},
          }),
        );
        expect(_process(answer(c))['status'], 'succeeded');
      });

      test('should store workflow finished error on resume workflow process', () async {
        final c = await setupResumeWithTree();
        resumeStarted();
        r.resumed.onWorkflowFinished!(
          const WorkflowFinishedEvent({
            'data': {'status': 'failed', 'error': 'Invalid upload file'},
          }),
        );
        expect(_process(answer(c))['status'], 'failed');
        expect(_process(answer(c))['error'], 'Invalid upload file');
      });
    });

    group('onData', () {
      test('should append message content', () async {
        final c = await setupResumeWithTree();
        r.resumed.onData!('resumed', false, _info(conversationId: 'conv-2', messageId: 'msg-resume', taskId: 'task-2'));
        expect(answer(c)!['content'], contains('resumed'));
      });

      test('should update conversationId when provided', () async {
        final c = await setupResumeWithTree();
        r.resumed.onData!('msg', false, _info(conversationId: 'new-conv-resume', taskId: 'task-2'));
        expect(c.conversationId, 'new-conv-resume');
      });
    });

    group('onReasoning', () {
      test('should accumulate reasoning per node onto the resumed answer', () async {
        final c = await setupResumeWithTree();
        r.resumed.onReasoning!(
          const ReasoningChunkEvent({
            'data': {'message_id': 'msg-resume', 'reasoning': 'resumed ', 'node_id': 'llm'},
          }),
        );
        r.resumed.onReasoning!(
          const ReasoningChunkEvent({
            'data': {'message_id': 'msg-resume', 'reasoning': 'thought', 'node_id': 'llm', 'is_final': true},
          }),
        );
        expect(answer(c)!['reasoningContent'], {'llm': 'resumed thought'});
        expect(answer(c)!['reasoningFinished'], true);
      });

      test('should ignore empty reasoning and fall back to "_" when node_id is absent', () async {
        final c = await setupResumeWithTree();
        for (final reasoning in ['', 'a', 'b']) {
          r.resumed.onReasoning!(
            ReasoningChunkEvent({
              'data': {'message_id': 'msg-resume', 'reasoning': reasoning},
            }),
          );
        }
        expect(answer(c)!['reasoningContent'], {'_': 'ab'});
        expect(answer(c)!['reasoningFinished'], isNull);
      });
    });

    group('onCompleted', () {
      test('should set isResponding to false', () async {
        final c = await setupResumeWithTree();
        r.resumed.onCompleted!(false);
        await pumpEventQueue();
        expect(c.isResponding, isFalse);
      });

      test('should not call fetchInspectVars when paused', () async {
        await setupResumeWithTree();
        r.store.setWorkflowRunningData({
          'result': {'status': 'paused'},
        });
        r.fetchInspectVars = 0;
        r.resumed.onCompleted!(false);
        await pumpEventQueue();
        expect(r.fetchInspectVars, 0);
      });

      test('should still call fetchInspectVars on error but skip suggested questions', () async {
        var asked = 0;
        await setupResumeWithTree(
          config: {
            'suggested_questions_after_answer': {'enabled': true},
          },
          fetch: (_, _) {
            asked++;
            return Future.value(['s1']);
          },
        );
        r
          ..fetchInspectVars = 0
          ..run.invalidated = 0;
        r.resumed.onCompleted!(true);
        await pumpEventQueue();
        expect(r.fetchInspectVars, 1);
        expect(r.run.invalidated, 1);
        expect(asked, 0);
      });

      test('should fetch suggested questions when enabled', () async {
        var asked = 0;
        await setupResumeWithTree(
          config: {
            'suggested_questions_after_answer': {'enabled': true},
          },
          fetch: (_, getAbort) {
            asked++;
            getAbort(() {});
            return Future.value(['s1']);
          },
        );
        r.resumed.onCompleted!(false);
        await pumpEventQueue();
        expect(asked, 1);
      });

      test('should set suggestedQuestions to empty on fetch error', () async {
        final c = await setupResumeWithTree(
          config: {
            'suggested_questions_after_answer': {'enabled': true},
          },
          fetch: (_, _) => Future.error(Exception('fail')),
        );
        r.resumed.onCompleted!(false);
        await pumpEventQueue();
        expect(c.suggestedQuestions, isEmpty);
      });
    });

    group('onError', () {
      test('should set isResponding to false', () async {
        final c = await setupResumeWithTree();
        r.resumed.onError!('');
        expect(c.isResponding, isFalse);
      });
    });

    group('onMessageEnd', () {
      test('should update citation and files', () async {
        final c = await setupResumeWithTree();
        r.resumed.onMessageEnd!(
          const MessageEndEvent({
            'metadata': {
              'retriever_resources': [
                {'id': 'cite-1'},
              ],
            },
            'files': <Object?>[],
          }),
        );
        expect(answer(c)!['citation'], [
          {'id': 'cite-1'},
        ]);
      });
    });

    group('onMessageReplace', () {
      test('should replace content', () async {
        final c = await setupResumeWithTree();
        r.resumed.onMessageReplace!(const MessageReplaceEvent({'answer': 'replaced'}));
        expect(answer(c)!['content'], 'replaced');
      });
    });

    group('onIterationStart / onIterationFinish', () {
      test('should push and update iteration tracing entries', () async {
        final c = await setupResumeWithTree();
        r.resumed.onIterationStart!(
          const IterationStartedEvent({
            'data': {'id': 'iter-r1', 'node_id': 'n-iter-r'},
          }),
        );
        expect(_tracing(answer(c)), hasLength(1));
        expect(_tracing(answer(c))[0]['id'], 'iter-r1');
        expect(_tracing(answer(c))[0]['status'], 'running');
        r.resumed.onIterationFinish!(
          const IterationCompletedEvent({
            'data': {'id': 'iter-r1', 'node_id': 'n-iter-r', 'execution_metadata': <String, Object?>{}},
          }),
        );
        expect(_tracing(answer(c)), hasLength(1));
        expect(_tracing(answer(c))[0]['status'], 'succeeded');
      });

      test('should handle iteration finish when no match found', () async {
        await setupResumeWithTree();
        r.resumed.onIterationFinish!(
          const IterationCompletedEvent({
            'data': {'id': 'no-match', 'node_id': 'no-match', 'execution_metadata': <String, Object?>{}},
          }),
        );
      });
    });

    group('onLoopStart / onLoopFinish', () {
      test('should push and update loop tracing entries', () async {
        final c = await setupResumeWithTree();
        r.resumed.onLoopStart!(
          const LoopStartedEvent({
            'data': {'id': 'loop-r1', 'node_id': 'n-loop-r'},
          }),
        );
        expect(_tracing(answer(c)), hasLength(1));
        expect(_tracing(answer(c))[0]['id'], 'loop-r1');
        expect(_tracing(answer(c))[0]['status'], 'running');
        r.resumed.onLoopFinish!(
          const LoopCompletedEvent({
            'data': {'id': 'loop-r1', 'node_id': 'n-loop-r', 'execution_metadata': <String, Object?>{}},
          }),
        );
        expect(_tracing(answer(c)), hasLength(1));
        expect(_tracing(answer(c))[0]['status'], 'succeeded');
      });

      test('should handle loop finish when no match found', () async {
        await setupResumeWithTree();
        r.resumed.onLoopFinish!(
          const LoopCompletedEvent({
            'data': {'id': 'no-match', 'node_id': 'no-match', 'execution_metadata': <String, Object?>{}},
          }),
        );
      });
    });

    group('onNodeStarted / onNodeFinished', () {
      test('should add and update node tracing entries', () async {
        final c = await setupResumeWithTree();
        resumeStarted();
        r.resumed.onNodeStarted!(
          const NodeStartedEvent({
            'data': {'node_id': 'rn-1', 'id': 'rtrace-1'},
          }),
        );
        final started = _tracing(answer(c)).firstWhere((t) => t['node_id'] == 'rn-1');
        expect(started['id'], 'rtrace-1');
        expect(started['status'], 'running');
        r.resumed.onNodeFinished!(
          const NodeFinishedEvent({
            'data': {'node_id': 'rn-1', 'id': 'rtrace-1', 'status': 'succeeded'},
          }),
        );
        expect(_tracing(answer(c)).firstWhere((t) => t['node_id'] == 'rn-1')['status'], 'succeeded');
      });

      test('should skip onNodeStarted when iteration_id is present', () async {
        final c = await setupResumeWithTree();
        resumeStarted();
        r.resumed.onNodeStarted!(
          const NodeStartedEvent({
            'data': {'node_id': 'rn-child', 'id': 'rtrace-child', 'iteration_id': 'iter-parent'},
          }),
        );
        expect(_tracing(answer(c)).any((t) => t['node_id'] == 'rn-child'), isFalse);
      });

      test('should skip onNodeFinished when iteration_id is present', () async {
        await setupResumeWithTree();
        resumeStarted();
        r.resumed.onNodeFinished!(
          const NodeFinishedEvent({
            'data': {'node_id': 'rn-1', 'id': 'rtrace-1', 'iteration_id': 'iter-parent'},
          }),
        );
      });

      test('should update existing node in tracing on onNodeStarted', () async {
        final c = await setupResumeWithTree();
        resumeStarted();
        for (final id in ['rtrace-1', 'rtrace-1-v2']) {
          r.resumed.onNodeStarted!(
            NodeStartedEvent({
              'data': {'node_id': 'rn-1', 'id': id},
            }),
          );
        }
        final matching = _tracing(answer(c)).where((t) => t['node_id'] == 'rn-1').toList();
        expect(matching, hasLength(1));
        expect(matching[0]['id'], 'rtrace-1-v2');
        expect(matching[0]['status'], 'running');
      });

      test('should match nodeFinished with parallel_id', () async {
        final c = await setupResumeWithTree();
        resumeStarted();
        r.resumed.onNodeStarted!(
          const NodeStartedEvent({
            'data': {
              'node_id': 'rn-1',
              'id': 'rtrace-1',
              'execution_metadata': {'parallel_id': 'p1'},
            },
          }),
        );
        r.resumed.onNodeFinished!(
          const NodeFinishedEvent({
            'data': {
              'node_id': 'rn-1',
              'id': 'rtrace-1',
              'status': 'succeeded',
              'execution_metadata': {'parallel_id': 'p1'},
            },
          }),
        );
        final t = _tracing(answer(c)).firstWhere((t) => t['id'] == 'rtrace-1');
        expect(t['status'], 'succeeded');
        expect((t['execution_metadata'] as Map)['parallel_id'], 'p1');
      });
    });

    group('onHumanInputRequired', () {
      HumanInputRequiredEvent required(String nodeId, String token) => HumanInputRequiredEvent({
        'data': {'node_id': nodeId, 'form_token': token},
      });

      test('should initialize humanInputFormDataList', () async {
        final c = await setupResumeWithTree();
        r.resumed.onHumanInputRequired!(required('rn-human', 'rt-1'));
        expect(_list(answer(c), 'humanInputFormDataList'), hasLength(1));
      });

      test('should update existing form for same node and push for different node', () async {
        final c = await setupResumeWithTree();
        r.resumed.onHumanInputRequired!(required('rn-human', 'rt-1'));
        r.resumed.onHumanInputRequired!(required('rn-human', 'rt-2'));
        expect(_list(answer(c), 'humanInputFormDataList'), hasLength(1));
        r.resumed.onHumanInputRequired!(required('rn-human-2', 'rt-3'));
        expect(_list(answer(c), 'humanInputFormDataList'), hasLength(2));
      });

      test('should set tracing node to Paused when tracing match is found', () async {
        final c = await setupResumeWithTree();
        resumeStarted();
        r.resumed.onNodeStarted!(
          const NodeStartedEvent({
            'data': {'node_id': 'rn-human', 'id': 'trace-human'},
          }),
        );
        r.resumed.onHumanInputRequired!(required('rn-human', 'rt-1'));
        expect(_tracing(answer(c)).firstWhere((t) => t['node_id'] == 'rn-human')['status'], 'paused');
      });
    });

    group('onHumanInputFormFilled', () {
      test('should move form from pending to filled list', () async {
        final c = await setupResumeWithTree();
        r.resumed.onHumanInputRequired!(
          const HumanInputRequiredEvent({
            'data': {'node_id': 'rn-human', 'form_token': 'rt-1'},
          }),
        );
        r.resumed.onHumanInputFormFilled!(
          const HumanInputFormFilledEvent({
            'data': {
              'node_id': 'rn-human',
              'submitted_data': {'a': 1},
            },
          }),
        );
        expect(_list(answer(c), 'humanInputFormDataList'), isEmpty);
        expect(_list(answer(c), 'humanInputFilledFormDataList'), hasLength(1));
      });

      test('should initialize humanInputFilledFormDataList when not present', () async {
        final c = await setupResumeWithTree();
        r.resumed.onHumanInputFormFilled!(
          const HumanInputFormFilledEvent({
            'data': {
              'node_id': 'rn-human',
              'submitted_data': {'b': 2},
            },
          }),
        );
        expect(_list(answer(c), 'humanInputFilledFormDataList'), hasLength(1));
      });
    });

    group('onHumanInputFormTimeout', () {
      test('should set expiration_time on the form entry', () async {
        final c = await setupResumeWithTree();
        r.resumed.onHumanInputRequired!(
          const HumanInputRequiredEvent({
            'data': {'node_id': 'rn-human', 'form_token': 'rt-1'},
          }),
        );
        r.resumed.onHumanInputFormTimeout!(
          const HumanInputFormTimeoutEvent({
            'data': {'node_id': 'rn-human', 'expiration_time': '2025-06-01'},
          }),
        );
        final form = _list(answer(c), 'humanInputFormDataList').firstWhere((f) => f['node_id'] == 'rn-human');
        expect(form['expiration_time'], '2025-06-01');
      });
    });

    group('onWorkflowPaused', () {
      test('should keep the resumable stream and set status to Paused', () async {
        final c = await setupResumeWithTree();
        final before = r.resumes.length;
        r.resumed.onWorkflowPaused!(
          const WorkflowPausedEvent({
            'data': {'workflow_run_id': 'wfr-paused'},
          }),
        );
        expect(r.resumes.length, before);
        expect(_process(answer(c))['status'], 'paused');
      });
    });
  });

  group('useChat – handleResume with bare prevChatTree (no humanInputFormDataList / no tracing)', () {
    late _Rig r;

    DebugChatController bare(String id, String runId, {Object? tracing = const <Object?>[], bool process = true}) {
      r = _Rig();
      final c = r.chat({}, null, [
        {
          'id': 'q1',
          'content': 'question',
          'isAnswer': false,
          'children': [
            {
              'id': id,
              'content': '',
              'isAnswer': true,
              if (process) 'workflow_run_id': runId,
              if (process) 'workflowProcess': <String, Object?>{'status': 'running', 'tracing': tracing},
              'children': <DifyJson>[],
            },
          ],
        },
      ]);
      c.handleResume(id, runId);
      return c;
    }

    DebugChatController setupWithBareTree() => bare('bare-msg', 'wfr-bare');
    DebugChatController setupWithBareTreeNoTracing() => bare('bare-msg-nt', 'wfr-bare-nt', tracing: null);

    test('onHumanInputRequired should initialize humanInputFormDataList when null', () {
      final c = setupWithBareTree();
      r.resumed.onHumanInputRequired!(
        const HumanInputRequiredEvent({
          'data': {'node_id': 'hn-bare', 'form_token': 'ft-bare'},
        }),
      );
      expect(_list(_byId(c, 'bare-msg'), 'humanInputFormDataList'), hasLength(1));
    });

    test('onHumanInputFormFilled should initialize humanInputFilledFormDataList when null', () {
      final c = setupWithBareTree();
      r.resumed.onHumanInputFormFilled!(
        const HumanInputFormFilledEvent({
          'data': {
            'node_id': 'hn-bare',
            'submitted_data': {'x': 1},
          },
        }),
      );
      expect(_list(_byId(c, 'bare-msg'), 'humanInputFilledFormDataList'), hasLength(1));
    });

    test('onLoopStart should initialize tracing array when not present', () {
      final c = setupWithBareTreeNoTracing();
      r.resumed.onLoopStart!(
        const LoopStartedEvent({
          'data': {'id': 'loop-bare', 'node_id': 'n-loop-bare'},
        }),
      );
      final t = _tracing(_byId(c, 'bare-msg-nt'));
      expect(t, hasLength(1));
      expect(t[0]['id'], 'loop-bare');
      expect(t[0]['node_id'], 'n-loop-bare');
      expect(t[0]['status'], 'running');
    });

    test('onLoopFinish should return early when no tracing', () {
      setupWithBareTreeNoTracing();
      r.resumed.onLoopFinish!(
        const LoopCompletedEvent({
          'data': {'id': 'loop-bare', 'node_id': 'n-loop-bare', 'execution_metadata': <String, Object?>{}},
        }),
      );
    });

    test('onIterationStart should initialize tracing when not present', () {
      final c = setupWithBareTreeNoTracing();
      r.resumed.onIterationStart!(
        const IterationStartedEvent({
          'data': {'id': 'iter-bare', 'node_id': 'n-iter-bare'},
        }),
      );
      final t = _tracing(_byId(c, 'bare-msg-nt'));
      expect(t, hasLength(1));
      expect(t[0]['id'], 'iter-bare');
      expect(t[0]['node_id'], 'n-iter-bare');
      expect(t[0]['status'], 'running');
    });

    test('onIterationFinish should return early when no tracing', () {
      setupWithBareTreeNoTracing();
      r.resumed.onIterationFinish!(
        const IterationCompletedEvent({
          'data': {'id': 'iter-bare', 'node_id': 'n-iter-bare', 'execution_metadata': <String, Object?>{}},
        }),
      );
    });

    test('onNodeStarted should initialize tracing when not present', () {
      final c = setupWithBareTreeNoTracing();
      r.resumed.onNodeStarted!(
        const NodeStartedEvent({
          'data': {'node_id': 'rn-bare', 'id': 'rtrace-bare'},
        }),
      );
      final t = _tracing(_byId(c, 'bare-msg-nt'));
      expect(t, hasLength(1));
      expect(t[0]['id'], 'rtrace-bare');
      expect(t[0]['node_id'], 'rn-bare');
      expect(t[0]['status'], 'running');
    });

    test('onNodeFinished should return early when no tracing', () {
      setupWithBareTreeNoTracing();
      r.resumed.onNodeFinished!(
        const NodeFinishedEvent({
          'data': {'node_id': 'rn-bare', 'id': 'rtrace-bare', 'status': 'succeeded'},
        }),
      );
    });

    test('onIterationStart/onNodeStarted/onLoopStart should return early when no workflowProcess', () {
      final c = bare('bare-nowp', 'wfr-x', process: false);
      r.resumed.onIterationStart!(
        const IterationStartedEvent({
          'data': {'id': 'i1', 'node_id': 'ni1'},
        }),
      );
      r.resumed.onNodeStarted!(
        const NodeStartedEvent({
          'data': {'node_id': 'ns1', 'id': 'ts1'},
        }),
      );
      r.resumed.onLoopStart!(
        const LoopStartedEvent({
          'data': {'id': 'l1', 'node_id': 'nl1'},
        }),
      );
      expect(_byId(c, 'bare-nowp')!['workflowProcess'], isNull);
    });

    test('onHumanInputRequired should set Paused on tracing node when found', () {
      final c = setupWithBareTree();
      r.resumed.onWorkflowStarted!(_started(runId: 'wfr-2', taskId: 'task-2'));
      r.resumed.onNodeStarted!(
        const NodeStartedEvent({
          'data': {'node_id': 'hn-with-trace', 'id': 'trace-hn'},
        }),
      );
      r.resumed.onHumanInputRequired!(
        const HumanInputRequiredEvent({
          'data': {'node_id': 'hn-with-trace', 'form_token': 'ft-tr'},
        }),
      );
      expect(_tracing(_byId(c, 'bare-msg')).firstWhere((t) => t['node_id'] == 'hn-with-trace')['status'], 'paused');
    });
  });
}
