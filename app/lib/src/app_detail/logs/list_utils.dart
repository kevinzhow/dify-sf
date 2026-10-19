/// log/list-utils.ts (Dify 1.17.1): the conversation drawer's chat items (paired question / answer items with
/// feedback, annotations and run ids), their merging across pages, the thread state, the annotation helpers, the
/// table's row values and the detail's variables.
library;

import '../../workflow_editor/header/format.dart' show formatTime;
import '../../workflow_editor/run/debug_chat.dart' show getThreadMessages;
import '../../workflow_editor/run/ui/run_panels.dart' show buildChatItemTree;
import '../../workflow_editor/variable_inspect/value_content_helpers.dart' show getProcessedFilesFromResponse;
import 'logs_data.dart';

List<Json> _files(Json m, String belongsTo) => getProcessedFilesFromResponse([
  for (final f in (m['message_files'] as List? ?? const []))
    if (f is Map && f['belongs_to'] == belongsTo)
      {
        'related_id': f['id'] ?? f['upload_file_id'],
        'extension': '',
        'filename': '',
        'size': 0,
        'mime_type': '',
        'transfer_method': f['transfer_method'],
        'type': f['type'],
        'url': f['url'],
        'upload_file_id': f['upload_file_id'],
        'remote_url': f['url'],
      },
]);

bool _truthy(Object? v) => v != null && v != '' && v != 0 && v != false;

Object? _or(Iterable<Object? Function()> values) {
  Object? last;
  for (final v in values) {
    last = v();
    if (_truthy(last)) return last;
  }
  return last;
}

/// `getFormattedChatList`: each message as a question item (`question-<id>`) and an answer item (the message id),
/// the answer with the user's and the admin's feedback, the prompt log, `more` (time in [format], tokens, latency),
/// citations and the annotation (a hit's or the message's own).
List<Json> getFormattedChatList(List<Json> messages, String conversationId, String format) {
  final out = <Json>[];
  for (final item in messages) {
    final inputs = (item['inputs'] as Map?)?.cast<String, Object?>() ?? const {};
    out.add({
      'id': 'question-${item['id']}',
      'content': _or([() => inputs['query'], () => inputs['default_input'], () => item['query']]),
      'isAnswer': false,
      'message_files': _files(item, 'user'),
      'parentMessageId': _truthy(item['parent_message_id']) ? item['parent_message_id'] : null,
    });
    final feedbacks = (item['feedbacks'] as List? ?? const []).whereType<Map>().map((f) => f.cast<String, Object?>());
    final log = [...(item['message'] as List? ?? const [])];
    if (log.isEmpty || (log.last is Map && (log.last as Map)['role'] != 'assistant')) {
      log.add({
        'role': 'assistant',
        'text': item['answer'],
        'files': [
          for (final f in (item['message_files'] as List? ?? const []))
            if (f is Map && f['belongs_to'] == 'assistant') f,
        ],
      });
    }
    final hit = item['annotation_hit_history'] as Map?;
    final annotation = item['annotation'] as Map?;
    out.add({
      'id': item['id'],
      'content': item['answer'],
      'agent_thoughts': item['agent_thoughts'],
      'feedback': feedbacks.where((f) => f['from_source'] == 'user').firstOrNull,
      'adminFeedback': feedbacks.where((f) => f['from_source'] == 'admin').firstOrNull,
      'feedbackDisabled': false,
      'isAnswer': true,
      'message_files': _files(item, 'assistant'),
      'log': log,
      'workflow_run_id': item['workflow_run_id'],
      'conversationId': conversationId,
      'input': {'inputs': inputs, 'query': item['query']},
      'more': {
        'time': formatTime(((item['created_at'] as num?) ?? 0).toInt(), format),
        'tokens': ((item['answer_tokens'] as num?) ?? 0) + ((item['message_tokens'] as num?) ?? 0),
        'latency': ((item['provider_response_latency'] as num?) ?? 0).toStringAsFixed(2),
      },
      'citation': (item['metadata'] as Map?)?['retriever_resources'],
      'annotation': hit != null
          ? {
              'id': hit['annotation_id'],
              'authorName': (hit['annotation_create_account'] as Map?)?['name'] ?? 'N/A',
              'created_at': hit['created_at'],
            }
          : annotation != null
          ? {
              'id': annotation['id'],
              'authorName': (annotation['account'] as Map?)?['name'],
              'logAnnotation': annotation,
              'created_at': 0,
            }
          : null,
      'parentMessageId': 'question-${item['id']}',
    });
  }
  return out;
}

/// `mergeUniqueChatItems`: the new items not already in [prev], before them.
List<Json> mergeUniqueChatItems(List<Json> prev, List<Json> next) {
  final ids = {for (final i in prev) i['id']};
  return [...next.where((i) => !ids.contains(i['id'])), ...prev];
}

/// `mergePaginatedChatItems`: like [mergeUniqueChatItems]; a page with nothing new retries up to [maxRetryCount]
/// times (while there are older items), then gives up (`retryCount` back to 0).
({List<Json> items, int retryCount}) mergePaginatedChatItems({
  required int maxRetryCount,
  required List<Json> newItems,
  required List<Json> prevItems,
  required int retryCount,
}) {
  final ids = {for (final i in prevItems) i['id']};
  final unique = newItems.where((i) => !ids.contains(i['id'])).toList();
  if (unique.isEmpty) {
    if (retryCount < maxRetryCount && prevItems.length > 1) return (items: prevItems, retryCount: retryCount + 1);
    return (items: prevItems, retryCount: 0);
  }
  return (items: [...unique, ...prevItems], retryCount: 0);
}

/// `buildChatThreadState`: the tree (under the opening statement once every page is loaded and there is an
/// [introduction]), the thread to the last item, and the oldest answer (the next page's `first_id`).
({List<Json> chatItemTree, String? oldestAnswerId, List<Json> threadChatItems}) buildChatThreadState({
  required List<Json> allChatItems,
  required bool hasMore,
  String? introduction,
}) {
  if (allChatItems.isEmpty) return (chatItemTree: const [], oldestAnswerId: null, threadChatItems: const []);
  var tree = buildChatItemTree(allChatItems);
  if (!hasMore && introduction != null && introduction.isNotEmpty) {
    tree = [
      {
        'id': 'introduction',
        'isAnswer': true,
        'isOpeningStatement': true,
        'content': introduction,
        'feedbackDisabled': true,
        'children': tree,
      },
    ];
  }
  return (
    chatItemTree: tree,
    oldestAnswerId: allChatItems.where((i) => i['isAnswer'] == true).firstOrNull?['id'] as String?,
    threadChatItems: getThreadMessages(tree, allChatItems.last['id'] as String?),
  );
}

/// `getThreadChatItems`.
List<Json> getThreadChatItems(List<Json> tree, String siblingMessageId) => getThreadMessages(tree, siblingMessageId);

/// `applyAnnotationEdited`: the question before [index] gets [query], the answer's annotation [answer].
List<Json> applyAnnotationEdited(List<Json> items, String query, String answer, int index) => [
  for (final (i, item) in items.indexed)
    if (i == index - 1)
      {...item, 'content': query}
    else if (i == index)
      {
        ...item,
        'annotation': {
          ...?(item['annotation'] as Map?)?.cast<String, Object?>(),
          'logAnnotation': {
            ...?((item['annotation'] as Map?)?['logAnnotation'] as Map?)?.cast<String, Object?>(),
            'content': answer,
          },
        },
      }
    else
      item,
];

/// `applyAnnotationAdded`.
List<Json> applyAnnotationAdded(
  List<Json> items,
  String annotationId,
  String authorName,
  String query,
  String answer,
  int index,
) => [
  for (final (i, item) in items.indexed)
    if (i == index - 1)
      {...item, 'content': query}
    else if (i == index)
      {
        ...item,
        'annotation': {
          'id': annotationId,
          'authorName': authorName,
          'logAnnotation': {
            'content': answer,
            'account': {'id': '', 'name': authorName, 'email': ''},
          },
        },
      }
    else
      item,
];

/// `applyAnnotationRemoved`.
List<Json> applyAnnotationRemoved(List<Json> items, int index) => [
  for (final (i, item) in items.indexed)
    if (i == index) ({...item}..remove('annotation')) else item,
];

/// `isNearTopLoadMore` (the drawer scrolls `column-reverse`, so the top is a negative offset).
bool isNearTopLoadMore({required double clientHeight, required double scrollHeight, required double scrollTop}) =>
    scrollTop.abs() > scrollHeight - clientHeight - 40;

Object? _get(Json m, String path) {
  Object? v = m;
  for (final p in path.split('.')) {
    v = v is Map ? v[p] : null;
  }
  return v;
}

/// `getConversationRowValues`: the end user (session, else account), the left cell (the title; for completions the
/// query), the right cell (message count; for completions the answer), with their empty labels.
({Object? endUser, bool isLeftEmpty, bool isRightEmpty, Object? leftValue, Object? rightValue})
getConversationRowValues({
  required bool isChatMode,
  required Json log,
  required String noChatLabel,
  required String noOutputLabel,
}) {
  final endUser = _or([() => log['from_end_user_session_id'], () => log['from_account_name']]);
  var left = _get(log, isChatMode ? 'name' : 'message.inputs.query');
  if (!_truthy(left)) {
    left = !isChatMode ? _or([() => _get(log, 'message.query'), () => _get(log, 'message.inputs.default_input')]) : '';
  }
  if (!_truthy(left)) left = '';
  final right = _get(log, isChatMode ? 'message_count' : 'message.answer');
  return (
    endUser: _truthy(endUser) ? endUser : null,
    isLeftEmpty: !_truthy(left),
    isRightEmpty: !_truthy(right),
    leftValue: _truthy(left) ? left : noChatLabel,
    rightValue: right == 0 ? 0 : (_truthy(right) ? right : noOutputLabel),
  );
}

/// `getDetailVarList`: the start form's variables with their values (the latest page's inputs, else the detail's).
List<({String label, String value})> getDetailVarList(Json detail, Map<String, Object?> varValues) {
  final form = _get(detail, 'model_config.user_input_form');
  if (form is! List) return const [];
  return [
    for (final item in form)
      if (item is Map && item.values.firstOrNull is Map)
        if ((item.values.first as Map)['variable'] case final String variable)
          if ((varValues[variable] ?? _get(detail, 'message.inputs.$variable')) case final String value)
            (label: variable, value: value),
  ];
}

/// `getCompletionMessageFiles`: the completion's file urls (none for chats).
List<String> getCompletionMessageFiles(Json detail, bool isChatMode) {
  final files = _get(detail, 'message.message_files');
  if (isChatMode || files is! List || files.isEmpty) return const [];
  return [
    for (final f in files)
      if (f is Map && f['url'] is String && (f['url'] as String).isNotEmpty) f['url'] as String,
  ];
}
