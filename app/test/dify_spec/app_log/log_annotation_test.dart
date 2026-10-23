// dify-spec: web/app/components/app/log-annotation/__tests__/index.spec.tsx
import 'package:collab_client/collab_client.dart' show AppInfo;
import 'package:dify_sf_app/src/app_detail/logs/logs_data.dart';
import 'package:dify_sf_app/src/app_detail/logs/logs_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  Widget region(String label, AppInfo app) => Text(app.id, key: ValueKey(label));

  Future<void> renderPage(WidgetTester t, {AppInfo? app, LogPageType pageType = LogPageType.log}) => renderLog(
    t,
    LogAnnotation(
      app: app,
      pageType: pageType,
      source: const EmptyAppLogsSource(),
      annotationBuilder: (context, app) => region('Annotation log', app),
      logBuilder: (context, app) => region('App log', app),
      workflowLogBuilder: (context, app) => region('Workflow log', app),
    ),
  );

  group('LogAnnotation', () {
    group('Rendering', () {
      testWidgets('should render loading state when app detail is missing', (t) async {
        await renderPage(t);
        expect(find.bySemanticsLabel('status'), findsOneWidget);
        expect(find.byKey(const ValueKey('logs-loading')), findsOneWidget);
      });

      testWidgets('should render log content without the old page tabs', (t) async {
        await renderPage(
          t,
          app: mockApp(id: 'app-123', mode: 'chat'),
        );
        expect(find.byKey(const ValueKey('App log')), findsOneWidget);
        expect(find.text('app-log.title'), findsNothing);
        expect(find.text('app-annotation.title'), findsNothing);
      });

      testWidgets('should render completion logs without the old page tabs', (t) async {
        await renderPage(
          t,
          app: mockApp(id: 'app-123', mode: 'completion'),
        );
        expect(find.byKey(const ValueKey('App log')), findsOneWidget);
        expect(find.text('app-log.title'), findsNothing);
        expect(find.text('app-annotation.title'), findsNothing);
      });

      testWidgets('should hide tabs and render workflow log in workflow mode', (t) async {
        await renderPage(
          t,
          app: mockApp(id: 'app-123', mode: 'workflow'),
        );
        expect(find.text('app-log.title'), findsNothing);
        expect(find.byKey(const ValueKey('Workflow log')), findsOneWidget);
      });
    });

    group('Props', () {
      testWidgets('should render log content when page type is log', (t) async {
        await renderPage(
          t,
          app: mockApp(id: 'app-123', mode: 'chat'),
        );
        expect(find.byKey(const ValueKey('App log')), findsOneWidget);
        expect(find.byKey(const ValueKey('Annotation log')), findsNothing);
      });

      testWidgets('should render annotation content when page type is annotation', (t) async {
        await renderPage(
          t,
          app: mockApp(id: 'app-123', mode: 'chat'),
          pageType: LogPageType.annotation,
        );
        expect(find.byKey(const ValueKey('Annotation log')), findsOneWidget);
        expect(find.byKey(const ValueKey('App log')), findsNothing);
      });
    });
  });
}
