/// The chatflow Debug & Preview conversation (Dify 1.17.1 workflow/panel/debug-and-preview/hooks.ts `useChat`, with
/// base/chat/utils.ts `getThreadMessages`, base/chat/chat/utils.ts `processOpeningStatement` / `getProcessedInputs`
/// and human-input-content/submitted-utils.ts): the message tree, the streamed answer with its workflow process,
/// stop / restart, resuming a paused run, and suggested questions. Chat items are Dify's ChatItemInTree JSON (`id`,
/// `content`, `isAnswer`, `parentMessageId`, `siblingIndex`, `children`, `workflowProcess` {status, tracing, error},
/// `workflow_run_id`, `message_files`, `agent_thoughts`, `citation`, `allFiles`, `reasoningContent`,
/// `reasoningFinished`, `humanInputFormDataList`, `humanInputFilledFormDataList`, `isError`, `isOpeningStatement`,
/// `suggestedQuestions`; the thread adds `siblingCount`, `prevSibling`, `nextSibling`).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../design/widgets/toast.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store.dart';
import '../variable_inspect/value_content_helpers.dart' show getProcessedFiles, getProcessedFilesFromResponse;
import 'run_graph.dart';
import 'run_service.dart';
import 'run_stream.dart';
import 'run_types.dart';
import 'workflow_run.dart';

/// `formSettings`: the user inputs and their form (InputForm JSON: `variable`, `label`, `type`, ...).
typedef ChatFormSettings = ({DifyJson inputs, List<DifyJson> inputsForm});

/// `onGetSuggestedQuestions(messageId, getAbortController)` (ChatWrapper's `fetchSuggestedQuestions`): the questions;
/// [getAbortController] receives what cancels the request.
typedef SuggestedQuestionsFetcher = Future<List<String>> Function(
  String messageId,
  void Function(VoidCallback abort) getAbortController,
);

/// `processOpeningStatement`.
String processOpeningStatement(String openingStatement, DifyJson inputs, List<DifyJson> inputsForm) {
  if (openingStatement.isEmpty) return openingStatement;
  return openingStatement.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (m) {
    final key = m[1]!;
    final name = inputs[key];
    if (name != null && name != '' && name != false && name != 0) return '$name';
    final valueObj = inputsForm.where((v) => v['variable'] == key).firstOrNull;
    return valueObj != null ? '{{${valueObj['label']}}}' : m[0]!;
  });
}

/// `processInputFileFromServer`.
DifyJson processInputFileFromServer(Map fileItem) {
  // Runtime values already identify a frozen record; keep the marker/reference,
  // including for remote files, so restoring inputs never downloads them again.
  if (fileItem['dify_model_identity'] == '__dify__file__') return fileItem.cast<String, Object?>();
  return {
    'type': fileItem['type'],
    'transfer_method': fileItem['transfer_method'],
    'url': fileItem['remote_url'] ?? fileItem['url'],
    'upload_file_id': fileItem['upload_file_id'] ?? fileItem['related_id'],
  };
}

/// `getProcessedInputs`.
DifyJson getProcessedInputs(DifyJson inputs, List<DifyJson> inputsForm) {
  final processed = {...inputs};
  for (final item in inputsForm) {
    final variable = item['variable'] as String? ?? '';
    final inputValue = inputs[variable];
    if (item['type'] == 'checkbox') {
      processed[variable] = inputValue != null && inputValue != false && inputValue != '' && inputValue != 0;
      continue;
    }
    if (inputValue == null) continue;
    switch (item['type']) {
      case 'file':
        processed[variable] = inputValue is Map && inputValue.containsKey('transfer_method')
            ? processInputFileFromServer(inputValue)
            : getProcessedFiles([(inputValue as Map).cast<String, Object?>()]).firstOrNull;
      case 'file-list':
        final list = inputValue as List;
        processed[variable] = list.isNotEmpty && list.first is Map && (list.first as Map).containsKey('transfer_method')
            ? [for (final f in list) processInputFileFromServer(f as Map)]
            : getProcessedFiles([for (final f in list) (f as Map).cast<String, Object?>()]);
      case 'json_object':
        try {
          final v = inputValue is String ? jsonDecode(inputValue) : inputValue;
          processed[variable] = v is Map ? v : inputValue;
        } catch (_) {
          processed[variable] = inputValue;
        }
    }
  }
  return processed;
}

/// `enrichSubmittedHumanInputFormData`.
DifyJson enrichSubmittedHumanInputFormData(DifyJson filledFormData, [DifyJson? requiredFormData]) {
  if (requiredFormData == null) return filledFormData;
  return {...filledFormData, 'form_content': requiredFormData['form_content'], 'inputs': requiredFormData['inputs']};
}

List<DifyJson> _children(DifyJson node) => switch (node['children']) {
  final List l => l.cast<DifyJson>(),
  _ => const [],
};

/// `getThreadMessages`: the path to [targetMessageId] (the last message when null) and everything after it on the
/// latest branch, answers marked with their sibling count and neighbours.
List<DifyJson> getThreadMessages(List<DifyJson> tree, [String? targetMessageId]) {
  var ret = <DifyJson>[];
  DifyJson? targetNode;
  final stack = [
    for (final root in tree.reversed) (node: root, path: [root]),
  ];
  while (stack.isNotEmpty) {
    final (:node, :path) = stack.removeLast();
    if (node['id'] == targetMessageId || (targetMessageId == null && _children(node).isEmpty && stack.isEmpty)) {
      targetNode = node;
      ret = [
        for (var index = 0; index < path.length; index++)
          if (path[index]['isAnswer'] != true)
            path[index]
          else
            () {
              final item = path[index];
              final parentAnswer = index >= 2 ? path[index - 2] : null;
              final siblingIndex = (item['siblingIndex'] as num?)?.toInt() ?? 0;
              final siblings = parentAnswer == null ? tree : _children(parentAnswer);
              String? siblingAt(int i) =>
                  i >= 0 && i < siblings.length ? (_children(siblings[i]).firstOrNull?['id'] as String?) : null;
              return {
                ...item,
                'siblingCount': siblings.length,
                'prevSibling': siblingAt(siblingIndex - 1),
                'nextSibling': siblingAt(siblingIndex + 1),
              };
            }(),
      ];
      break;
    }
    final children = _children(node);
    for (var i = children.length - 1; i >= 0; i--) {
      stack.add((node: children[i], path: [...path, children[i]]));
    }
  }
  if (targetNode != null) {
    final rest = <DifyJson>[targetNode];
    while (rest.isNotEmpty) {
      final node = rest.removeLast();
      if (!identical(node, targetNode)) ret.add(node);
      final children = _children(node);
      if (children.isNotEmpty) {
        final lastChild = children.last;
        if (lastChild['isAnswer'] != true) {
          rest.add(lastChild);
          continue;
        }
        final parentAnswer = ret.length >= 2 ? ret[ret.length - 2] : null;
        final pc = parentAnswer == null ? null : _children(parentAnswer);
        rest.add({
          ...lastChild,
          'siblingCount': pc?.length,
          'prevSibling': pc != null && pc.length >= 2 ? (_children(pc[pc.length - 2]).firstOrNull?['id']) : null,
        });
      }
    }
  }
  return ret;
}

/// `useChat` for the chatflow preview. Listen to it (a [ChangeNotifier]) for [chatList], [isResponding] and
/// [suggestedQuestions].
class DebugChatController extends ChangeNotifier {
  DebugChatController({
    required this.run,
    required this.service,
    required this.store,
    this._config,
    this._formSettings,
    List<DifyJson>? prevChatTree,
    this.stopChat,
    this.graph,
    bool Function()? canRun,
    this.fetchInspectVars,
    RunStreamHandle Function(String workflowRunId, RunCallbacks callbacks)? resumeStream,
    void Function(DifyToastType type, String message)? toast,
  }) : canRun = (() => (canRun?.call() ?? true) && run.validateBeforeRun()),
       toast = toast ?? difyToast,
       resumeStream = resumeStream ?? ((id, cb) => listenRunEvents(service.workflowEvents(id), cb)) {
    _chatTree = prevChatTree ?? [];
    if (prevChatTree == null) unawaited(restoreConversation());
  }

  final WorkflowRunController run;
  final WorkflowRunService service;
  final WorkflowStore store;

  /// `stopChat(taskId)` (ChatWrapper: `stopChatMessageResponding`); null: stopping only ends the local response.
  final void Function(String taskId)? stopChat;

  /// The graph (`getHumanInputNodeData`).
  final RunGraph? graph;

  /// `sseGet('/workflow/{run_id}/events?...', {}, callbacks)`: follows a paused run's events.
  final RunStreamHandle Function(String workflowRunId, RunCallbacks callbacks) resumeStream;

  /// `accessControl.canRun`.
  final bool Function() canRun;
  final VoidCallback? fetchInspectVars;
  final void Function(DifyToastType type, String message) toast;

  DifyJson? _config;
  ChatFormSettings? _formSettings;

  /// The features config (`opening_statement`, `suggested_questions`, `suggested_questions_after_answer`).
  DifyJson? get config => _config;
  set config(DifyJson? v) {
    _config = v;
    notifyListeners();
  }

  ChatFormSettings? get formSettings => _formSettings;
  set formSettings(ChatFormSettings? v) {
    _formSettings = v;
    notifyListeners();
  }

  var _hasStopResponded = false;
  var _conversationId = '';
  var _taskId = '';
  var _isResponding = false;
  RunStreamHandle? _workflowEventsAbort;
  var _suggestedQuestions = const <String>[];
  VoidCallback? _suggestedQuestionsAbort;
  late List<DifyJson> _chatTree;
  String? _targetMessageId;
  var _disposed = false;

  bool _restoring = false;
  int _conversationEpoch = 0;
  bool get isResponding => _isResponding || _restoring;

  void _rememberConversation(String id) {
    if (id == _conversationId) return;
    _conversationId = id;
    unawaited(service.rememberChatConversation(id));
  }

  Future<void> restoreConversation() async {
    final epoch = ++_conversationEpoch;
    final id = await service.recalledChatConversation();
    if (_disposed || epoch != _conversationEpoch || id == null || id.isEmpty) return;
    _restoring = true;
    _changed();
    try {
      final messages = await service.fetchChatMessages(id);
      if (_disposed || epoch != _conversationEpoch) return;
      if (messages.isNotEmpty && messages.first['inputs'] is Map) {
        final savedInputs = messages.first['inputs'] as Map;
        store.setInputs({
          for (final entry in savedInputs.entries)
            if (entry.key is String && entry.value != null) entry.key as String: entry.value as Object,
        });
      }
      final roots = <DifyJson>[];
      final answers = <String, DifyJson>{};
      for (final message in messages) {
        final mid = message['id'] as String;
        final parent = message['parent_message_id'] as String?;
        final answer = <String, Object?>{
          'id': mid,
          'content': message['answer'] ?? '',
          'isAnswer': true,
          'parentMessageId': 'question-$mid',
          'children': <DifyJson>[],
          'workflow_run_id': message['workflow_run_id'],
          'reasoningContent': message['reasoning'],
          'allFiles': getProcessedFilesFromResponse(message['files'] as List? ?? const []),
          'isError': message['status'] == 'error',
        };
        final siblings = answers[parent]?['children'] as List<DifyJson>? ?? roots;
        answer['siblingIndex'] = siblings.length;
        siblings.add({
          'id': 'question-$mid',
          'content': message['query'],
          'isAnswer': false,
          'parentMessageId': parent,
          'message_files': getProcessedFilesFromResponse(message['message_files'] as List? ?? const []),
          'children': <DifyJson>[answer],
        });
        answers[mid] = answer;
      }
      _conversationId = id;
      _setTree(roots);
      if (messages.isNotEmpty) {
        final latest = messages.last;
        final runId = latest['workflow_run_id'] as String?;
        if (runId != null && runId.isNotEmpty) {
          final detail = await service.fetchRunDetail(runId);
          if (_disposed || epoch != _conversationEpoch) return;
          if (detail['status'] == 'running' || detail['status'] == 'paused') {
            handleResume(latest['id'] as String, runId);
          }
        }
      }
    } on Object catch (error) {
      if (!_disposed && epoch == _conversationEpoch) toast(DifyToastType.error, '$error');
    } finally {
      if (!_disposed && epoch == _conversationEpoch) {
        _restoring = false;
        _changed();
      }
    }
  }

  String get conversationId => _conversationId;
  List<String> get suggestedQuestions => _suggestedQuestions;
  List<DifyJson> get chatTree => _chatTree;
  String? get targetMessageId => _targetMessageId;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _setResponding(bool v) {
    _isResponding = v;
    _changed();
  }

  void setTargetMessageId(String? id) {
    _targetMessageId = id;
    _changed();
  }

  void _setTree(List<DifyJson> tree) {
    _chatTree = tree;
    _changed();
  }

  List<DifyJson>? _thread;
  List<DifyJson>? _threadTree;
  String? _threadTarget;

  /// `threadMessages` (memoized on the tree and the target, as Dify's useMemo).
  List<DifyJson> get threadMessages {
    if (_thread == null || !identical(_threadTree, _chatTree) || _threadTarget != _targetMessageId) {
      _threadTree = _chatTree;
      _threadTarget = _targetMessageId;
      _thread = getThreadMessages(_chatTree, _targetMessageId);
    }
    return _thread!;
  }

  String _intro(String s) =>
      processOpeningStatement(s, _formSettings?.inputs ?? const {}, _formSettings?.inputsForm ?? const []);

  DifyJson? _opening;
  String? _openingKey;
  DifyJson? _merged;
  (DifyJson, DifyJson)? _mergedKey;

  /// `openingStatementItem`: the same object while its content and suggestions stay the same.
  DifyJson? get _openingStatementItem {
    final opening = _config?['opening_statement'];
    if (opening is! String || opening.isEmpty) return null;
    final questions = _config?['suggested_questions'];
    final content = _intro(opening);
    final suggestions = questions is List ? [for (final q in questions) _intro('$q')] : null;
    final key = jsonEncode([content, suggestions]);
    if (_opening == null || _openingKey != key) {
      _openingKey = key;
      _opening = {
        'id': 'opening-statement',
        'content': content,
        'isAnswer': true,
        'isOpeningStatement': true,
        'suggestedQuestions': suggestions,
      };
    }
    return _opening;
  }

  /// The messages shown: the thread, the opening statement first (the thread's own opener takes its content).
  List<DifyJson> get chatList {
    final thread = threadMessages;
    final ret = [...thread];
    final opening = _openingStatementItem;
    if (opening != null) {
      final index = thread.indexWhere((m) => m['isOpeningStatement'] == true);
      if (index > -1) {
        final opener = thread[index];
        final key = _mergedKey;
        if (_merged == null || key == null || !identical(key.$1, opener) || !identical(key.$2, opening)) {
          _mergedKey = (opener, opening);
          _merged = {...opener, 'content': opening['content'], 'suggestedQuestions': opening['suggestedQuestions']};
        }
        ret[index] = _merged!;
      } else {
        ret.insert(0, opening);
      }
    }
    return ret;
  }

  /// `produceChatTreeNode`: the tree with [operation] applied to (a copy of) the node [targetId]; as immer, the
  /// nodes on its path are copied, everything else is shared.
  List<DifyJson> _produceChatTreeNode(String targetId, void Function(DifyJson node) operation) {
    List<DifyJson>? walk(List<DifyJson> nodes) {
      for (var i = 0; i < nodes.length; i++) {
        if (nodes[i]['id'] == targetId) {
          final copy = {...nodes[i]};
          operation(copy);
          return [...nodes]..[i] = copy;
        }
      }
      for (var i = 0; i < nodes.length; i++) {
        final children = _children(nodes[i]);
        if (children.isEmpty) continue;
        final next = walk(children);
        if (next != null) return [...nodes]..[i] = {...nodes[i], 'children': next};
      }
      return null;
    }

    return walk(_chatTree) ?? _chatTree;
  }

  /// `updateChatTreeNode`.
  void updateChatTreeNode(String id, void Function(DifyJson node) update) => _setTree(_produceChatTreeNode(id, update));

  /// `handleStop`.
  void handleStop() {
    _hasStopResponded = true;
    _setResponding(false);
    if (stopChat != null && _taskId.isNotEmpty) stopChat!(_taskId);
    store
      ..setIterTimes(defaultIterTimes)
      ..setLoopTimes(defaultLoopTimes);
    _suggestedQuestionsAbort?.call();
    _workflowEventsAbort?.abort();
  }

  /// `handleRestart`: a new conversation.
  void handleRestart() {
    _conversationEpoch++;
    _restoring = false;
    handleStop(); // Keep the accepted task id until its stop request has been sent.
    _conversationId = '';
    unawaited(service.rememberChatConversation(''));
    _taskId = '';
    _chatTree = [];
    _suggestedQuestions = const [];
    _changed();
  }

  /// `updateCurrentQAOnTree`. [treeAtSend] is the tree when the message was sent (Dify's callback closes over it).
  void _updateCurrentQAOnTree({
    required List<DifyJson> treeAtSend,
    String? parentId,
    required DifyJson responseItem,
    required String placeholderQuestionId,
    required DifyJson questionItem,
  }) {
    // Shallow, as Dify's spread: the answer's lists are shared with the response being streamed.
    final currentQA = <String, Object?>{
      ...questionItem,
      'children': <DifyJson>[
        {...responseItem, 'children': <DifyJson>[]},
      ],
    };
    final ids = [placeholderQuestionId, questionItem['id']];
    if (parentId == null && !treeAtSend.any((item) => ids.contains(item['id']))) {
      _setTree([...treeAtSend, currentQA]);
    } else {
      _setTree(
        _produceChatTreeNode(parentId ?? '', (parent) {
          final children = [..._children(parent)];
          final i = children.indexWhere((c) => ids.contains(c['id']));
          if (i == -1) {
            children.add(currentQA);
          } else {
            children[i] = currentQA;
          }
          parent['children'] = children;
        }),
      );
    }
  }

  /// ChatWrapper's `fetchSuggestedQuestions` through the service (its request cannot be cancelled: the answer is
  /// dropped after an abort).
  Future<List<String>> _suggested(String messageId, void Function(VoidCallback abort) getAbortController) {
    var aborted = false;
    getAbortController(() => aborted = true);
    return service.fetchSuggestedQuestions(messageId).then((v) => aborted ? throw StateError('aborted') : v);
  }

  bool get _suggestedEnabled {
    final s = _config?['suggested_questions_after_answer'];
    return s is Map && s['enabled'] == true;
  }

  Future<void> _loadSuggested(String messageId, SuggestedQuestionsFetcher? onGetSuggestedQuestions) async {
    if (!_suggestedEnabled || _hasStopResponded || onGetSuggestedQuestions == null) return;
    try {
      final data = await onGetSuggestedQuestions(messageId, (abort) => _suggestedQuestionsAbort = abort);
      _suggestedQuestions = data;
    } catch (_) {
      _suggestedQuestions = const [];
    }
    _changed();
  }

  /// The default `onGetSuggestedQuestions` (ChatWrapper's, through the service).
  SuggestedQuestionsFetcher get defaultSuggestedQuestions => _suggested;

  void _afterCompleted() {
    fetchInspectVars?.call();
    run.invalidAllLastRun();
  }

  static List<DifyJson> _list(DifyJson item, String key) => ((item[key] ??= <DifyJson>[]) as List).cast<DifyJson>();
  static DifyJson _process(DifyJson item) => (item['workflowProcess'] as Map).cast<String, Object?>();
  static List<DifyJson> _processTracing(DifyJson item) => _list(_process(item), 'tracing');

  /// `handleSend(params, {onGetSuggestedQuestions})`: false when it can't send (no run permission, still
  /// responding).
  bool handleSend(DifyJson params, {SuggestedQuestionsFetcher? onGetSuggestedQuestions}) {
    if (!canRun()) return false;
    if (isResponding) {
      toast(DifyToastType.info, DifyI18n.tr('app-debug', 'errorMessage.waitForResponse'));
      return false;
    }
    _conversationEpoch++; // An older asynchronous history read must not replace this newly started turn.
    _workflowEventsAbort?.abort();
    final thread = threadMessages;
    // A request rejected before workflow_started has no server message ID. Its local
    // placeholder stays visible, but must never become a parent on the wire. Walk
    // back through that question to the last accepted answer, preserving branches.
    var parentMessageId = params['parent_message_id'] as String?;
    final seenParents = <String>{};
    while (parentMessageId != null && parentMessageId.startsWith('answer-placeholder-')) {
      if (!seenParents.add(parentMessageId)) {
        parentMessageId = null;
        break;
      }
      final answer = thread.where((m) => m['id'] == parentMessageId).firstOrNull;
      final question = thread.where((m) => m['id'] == answer?['parentMessageId']).firstOrNull;
      parentMessageId = question?['parentMessageId'] as String?;
    }
    final parentMessage = thread.where((m) => m['id'] == parentMessageId).firstOrNull;
    final now = DateTime.now().millisecondsSinceEpoch;
    final placeholderQuestionId = 'question-$now';
    final questionItem = <String, Object?>{
      'id': placeholderQuestionId,
      'content': params['query'],
      'isAnswer': false,
      'message_files': params['files'],
      'parentMessageId': parentMessageId,
    };
    final placeholderAnswerId = 'answer-placeholder-$now';
    final siblingIndex = parentMessage != null ? _children(parentMessage).length : _chatTree.length;
    final treeAtSend = _chatTree;
    _targetMessageId = parentMessage?['id'] as String?;
    _updateCurrentQAOnTree(
      treeAtSend: treeAtSend,
      parentId: parentMessageId,
      responseItem: {
        'id': placeholderAnswerId,
        'content': '',
        'isAnswer': true,
        'parentMessageId': questionItem['id'],
        'siblingIndex': siblingIndex,
      },
      placeholderQuestionId: placeholderQuestionId,
      questionItem: questionItem,
    );
    final responseItem = <String, Object?>{
      'id': placeholderAnswerId,
      'content': '',
      'agent_thoughts': <Object?>[],
      'message_files': <Object?>[],
      'isAnswer': true,
      'parentMessageId': questionItem['id'],
      'siblingIndex': siblingIndex,
      'humanInputFormDataList': <DifyJson>[],
      'humanInputFilledFormDataList': <DifyJson>[],
    };
    _setResponding(true);

    final files = (params['files'] as List?)?.cast<DifyJson>() ?? const [];
    final bodyParams = <String, Object?>{
      'files': [
        for (final f in getProcessedFiles(files)) f['transfer_method'] == 'local_file' ? {...f, 'url': ''} : f,
      ],
      'inputs': getProcessedInputs(
        (params['inputs'] as Map?)?.cast<String, Object?>() ?? const {},
        _formSettings?.inputsForm ?? const [],
      ),
      for (final e in params.entries)
        if (e.key != 'files' && e.key != 'inputs') e.key: e.value,
      if (params.containsKey('parent_message_id')) 'parent_message_id': parentMessageId,
    };
    var hasSetResponseId = false;
    void update() => _updateCurrentQAOnTree(
      treeAtSend: treeAtSend,
      placeholderQuestionId: placeholderQuestionId,
      questionItem: questionItem,
      responseItem: responseItem,
      parentId: parentMessageId,
    );
    void setResponseId(String messageId) {
      questionItem['id'] = 'question-$messageId';
      responseItem['id'] = messageId;
      responseItem['parentMessageId'] = questionItem['id'];
      hasSetResponseId = true;
    }

    unawaited(
      run.handleRun(
        bodyParams,
        callback: RunCallbacks(
          getAbortController: (h) => _workflowEventsAbort = h,
          onData: (message, isFirstMessage, info) {
            responseItem['content'] = '${responseItem['content']}$message';
            final messageId = info.messageId;
            if (messageId != null && messageId.isNotEmpty && !hasSetResponseId) setResponseId(messageId);
            if (isFirstMessage && (info.conversationId?.isNotEmpty ?? false)) {
              _rememberConversation(info.conversationId!);
            }
            _taskId = info.taskId ?? '';
            if (messageId != null && messageId.isNotEmpty) responseItem['id'] = messageId;
            update();
          },
          onReasoning: (e) {
            final d = e.data;
            final content = (responseItem['reasoningContent'] ??= <String, Object?>{}) as Map;
            final key = (d['node_id'] as String?)?.isNotEmpty == true ? d['node_id'] as String : '_';
            final reasoning = d['reasoning'] as String?;
            if (reasoning != null && reasoning.isNotEmpty) content[key] = '${content[key] ?? ''}$reasoning';
            if (d['is_final'] == true) responseItem['reasoningFinished'] = true;
            update();
          },
          onCompleted: ([hasError = false, errorMessage]) {
            _setResponding(false);
            if (runningStatusOf(store.workflowRunningData.value) == WorkflowRunningStatus.paused) return;
            _afterCompleted();
            if (hasError) {
              if (errorMessage != null && errorMessage.isNotEmpty) {
                responseItem['content'] = errorMessage;
                responseItem['isError'] = true;
                update();
              }
              return;
            }
            unawaited(_loadSuggested(responseItem['id'] as String, onGetSuggestedQuestions));
          },
          onMessageEnd: (e) {
            final metadata = e.json['metadata'];
            responseItem['citation'] = (metadata is Map ? metadata['retriever_resources'] : null) ?? <Object?>[];
            final processed = getProcessedFilesFromResponse((e.json['files'] as List?) ?? const []);
            final all = [...((responseItem['allFiles'] as List?) ?? const []).cast<DifyJson>(), ...processed];
            final seen = <Object?>{};
            responseItem['allFiles'] = [
              for (final f in all)
                if (seen.add(f['id'])) f,
            ];
            update();
          },
          onMessageReplace: (e) {
            responseItem['content'] = e.answer;
            if (e.json['reasoning'] is Map) responseItem['reasoningContent'] = e.json['reasoning'];
            if (e.json['files'] is List) {
              responseItem['allFiles'] = getProcessedFilesFromResponse(e.json['files'] as List);
            }
            update();
          },
          onError: (_, [_]) => _setResponding(false),
          onWorkflowStarted: (e) {
            if (e.conversationId?.isNotEmpty ?? false) _rememberConversation(e.conversationId!);
            if ((e.messageId?.isNotEmpty ?? false) && !hasSetResponseId) setResponseId(e.messageId!);
            final process = responseItem['workflowProcess'];
            if (process is Map && (process['tracing'] as List?)?.isNotEmpty == true) {
              _setResponding(true);
              responseItem['workflowProcess'] = {
                ...process.cast<String, Object?>(),
                'status': WorkflowRunningStatus.running,
                'error': null,
              };
            } else {
              _taskId = e.taskId ?? '';
              responseItem['workflow_run_id'] = e.workflowRunId;
              responseItem['workflowProcess'] = <String, Object?>{
                'status': WorkflowRunningStatus.running,
                'tracing': <DifyJson>[],
              };
            }
            update();
          },
          onWorkflowFinished: (e) {
            responseItem['workflowProcess'] = {
              ..._process(responseItem),
              'status': e.data['status'],
              'error': e.data['error'],
            };
            update();
          },
          onIterationStart: (e) {
            _processTracing(responseItem).add({...e.data, 'status': NodeRunningStatus.running});
            update();
          },
          onIterationFinish: (e) {
            final tracing = _processTracing(responseItem);
            final i = tracing.indexWhere((t) => t['id'] == e.data['id']);
            if (i > -1) {
              tracing[i] = {...tracing[i], ...e.data};
              update();
            }
          },
          onLoopStart: (e) {
            _processTracing(responseItem).add({...e.data, 'status': NodeRunningStatus.running});
            update();
          },
          onLoopFinish: (e) {
            final tracing = _processTracing(responseItem);
            final i = tracing.indexWhere((t) => t['id'] == e.data['id']);
            if (i > -1) {
              tracing[i] = {...tracing[i], ...e.data};
              update();
            }
          },
          onNodeStarted: (e) {
            final tracing = _processTracing(responseItem);
            final i = tracing.indexWhere((t) => t['node_id'] == e.data['node_id']);
            if (i > -1) {
              tracing[i] = {...e.data, 'status': NodeRunningStatus.running};
            } else {
              tracing.add({...e.data, 'status': NodeRunningStatus.running});
            }
            update();
          },
          onNodeRetry: (e) {
            _processTracing(responseItem).add({...e.data});
            update();
          },
          onNodeFinished: (e) {
            final tracing = _processTracing(responseItem);
            final i = tracing.indexWhere((t) => t['id'] == e.data['id']);
            if (i > -1) {
              tracing[i] = {...tracing[i], ...e.data};
              update();
            }
          },
          onAgentLog: (e) {
            final tracing = _processTracing(responseItem);
            final i = tracing.indexWhere((t) => t['node_id'] == e.data['node_id']);
            if (i > -1) {
              final current = jsonCopy(tracing[i]);
              _addAgentLog(current, e.data);
              tracing[i] = current;
              update();
            }
          },
          onHumanInputRequired: (e) {
            _upsertForm(responseItem, e.data);
            final tracing = _processTracing(responseItem);
            final i = tracing.indexWhere((t) => t['node_id'] == e.data['node_id']);
            if (i > -1) {
              tracing[i] = {...tracing[i], 'status': NodeRunningStatus.paused};
              update();
            }
          },
          onHumanInputFormFilled: (e) {
            _formFilled(responseItem, e.data);
            update();
          },
          onHumanInputFormTimeout: (e) {
            _formTimeout(responseItem, e.data);
            update();
          },
          onWorkflowPaused: (_) {
            _process(responseItem)['status'] = WorkflowRunningStatus.paused;
            update();
          },
        ),
      ),
    );
    return true;
  }

  static void _addAgentLog(DifyJson current, DifyJson data) {
    final meta = current['execution_metadata'];
    if (meta is Map) {
      final log = meta['agent_log'];
      if (log is List) {
        final j = log.indexWhere((l) => l is Map && l['message_id'] == data['message_id']);
        if (j > -1) {
          log[j] = {...(log[j] as Map).cast<String, Object?>(), ...data};
        } else {
          log.add({...data});
        }
      } else {
        meta['agent_log'] = [
          {...data},
        ];
      }
    } else {
      current['execution_metadata'] = {
        'agent_log': [
          {...data},
        ],
      };
    }
  }

  static void _upsertForm(DifyJson item, DifyJson event) {
    final data = {...event};
    final forms = item['humanInputFormDataList'];
    if (forms is! List) {
      item['humanInputFormDataList'] = [data];
      return;
    }
    final i = forms.indexWhere((f) => f is Map && f['node_id'] == data['node_id']);
    if (i > -1) {
      forms[i] = data;
    } else {
      forms.add(data);
    }
  }

  static void _formFilled(DifyJson item, DifyJson data) {
    DifyJson? required;
    final forms = item['humanInputFormDataList'];
    if (forms is List && forms.isNotEmpty) {
      final i = forms.indexWhere((f) => f is Map && f['node_id'] == data['node_id']);
      if (i > -1) required = (forms.removeAt(i) as Map).cast<String, Object?>();
    }
    final enriched = enrichSubmittedHumanInputFormData(data, required);
    final filled = item['humanInputFilledFormDataList'];
    if (filled is List) {
      filled.add(enriched);
    } else {
      item['humanInputFilledFormDataList'] = [enriched];
    }
  }

  static void _formTimeout(DifyJson item, DifyJson data) {
    final forms = item['humanInputFormDataList'];
    if (forms is List && forms.isNotEmpty) {
      final i = forms.indexWhere((f) => f is Map && f['node_id'] == data['node_id']);
      if (i > -1) (forms[i] as Map)['expiration_time'] = data['expiration_time'];
    }
  }

  /// `getHumanInputNodeData(nodeId)`: the node (not a note) with that id.
  RunGraphNode? getHumanInputNodeData(String nodeId) =>
      graph?.nodes.where((n) => n.rfType == 'custom' && n.id == nodeId).firstOrNull;

  /// `handleSubmitHumanInputForm`.
  Future<void> handleSubmitHumanInputForm(String formToken, DifyJson formData) =>
      service.submitHumanInputForm(formToken, formData);

  /// `handleResume(messageId, workflowRunId)`: follows a paused run's events again for that message.
  void handleResume(
    String messageId,
    String workflowRunId, {
    SuggestedQuestionsFetcher? onGetSuggestedQuestions,
  }) {
    void upd(void Function(DifyJson item) f) => updateChatTreeNode(messageId, f);
    final callbacks = RunCallbacks(
      getAbortController: (h) => _workflowEventsAbort = h,
      onData: (message, _, info) {
        upd((item) {
          item['content'] = '${item['content'] ?? ''}$message';
          if (info.messageId?.isNotEmpty ?? false) item['id'] = info.messageId;
        });
        if (info.conversationId?.isNotEmpty ?? false) _rememberConversation(info.conversationId!);
        if (info.taskId?.isNotEmpty ?? false) _taskId = info.taskId!;
      },
      onReasoning: (e) {
        final d = e.data;
        updateChatTreeNode(d['message_id'] as String? ?? '', (item) {
          final content = (item['reasoningContent'] ??= <String, Object?>{}) as Map;
          final key = (d['node_id'] as String?)?.isNotEmpty == true ? d['node_id'] as String : '_';
          final reasoning = d['reasoning'] as String?;
          if (reasoning != null && reasoning.isNotEmpty) content[key] = '${content[key] ?? ''}$reasoning';
          if (d['is_final'] == true) item['reasoningFinished'] = true;
        });
      },
      onCompleted: ([hasError = false, _]) {
        _setResponding(false);
        if (runningStatusOf(store.workflowRunningData.value) == WorkflowRunningStatus.paused) return;
        _afterCompleted();
        if (hasError) return;
        unawaited(_loadSuggested(messageId, onGetSuggestedQuestions));
      },
      onMessageEnd: (e) => upd((item) {
        final metadata = e.json['metadata'];
        item['citation'] = (metadata is Map ? metadata['retriever_resources'] : null) ?? <Object?>[];
        final processed = getProcessedFilesFromResponse((e.json['files'] as List?) ?? const []);
        final all = [...((item['allFiles'] as List?) ?? const []).cast<DifyJson>(), ...processed];
        final seen = <Object?>{};
        item['allFiles'] = [
          for (final f in all)
            if (seen.add(f['id'])) f,
        ];
      }),
      onMessageReplace: (e) => upd((item) {
        item['content'] = e.answer;
        if (e.json['reasoning'] is Map) item['reasoningContent'] = e.json['reasoning'];
        if (e.json['files'] is List) item['allFiles'] = getProcessedFilesFromResponse(e.json['files'] as List);
      }),
      onError: (_, [_]) => _setResponding(false),
      onWorkflowStarted: (e) {
        _setResponding(true);
        _hasStopResponded = false;
        upd((item) {
          final process = item['workflowProcess'];
          if (process is Map && (process['tracing'] as List?)?.isNotEmpty == true) {
            item['workflowProcess'] = {
              ...process.cast<String, Object?>(),
              'status': WorkflowRunningStatus.running,
              'error': null,
            };
          } else {
            _taskId = e.taskId ?? '';
            item['workflow_run_id'] = e.workflowRunId;
            item['workflowProcess'] = <String, Object?>{
              'status': WorkflowRunningStatus.running,
              'tracing': <DifyJson>[],
            };
          }
        });
      },
      onWorkflowFinished: (e) => upd((item) {
        final process = item['workflowProcess'];
        if (process is Map) {
          item['workflowProcess'] = {
            ...process.cast<String, Object?>(),
            'status': e.data['status'],
            'error': e.data['error'],
          };
        }
      }),
      onIterationStart: (e) => upd((item) {
        if (item['workflowProcess'] is! Map) return;
        _processTracing(item).add({...e.data, 'status': WorkflowRunningStatus.running});
      }),
      onIterationFinish: (e) => upd((item) => _finishContainer(item, e.data)),
      onNodeStarted: (e) => upd((item) {
        if (item['workflowProcess'] is! Map) return;
        final tracing = _processTracing(item);
        final i = tracing.indexWhere((t) => t['node_id'] == e.data['node_id']);
        if (i > -1) {
          tracing[i] = {...e.data, 'status': NodeRunningStatus.running};
        } else {
          if (e.data['iteration_id'] != null) return;
          tracing.add({...e.data, 'status': WorkflowRunningStatus.running});
        }
      }),
      onNodeFinished: (e) => upd((item) {
        final process = item['workflowProcess'];
        if (process is! Map || process['tracing'] is! List) return;
        if (e.data['iteration_id'] != null) return;
        final tracing = _processTracing(item);
        final parallelId = (e.data['execution_metadata'] as Map?)?['parallel_id'];
        final i = tracing.indexWhere((t) {
          final tp = (t['execution_metadata'] as Map?)?['parallel_id'];
          if (tp == null) return t['id'] == e.data['id'];
          return t['id'] == e.data['id'] && tp == parallelId;
        });
        if (i > -1) tracing[i] = {...e.data};
      }),
      onLoopStart: (e) => upd((item) {
        if (item['workflowProcess'] is! Map) return;
        _processTracing(item).add({...e.data, 'status': WorkflowRunningStatus.running});
      }),
      onLoopFinish: (e) => upd((item) => _finishContainer(item, e.data)),
      onHumanInputRequired: (e) => upd((item) {
        _upsertForm(item, e.data);
        final process = item['workflowProcess'];
        if (process is Map && process['tracing'] is List) {
          final tracing = _processTracing(item);
          final i = tracing.indexWhere((t) => t['node_id'] == e.data['node_id']);
          if (i > -1) tracing[i]['status'] = NodeRunningStatus.paused;
        }
      }),
      onHumanInputFormFilled: (e) => upd((item) => _formFilled(item, e.data)),
      onHumanInputFormTimeout: (e) => upd((item) => _formTimeout(item, e.data)),
      onWorkflowPaused: (_) => upd((item) {
        final process = item['workflowProcess'];
        if (process is Map) process['status'] = WorkflowRunningStatus.paused;
      }),
    );
    _workflowEventsAbort?.abort();
    resumeStream(workflowRunId, callbacks);
  }

  static void _finishContainer(DifyJson item, DifyJson data) {
    final process = item['workflowProcess'];
    if (process is! Map || process['tracing'] is! List) return;
    final tracing = _processTracing(item);
    final parallelId = (data['execution_metadata'] as Map?)?['parallel_id'];
    final i = tracing.indexWhere(
      (t) =>
          t['node_id'] == data['node_id'] &&
          ((t['execution_metadata'] as Map?)?['parallel_id'] == parallelId || t['parallel_id'] == parallelId),
    );
    if (i > -1) tracing[i] = {...tracing[i], ...data, 'status': WorkflowRunningStatus.succeeded};
  }

  /// `handleSwitchSibling`: shows another answer; resumes it when it waits for human input.
  void handleSwitchSibling(
    String siblingMessageId, {
    SuggestedQuestionsFetcher? onGetSuggestedQuestions,
  }) {
    setTargetMessageId(siblingMessageId);
    DifyJson? find(List<DifyJson> nodes) {
      for (final n in nodes) {
        if (n['id'] == siblingMessageId) return n;
        final found = find(_children(n));
        if (found != null) return found;
      }
      return null;
    }

    final target = find(_chatTree);
    final runId = target?['workflow_run_id'] as String?;
    final forms = target?['humanInputFormDataList'];
    if (runId != null && runId.isNotEmpty && forms is List && forms.isNotEmpty) {
      handleResume(target!['id'] as String, runId, onGetSuggestedQuestions: onGetSuggestedQuestions);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _workflowEventsAbort?.abort();
    super.dispose();
  }
}
