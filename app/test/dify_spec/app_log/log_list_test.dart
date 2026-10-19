// dify-spec: web/app/components/app/log/__tests__/list.spec.tsx
import 'package:collab_client/collab_client.dart' show AppInfo;
import 'package:dify_sf_app/src/app_detail/logs/chat_log.dart';
import 'package:dify_sf_app/src/app_detail/logs/log_widgets.dart';
import 'package:dify_sf_app/src/app_detail/logs/logs_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Json createLogs() => {
  'data': [
    {
      'id': 'conversation-1',
      'name': 'hello world',
      'from_account_name': 'demo-user',
      'read_at': null,
      'message_count': 2,
      'user_feedback_stats': {'like': 0, 'dislike': 0},
      'admin_feedback_stats': {'like': 0, 'dislike': 0},
      'updated_at': 1710000000,
      'created_at': 1710000000,
      'annotated': false,
    },
  ],
};

Json createChatMessage(String id, [Json overrides = const {}]) => {
  'id': id,
  'answer': 'Assistant reply $id',
  'query': 'Question $id',
  'created_at': 1710000000,
  'inputs': {'query': 'Question $id'},
  'feedbacks': const <Json>[],
  'message': const <Json>[],
  'message_files': const <Json>[],
  'answer_tokens': 10,
  'message_tokens': 5,
  'parent_message_id': null,
  ...overrides,
};

Json detail({List<Json> form = const []}) => {
  'id': 'conversation-1',
  'created_at': 1710000000,
  'model_config': {
    'model': 'gpt-4o',
    'configs': {'introduction': 'Hello there'},
    'user_input_form': form,
  },
  'message': {
    'inputs': {if (form.isNotEmpty) 'query': 'Latest question'},
  },
};

void main() {
  late RecordingLogsSource source;
  late int refreshes;
  late List<String?> urlUpdates;
  LogChatProps? chat;
  setUp(() {
    source = RecordingLogsSource();
    refreshes = 0;
    urlUpdates = [];
    chat = null;
  });

  /// Dify's mocked `Chat`: the item count and the props.
  Widget chatPanel(BuildContext context, LogChatProps props) {
    chat = props;
    return SizedBox(
      key: const ValueKey('chat-panel'),
      height: 2000,
      child: Text('${props.chatList.length}', key: const ValueKey('chat-panel-count')),
    );
  }

  Future<void> renderList(WidgetTester t, {AppInfo? app, Json? logs, String? conversationId}) => renderLog(
    t,
    SingleChildScrollView(
      child: ConversationList(
        logs: logs ?? createLogs(),
        app: app ?? mockApp(id: 'app-1', mode: 'chat'),
        source: source,
        onRefresh: () => refreshes++,
        conversationId: conversationId,
        onConversationIdChange: urlUpdates.add,
        chatBuilder: chatPanel,
      ),
    ),
  );

  bool drawerOpen() => find.byKey(const ValueKey('log-drawer')).evaluate().isNotEmpty;

  group('ConversationList', () {
    testWidgets('should render chat rows and push the conversation id into the url when a row is clicked', (t) async {
      await renderList(t);
      expect(find.text('hello world'), findsOneWidget);
      // `formatTime(created_at, t('dateTimeFormat'))` twice (updated and created), with the echoed format.
      expect(find.text('app-log.dateTimeFormat'), findsNWidgets(2));
      await t.tap(find.text('hello world'));
      await settle(t);
      expect(drawerOpen(), isTrue);
      expect(urlUpdates, ['conversation-1']);
    });

    testWidgets('restores focus to the conversation entry after %s opening', (t) async {
      for (final opening in ['keyboard', 'row']) {
        refreshes = 0;
        urlUpdates.clear();
        await renderList(t);
        final trigger = t.widget<LogDrawerTrigger>(find.byType(LogDrawerTrigger));
        if (opening == 'keyboard') {
          trigger.focusNode!.requestFocus();
          await t.pump();
          await t.sendKeyEvent(LogicalKeyboardKey.enter);
        } else {
          await t.tap(find.text('hello world'));
        }
        await settle(t);
        expect(drawerOpen(), isTrue, reason: opening);
        expect(urlUpdates.last, 'conversation-1');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t);
        expect(drawerOpen(), isFalse, reason: opening);
        expect(trigger.focusNode!.hasFocus, isTrue, reason: opening);
        expect(refreshes, 1);
        expect(urlUpdates.last, isNull);
      }
    });

    testWidgets('should close the drawer, refresh, and clear modal flags', (t) async {
      source.conversation = detail();
      await renderList(t, conversationId: 'conversation-1');
      expect(drawerOpen(), isTrue);
      await tapButton(t, 'common.operation.close');
      expect(refreshes, 1);
      expect(drawerOpen(), isFalse);
      expect(urlUpdates.last, isNull);
    });

    testWidgets('should render chat conversation details and submit feedback from the chat panel', (t) async {
      source.conversation = detail(
        form: [
          {
            'query': {'variable': 'query'},
          },
        ],
      );
      source.messagePages.add({
        'data': [
          {
            'id': 'message-1',
            'answer': 'Assistant reply',
            'query': 'Latest question',
            'created_at': 1710000000,
            'inputs': {'query': 'Latest question'},
            'feedbacks': const <Json>[],
            'message': const <Json>[],
            'message_files': const <Json>[],
          },
        ],
        'has_more': false,
      });
      await renderList(t, conversationId: 'conversation-1');
      expect(source.chatMessagesCalls.first, {'conversation_id': 'conversation-1', 'limit': 10});
      expect(find.byKey(const ValueKey('chat-panel')), findsOneWidget);
      final vars = t.widget<LogVarPanel>(find.byType(LogVarPanel)).varList;
      expect(vars, [(label: 'query', value: 'Latest question')]);
      expect(chat!.hideLogModal, isTrue);
      await chat!.onFeedback('message-1', {'rating': 'like', 'content': 'nice'});
      await settle(t);
      expect(source.feedbackCalls.single.appId, 'app-1');
      expect(source.feedbackCalls.single.body, {'message_id': 'message-1', 'rating': 'like', 'content': 'nice'});
    });

    testWidgets('should expose run details only for %s conversation answers', (t) async {
      for (final (mode, expected) in [('chat', false), ('agent-chat', false), ('advanced-chat', true)]) {
        source.conversation = detail();
        source.messagePages.add({
          'data': [createChatMessage('message-1')],
          'has_more': false,
        });
        await renderList(
          t,
          app: mockApp(id: 'app-1', mode: mode),
          conversationId: 'conversation-1',
        );
        expect(chat!.showPromptLog, expected, reason: mode);
        await t.pumpWidget(const SizedBox());
      }
    });

    testWidgets('should render chatflow status cells and feedback counters for advanced chat logs', (t) async {
      Json row(
        String id,
        String name,
        Json status, {
        Json user = const {'like': 0, 'dislike': 0},
        Json admin = const {'like': 0, 'dislike': 0},
      }) => {
        'id': id,
        'name': name,
        'from_account_name': 'user',
        'read_at': 1710000001,
        'message_count': 3,
        'status_count': status,
        'user_feedback_stats': user,
        'admin_feedback_stats': admin,
        'updated_at': 1710000000,
        'created_at': 1710000000,
      };
      await renderList(
        t,
        app: mockApp(id: 'app-1', mode: 'advanced-chat'),
        logs: {
          'data': [
            row(
              'conversation-pending',
              'Pending row',
              {'paused': 1, 'success': 0, 'failed': 0, 'partial_success': 0},
              user: {'like': 2, 'dislike': 0},
              admin: {'like': 0, 'dislike': 1},
            ),
            row('conversation-success', 'Success row', {'paused': 0, 'success': 4, 'failed': 0, 'partial_success': 0}),
            row('conversation-partial', 'Partial row', {'paused': 0, 'success': 3, 'failed': 0, 'partial_success': 1}),
            row('conversation-failure', 'Failure row', {'paused': 0, 'success': 0, 'failed': 2, 'partial_success': 0}),
          ],
        },
      );
      expect(find.text('PENDING'), findsOneWidget);
      expect(find.text('SUCCESS'), findsOneWidget);
      expect(find.text('PARTIAL SUCCESS'), findsOneWidget);
      expect(find.text('2 FAILURES'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('1'), findsWidgets);
    });

    testWidgets('should support annotation changes, modal closing, and paginated scroll loading in the detail drawer', (
      t,
    ) async {
      source.conversation = detail(
        form: [
          {
            'query': {'variable': 'query'},
          },
        ],
      );
      source.messagePages
        ..add({
          'data': [
            createChatMessage('message-1', {
              'annotation': {
                'id': 'annotation-1',
                'content': 'Annotated answer',
                'account': {'name': 'Admin'},
              },
            }),
            createChatMessage('message-2', {'parent_message_id': 'message-1'}),
            createChatMessage('message-3', {'parent_message_id': 'message-2'}),
            createChatMessage('message-4', {'parent_message_id': 'message-3'}),
          ],
          'has_more': true,
        })
        ..add({
          'data': [createChatMessage('message-5')],
          'has_more': false,
        });
      await renderList(t, conversationId: 'conversation-1');
      expect(t.widget<Text>(find.byKey(const ValueKey('chat-panel-count'))).data, '8');
      expect(find.text('app-log.detail.loading...'), findsOneWidget);
      chat!.onAnnotationAdded('annotation-2', 'Admin', 'Edited question', 'Edited answer', 1);
      await t.pump();
      chat!.onAnnotationEdited('Updated question', 'Updated answer', 1);
      await t.pump();
      await chat!.onAnnotationRemoved(1);
      await settle(t);
      expect(source.deletedAnnotations.single, (appId: 'app-1', id: 'annotation-2'));
      final scrollable = t.state<ScrollableState>(
        find.descendant(of: find.byKey(const ValueKey('conversation-scroll')), matching: find.byType(Scrollable)),
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await settle(t);
      expect(source.chatMessagesCalls, hasLength(2));
      expect(source.chatMessagesCalls[1]['first_id'], 'message-1');
    });
  });
}
