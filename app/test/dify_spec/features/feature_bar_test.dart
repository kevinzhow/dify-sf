// dify-spec: web/app/components/base/features/new-feature-panel/__tests__/feature-bar.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/run/ui/chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workflow/run/run_harness.dart';

void main() {
  Future<void> render(
    WidgetTester t, {
    String? enabled,
    bool isChatMode = true,
    bool showFileUpload = true,
    bool hideEditEntrance = false,
    VoidCallback? onClick,
  }) async {
    await renderRun(
      t,
      FeatureBar(
        features: {
          if (enabled != null) enabled: {'enabled': true},
        },
        isChatMode: isChatMode,
        showFileUpload: showFileUpload,
        hideEditEntrance: hideEditEntrance,
        onFeatureBarClick: onClick,
      ),
      size: const Size(800, 120),
    );
  }

  group('FeatureBar', () {
    group('Empty State', () {
      testWidgets('should render empty state when no features are enabled', (t) async {
        await render(
          t,
        );
        expect(find.text('app-debug.feature.bar.empty'), findsOneWidget);
        expect(find.text('app-debug.feature.bar.enableText'), findsNothing);
      });
      testWidgets('should call onFeatureBarClick when empty state is clicked', (t) async {
        var clicks = 0;
        await render(t, enabled: null, onClick: () => clicks++);
        await t.tap(find.text('app-debug.feature.bar.empty'));
        expect(clicks, 1);
      });
    });
    group('Enabled Features', () {
      testWidgets('should show enabled text when moreLikeThis is enabled', (t) async {
        await render(
          t,
          enabled: 'moreLikeThis',
        );
        expect(find.text('app-debug.feature.bar.enableText'), findsOneWidget);
        expect(find.text('app-debug.feature.bar.empty'), findsNothing);
      });
      testWidgets('should show manage button when features are enabled', (t) async {
        await render(
          t,
          enabled: 'moreLikeThis',
        );
        expect(find.text('app-debug.feature.bar.manage'), findsOneWidget);
      });
      testWidgets('should hide manage button when hideEditEntrance is true', (t) async {
        await render(
          t,
          enabled: 'moreLikeThis',
          hideEditEntrance: true,
        );
        expect(find.text('app-debug.feature.bar.manage'), findsNothing);
      });
      testWidgets('should call onFeatureBarClick when manage button is clicked', (t) async {
        var clicks = 0;
        await render(t, enabled: 'moreLikeThis', onClick: () => clicks++);
        await t.tap(find.text('app-debug.feature.bar.manage'));
        expect(clicks, 1);
      });
    });
    group('Chat Mode Features', () {
      testWidgets('should show enabled text when citation is enabled in chat mode', (t) async {
        await render(
          t,
          enabled: 'citation',
        );
        expect(find.text('app-debug.feature.bar.enableText'), findsOneWidget);
        expect(find.text('app-debug.feature.bar.empty'), findsNothing);
      });
      testWidgets('should show empty state when citation is enabled but not in chat mode', (t) async {
        await render(
          t,
          enabled: 'citation',
          isChatMode: false,
        );
        expect(find.text('app-debug.feature.bar.empty'), findsOneWidget);
        expect(find.text('app-debug.feature.bar.enableText'), findsNothing);
      });
      testWidgets('should show enabled text when opening is enabled in chat mode', (t) async {
        await render(
          t,
          enabled: 'opening',
        );
        expect(find.text('app-debug.feature.bar.enableText'), findsOneWidget);
        expect(find.text('app-debug.feature.bar.empty'), findsNothing);
      });
      testWidgets('should show enabled text when file is enabled with showFileUpload', (t) async {
        await render(
          t,
          enabled: 'file',
        );
        expect(find.text('app-debug.feature.bar.enableText'), findsOneWidget);
        expect(find.text('app-debug.feature.bar.empty'), findsNothing);
      });
      testWidgets('should show empty state when file is enabled but showFileUpload is false', (t) async {
        await render(
          t,
          enabled: 'file',
          showFileUpload: false,
        );
        expect(find.text('app-debug.feature.bar.empty'), findsOneWidget);
        expect(find.text('app-debug.feature.bar.enableText'), findsNothing);
      });
      testWidgets('should show enabled text when speech2text is enabled in chat mode', (t) async {
        await render(
          t,
          enabled: 'speech2text',
        );
        expect(find.text('app-debug.feature.bar.enableText'), findsOneWidget);
        expect(find.text('app-debug.feature.bar.empty'), findsNothing);
      });
      testWidgets('should show enabled text when text2speech is enabled', (t) async {
        await render(
          t,
          enabled: 'text2speech',
        );
        expect(find.text('app-debug.feature.bar.enableText'), findsOneWidget);
        expect(find.text('app-debug.feature.bar.empty'), findsNothing);
      });
      testWidgets('should show enabled text when moderation is enabled', (t) async {
        await render(
          t,
          enabled: 'moderation',
        );
        expect(find.text('app-debug.feature.bar.enableText'), findsOneWidget);
        expect(find.text('app-debug.feature.bar.empty'), findsNothing);
      });
      testWidgets('should show enabled text when suggested is enabled', (t) async {
        await render(
          t,
          enabled: 'suggested',
        );
        expect(find.text('app-debug.feature.bar.enableText'), findsOneWidget);
        expect(find.text('app-debug.feature.bar.empty'), findsNothing);
      });
      testWidgets('should show enabled text when annotationReply is enabled in chat mode', (t) async {
        await render(
          t,
          enabled: 'annotationReply',
        );
        expect(find.text('app-debug.feature.bar.enableText'), findsOneWidget);
        expect(find.text('app-debug.feature.bar.empty'), findsNothing);
      });
    });
  });
}
