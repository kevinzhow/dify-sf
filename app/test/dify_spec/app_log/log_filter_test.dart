// dify-spec: web/app/components/app/log/__tests__/filter.spec.tsx
import 'package:dify_sf_app/src/app_detail/logs/chat_log.dart';
import 'package:dify_sf_app/src/app_detail/logs/log_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

const defaultQueryParams = ChatLogQuery(period: '9', annotationStatus: 'all', keyword: '');

void main() {
  late List<ChatLogQuery> calls;
  setUp(() => calls = []);

  Future<void> renderFilter(
    WidgetTester t, {
    ChatLogQuery query = defaultQueryParams,
    int? count = 10,
    bool isChatMode = false,
  }) => renderLog(
    t,
    ChatLogFilter(queryParams: query, setQueryParams: calls.add, annotationCount: count, isChatMode: isChatMode),
  );

  Finder searchField() =>
      find.descendant(of: find.byKey(const ValueKey('chat-log-keyword')), matching: find.byType(EditableText));

  Future<void> pick(WidgetTester t, String chipKey, String option) async {
    await t.tap(find.byKey(ValueKey(chipKey)));
    await settle(t);
    await t.tap(find.byKey(ValueKey('chip-option-$option')));
    await settle(t);
  }

  group('Filter', () {
    group('Rendering', () {
      testWidgets('should render filter components', (t) async {
        await renderFilter(t);
        expect(searchField(), findsOneWidget);
      });

      testWidgets('should return null when loading', (t) async {
        await renderFilter(t, count: null);
        expect(find.byType(LogChip), findsNothing);
        expect(searchField(), findsNothing);
      });

      testWidgets('should render sort component in chat mode', (t) async {
        await renderFilter(t, isChatMode: true);
        expect(searchField(), findsOneWidget);
        expect(find.byType(LogSort), findsOneWidget);
      });

      testWidgets('should not render sort component when not in chat mode', (t) async {
        await renderFilter(t);
        expect(searchField(), findsOneWidget);
        expect(find.byType(LogSort), findsNothing);
      });
    });

    group('TIME_PERIOD_MAPPING', () {
      test(
        'should have correct period keys',
        () => expect(timePeriodMapping().keys, ['1', '2', '3', '4', '5', '6', '7', '8', '9']),
      );
      test('should have today period with value 0', () => expect(timePeriodMapping()['1'], (value: 0, name: 'today')));
      test(
        'should have last7days period with value 7',
        () => expect(timePeriodMapping()['2'], (value: 7, name: 'last7days')),
      );
      test(
        'should have last4weeks period with value 28',
        () => expect(timePeriodMapping()['3'], (value: 28, name: 'last4weeks')),
      );
      test(
        'should have allTime period with value -1',
        () => expect(timePeriodMapping()['9'], (value: -1, name: 'allTime')),
      );
    });

    group('User Interactions', () {
      testWidgets('should keep all periods for sandbox workspaces in %s', (t) async {
        // The community edition has no plans: every period stays.
        await renderFilter(t, query: defaultQueryParams.copyWith(period: '2'));
        await t.tap(find.byKey(const ValueKey('chat-log-period')));
        await settle(t);
        for (var k = 1; k <= 9; k++) {
          expect(find.byKey(ValueKey('chip-option-$k')), findsOneWidget);
        }
      });

      testWidgets('should update keyword when typing in search input', (t) async {
        await renderFilter(t);
        await t.enterText(searchField(), 'test search');
        await settle(t);
        expect(calls.last, defaultQueryParams.copyWith(keyword: 'test search'));
      });

      testWidgets('should clear keyword when clear button is clicked', (t) async {
        await renderFilter(t, query: defaultQueryParams.copyWith(keyword: 'existing search'));
        await tapButton(t, 'common.operation.clear');
        expect(calls.last, defaultQueryParams.copyWith(keyword: ''));
      });

      testWidgets('should update and clear period, annotation, and sort filters', (t) async {
        await renderFilter(t, isChatMode: true);
        await pick(t, 'chat-log-period', '9');
        expect(calls.last, defaultQueryParams.copyWith(period: '9'));
        await tapButton(t, 'common.operation.clear app-log.filter.period.allTime');
        expect(calls.last, defaultQueryParams.copyWith(period: '9'));
        await pick(t, 'chat-log-annotation', 'not_annotated');
        expect(calls.last, defaultQueryParams.copyWith(annotationStatus: 'not_annotated'));
        await tapButton(t, 'common.operation.clear app-log.filter.annotation.all');
        expect(calls.last, defaultQueryParams.copyWith(annotationStatus: 'all'));
        await t.tap(find.byKey(const ValueKey('chat-log-sort')).first);
        await settle(t);
        await t.tap(find.byKey(const ValueKey('sort-option-updated_at')));
        await settle(t);
        expect(calls.last, defaultQueryParams.copyWith(sortBy: 'updated_at'));
        await tapButton(t, 'app-log.filter.descending');
        expect(calls.last, defaultQueryParams.copyWith(sortBy: '-created_at'));
      });
    });

    group('Query Params', () {
      testWidgets('should display "today" when period is set to 1', (t) async {
        await renderFilter(t, query: defaultQueryParams.copyWith(period: '1'));
        expect(find.text('app-log.filter.period.today'), findsOneWidget);
      });

      testWidgets('should display "last7days" when period is set to 2', (t) async {
        await renderFilter(t, query: defaultQueryParams.copyWith(period: '2'));
        expect(find.text('app-log.filter.period.last7days'), findsOneWidget);
      });

      testWidgets('should display "allTime" when period is set to 9', (t) async {
        await renderFilter(t);
        expect(find.text('app-log.filter.period.allTime'), findsOneWidget);
      });

      testWidgets('should display annotated status with count when annotation_status is annotated', (t) async {
        await renderFilter(t, query: defaultQueryParams.copyWith(annotationStatus: 'annotated'));
        expect(find.textContaining(RegExp(r'filter\.annotation\.annotated.*10')), findsOneWidget);
      });

      testWidgets('should display not_annotated status when annotation_status is not_annotated', (t) async {
        await renderFilter(t, query: defaultQueryParams.copyWith(annotationStatus: 'not_annotated'));
        expect(find.text('app-log.filter.annotation.not_annotated'), findsOneWidget);
      });

      testWidgets('should display all annotation status when annotation_status is all', (t) async {
        await renderFilter(t);
        expect(find.text('app-log.filter.annotation.all'), findsOneWidget);
      });

      testWidgets('should return null when annotation count data is unavailable', (t) async {
        await renderFilter(t, count: null);
        expect(find.byType(Wrap), findsNothing);
      });
    });

    group('Chat Mode', () {
      testWidgets('should display sort component with sort_by parameter', (t) async {
        await renderFilter(t, isChatMode: true, query: defaultQueryParams.copyWith(sortBy: 'created_at'));
        expect(searchField(), findsOneWidget);
        expect(t.widget<LogSort>(find.byType(LogSort)).order, '');
        expect(t.widget<LogSort>(find.byType(LogSort)).value, 'created_at');
        expect(button('app-log.filter.descending'), findsOneWidget);
      });

      testWidgets('should handle descending sort order', (t) async {
        await renderFilter(t, isChatMode: true, query: defaultQueryParams.copyWith(sortBy: '-created_at'));
        expect(searchField(), findsOneWidget);
        expect(t.widget<LogSort>(find.byType(LogSort)).order, '-');
        expect(button('app-log.filter.ascending'), findsOneWidget);
      });
    });
  });
}
