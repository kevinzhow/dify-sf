// dify-spec: web/app/components/app/log/__tests__/list-utils.spec.ts
import 'package:dify_sf_app/src/app_detail/logs/list_utils.dart';
import 'package:dify_sf_app/src/app_detail/logs/logs_data.dart';
import 'package:flutter_test/flutter_test.dart';

List<Json> createChatItems() => [
  {'id': 'question-1', 'content': 'hello', 'isAnswer': false},
  {'id': 'answer-1', 'content': 'world', 'isAnswer': true, 'parentMessageId': 'question-1'},
  {'id': 'question-2', 'content': 'next', 'isAnswer': false, 'parentMessageId': 'answer-1'},
  {'id': 'answer-2', 'content': 'reply', 'isAnswer': true, 'parentMessageId': 'question-2'},
];

void main() {
  group('log list utils', () {
    test('should format chat messages into paired question and answer items', () {
      final items = getFormattedChatList(
        [
          {
            'id': 'message-1',
            'inputs': {'query': 'hello'},
            'query': 'hello',
            'answer': 'world',
            'created_at': 1710000000,
            'answer_tokens': 3,
            'message_tokens': 2,
            'message': [
              {'role': 'user', 'text': 'hello'},
            ],
            'message_files': [
              {'belongs_to': 'assistant', 'id': 'file-1'},
              {'belongs_to': 'user', 'id': 'file-2'},
            ],
          },
        ],
        'conversation-1',
        'YYYY-MM-DD',
      );
      expect(items, hasLength(2));
      expect(items[0], allOf(containsPair('id', 'question-message-1'), containsPair('content', 'hello')));
      expect(items[0], containsPair('isAnswer', false));
      expect(items[1], allOf(containsPair('id', 'message-1'), containsPair('content', 'world')));
      expect(items[1], allOf(containsPair('isAnswer', true), containsPair('conversationId', 'conversation-1')));
    });

    test('should preserve feedback and annotation hit history when formatting chat items', () {
      final items = getFormattedChatList(
        [
          {
            'id': 'message-2',
            'inputs': {'default_input': 'fallback prompt'},
            'query': '',
            'answer': 'answer',
            'created_at': 1710000000,
            'answer_tokens': 1,
            'message_tokens': 1,
            'message': [
              {'role': 'assistant', 'text': 'answer'},
            ],
            'feedbacks': [
              {'from_source': 'user', 'rating': 'like'},
              {'from_source': 'admin', 'rating': 'dislike'},
            ],
            'annotation_hit_history': {
              'annotation_id': 'annotation-1',
              'annotation_create_account': {},
              'created_at': 123,
            },
          },
        ],
        'conversation-2',
        'YYYY-MM-DD',
      );
      expect(items[0]['content'], 'fallback prompt');
      expect((items[1]['feedback']! as Map)['rating'], 'like');
      expect((items[1]['adminFeedback']! as Map)['rating'], 'dislike');
      expect(items[1]['annotation'], {'id': 'annotation-1', 'authorName': 'N/A', 'created_at': 123});
    });

    test('should merge unique chat items and handle pagination retries', () {
      final prevItems = createChatItems();
      final merged = mergeUniqueChatItems(prevItems, [
        {'id': 'answer-2', 'content': 'reply', 'isAnswer': true},
        {'id': 'answer-3', 'content': 'final', 'isAnswer': true},
      ]);
      expect([for (final i in merged) i['id']], ['answer-3', 'question-1', 'answer-1', 'question-2', 'answer-2']);
      final retry = mergePaginatedChatItems(maxRetryCount: 3, newItems: const [], prevItems: prevItems, retryCount: 1);
      expect(retry.items, same(prevItems));
      expect(retry.retryCount, 2);
      final giveUp = mergePaginatedChatItems(maxRetryCount: 3, newItems: const [], prevItems: prevItems, retryCount: 3);
      expect(giveUp.items, same(prevItems));
      expect(giveUp.retryCount, 0);
    });

    test('should build thread state and support switching siblings', () {
      final state = buildChatThreadState(allChatItems: createChatItems(), hasMore: false, introduction: 'intro');
      expect(
        state.chatItemTree[0],
        allOf(containsPair('id', 'introduction'), containsPair('isOpeningStatement', true)),
      );
      expect(state.oldestAnswerId, 'answer-1');
      expect(getThreadChatItems(state.chatItemTree, 'answer-2').last['id'], 'answer-2');
    });

    test('should return an empty thread state when there are no chat items', () {
      final state = buildChatThreadState(allChatItems: const [], hasMore: true);
      expect(state.chatItemTree, isEmpty);
      expect(state.oldestAnswerId, isNull);
      expect(state.threadChatItems, isEmpty);
    });

    test('should update annotation state helpers', () {
      final items = createChatItems();
      expect(applyAnnotationEdited(items, 'updated question', 'updated answer', 1)[0]['content'], 'updated question');
      expect(
        applyAnnotationAdded(items, 'annotation-1', 'Dify', 'question', 'answer', 1)[1]['annotation'],
        allOf(containsPair('id', 'annotation-1'), containsPair('authorName', 'Dify')),
      );
      expect(applyAnnotationRemoved(items, 1)[1]['annotation'], isNull);
    });

    test('should derive urls, scroll thresholds, row values, and detail metadata', () {
      expect(isNearTopLoadMore(clientHeight: 200, scrollHeight: 600, scrollTop: -380), isTrue);
      final row = getConversationRowValues(
        isChatMode: false,
        log: {
          'from_account_name': 'demo-user',
          'message': {
            'inputs': {'query': 'hello'},
            'answer': 'world',
          },
        },
        noChatLabel: 'no chat',
        noOutputLabel: 'no output',
      );
      expect(row, (
        endUser: 'demo-user',
        isLeftEmpty: false,
        isRightEmpty: false,
        leftValue: 'hello',
        rightValue: 'world',
      ));
      expect(
        getDetailVarList({
          'model_config': {
            'user_input_form': [
              {
                'text_input': {'variable': 'query'},
              },
            ],
          },
          'message': {
            'inputs': {'query': 'fallback value'},
          },
        }, {}),
        [(label: 'query', value: 'fallback value')],
      );
      expect(
        getCompletionMessageFiles({
          'message': {
            'message_files': [
              {'url': 'https://example.com/file-1'},
            ],
          },
        }, false),
        ['https://example.com/file-1'],
      );
    });

    test('should handle default inputs', () {
      final row = getConversationRowValues(
        isChatMode: false,
        log: {
          'from_end_user_session_id': 'session-1',
          'message': {
            'inputs': {'default_input': 'fallback input'},
            'answer': 0,
          },
        },
        noChatLabel: 'no chat',
        noOutputLabel: 'no output',
      );
      expect(row, (
        endUser: 'session-1',
        isLeftEmpty: false,
        isRightEmpty: true,
        leftValue: 'fallback input',
        rightValue: 0,
      ));
    });
  });
}
