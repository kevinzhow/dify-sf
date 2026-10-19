// dify-spec: web/app/components/app/log/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/app_detail/logs/chat_log.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late RecordingLogsSource source;
  setUp(() {
    source = RecordingLogsSource();
    chatLogsStateCache.clear();
  });

  group('Logs', () {
    testWidgets('should request chat conversations and show a loading state before data arrives', (t) async {
      final handle = t.ensureSemantics();
      await renderLog(
        t,
        ChatLogs(
          app: mockApp(id: 'app-1', mode: 'advanced-chat'),
          source: source,
          debounce: Duration.zero,
        ),
      );
      expect(source.chatConversationsCalls.last.appId, 'app-1');
      expect(find.text('app-log.title'), findsOneWidget);
      expect(
        find.semantics.byPredicate((n) => n.getSemanticsData().flagsCollection.isHeader && n.label == 'app-log.title'),
        findsOneWidget,
      );
      expect(find.text('app-log.description'), findsOneWidget);
      final link = find.semantics
          .byPredicate((n) => n.getSemanticsData().flagsCollection.isLink && n.label.contains('operation.learnMore'))
          .evaluate()
          .single;
      expect(link.getSemanticsData().linkUrl.toString(), 'https://docs.dify.ai/en/use-dify/monitor/logs');
      expect(find.byKey(const ValueKey('logs-loading')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('should update the page query parameter when pagination changes', (t) async {
      final pages = <int>[];
      source.chatConversationsAnswer = mockLogsResponse([], 10 + 1);
      await renderLog(
        t,
        ChatLogs(
          app: mockApp(id: 'app-3', mode: 'advanced-chat'),
          source: source,
          debounce: Duration.zero,
          onPageChange: pages.add,
        ),
      );
      await tapButton(t, 'Go to page 2');
      // Dify's `router.replace('?page=2')`: the page shown is the second (zero-based 1), requested as page 2.
      expect(pages, [1]);
      expect(source.chatConversationsCalls.last.params['page'], 2);
    });
  });
}
