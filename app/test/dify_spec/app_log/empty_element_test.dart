// dify-spec: web/app/components/app/log/__tests__/empty-element.spec.tsx
import 'package:dify_sf_app/src/app_detail/logs/log_widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dify_sf_app/src/i18n/dify_i18n.dart';

import '../dify_test_i18n.dart';
import 'harness.dart';

/// Dify's mocked `Trans`, which renders both link components: the content key with Dify's English tags.
class _Trans implements Translator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) => key == 'table.empty.element.content'
      ? '$ns.$key <shareLink>sharing</shareLink> <testLink>testing</testLink>'
      : DifyTestTranslator().t(ns, key, params);
}

const site = {'access_token': 'test-token', 'app_base_url': 'https://app.example.com/base'};

void main() {
  late List<String> tapped;
  setUp(() => tapped = []);

  Future<void> renderEmpty(WidgetTester t, String mode) => renderLog(
    t,
    LogEmptyElement(
      shareUrl: LogEmptyElement.shareUrlOf(site, mode),
      testPath: '/test-path',
      onShare: () => tapped.add('share'),
      onTest: () => tapped.add('test'),
    ),
  );

  /// The links in reading order, as `(text, url)`.
  List<(String, String?)> links(WidgetTester t) => [
    for (final n in find.semantics.byPredicate((n) => n.getSemanticsData().flagsCollection.isLink).evaluate())
      (n.getSemanticsData().label, n.getSemanticsData().linkUrl?.toString()),
  ];

  group('EmptyElement', () {
    group('Rendering', () {
      testWidgets('should render empty element with title', (t) async {
        await renderEmpty(t, 'chat');
        expect(find.text('app-log.table.empty.element.title'), findsOneWidget);
      });

      testWidgets('should render Trans component with i18n key', (t) async {
        await renderEmpty(t, 'chat');
        expect(find.textContaining('app-log.table.empty.element.content', findRichText: true), findsOneWidget);
      });
    });

    group('App Mode Handling', () {
      void expectType(String mode, String type) {
        expect(LogEmptyElement.shareUrlOf(site, mode), 'https://app.example.com/base/$type/test-token');
        expect(webAppTypeOf(mode), type);
      }

      test('should use CHAT mode for chat apps', () => expectType('chat', 'chat'));
      test('should use COMPLETION mode for completion apps', () => expectType('completion', 'completion'));
      test('should use WORKFLOW mode for workflow apps', () => expectType('workflow', 'workflow'));
      test('should use CHAT mode for advanced-chat apps', () => expectType('advanced-chat', 'chat'));
      test('should use CHAT mode for agent-chat apps', () => expectType('agent-chat', 'chat'));
    });

    group('Links', () {
      testWidgets('should render share link with correct attributes', (t) async {
        final handle = t.ensureSemantics();
        await renderLog(
          t,
          LogEmptyElement(
            shareUrl: LogEmptyElement.shareUrlOf(site, 'chat'),
            testPath: '/test-path',
            onShare: () => tapped.add('share'),
            onTest: () => tapped.add('test'),
          ),
          translator: _Trans(),
        );
        expect(links(t), isNotEmpty);
        expect(links(t).first.$2, 'https://app.example.com/base/chat/test-token');
        await t.tap(find.byKey(const ValueKey('log-empty-share-link')));
        expect(tapped, ['share']);
        handle.dispose();
      });

      testWidgets('should render test link with redirection path', (t) async {
        final handle = t.ensureSemantics();
        await renderLog(
          t,
          LogEmptyElement(
            shareUrl: LogEmptyElement.shareUrlOf(site, 'chat'),
            testPath: '/test-path',
            onTest: () => tapped.add('test'),
          ),
          translator: _Trans(),
        );
        expect(links(t)[1].$2, '/test-path');
        await t.tap(find.byKey(const ValueKey('log-empty-test-link')));
        expect(tapped, ['test']);
        handle.dispose();
      });
    });
  });
}
