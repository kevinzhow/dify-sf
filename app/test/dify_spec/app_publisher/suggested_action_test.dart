// dify-spec: web/app/components/app/app-publisher/__tests__/suggested-action.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/header/publisher/suggested_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Widget _box(Widget child) => SizedBox(width: 320, child: child);

void main() {
  group('SuggestedAction', () {
    testWidgets('should render an enabled external link with supporting copy', (t) async {
      final semantics = t.ensureSemantics();
      final opened = <(String, bool)>[];
      await render(
        t,
        _box(
          SuggestedAction(
            label: 'Open docs',
            link: 'https://example.com/docs',
            external: true,
            description: 'Read the documentation',
            onOpenLink: (link, {required external}) => opened.add((link, external)),
          ),
        ),
      );
      final link = named('Open docs');
      expect(isLink(link), isTrue);
      expect(data(link).linkUrl, Uri.parse('https://example.com/docs'));
      expect(data(link).hint, 'Read the documentation');
      expect(find.text('Read the documentation'), findsOneWidget);
      await t.tap(find.text('Open docs'));
      expect(opened, [('https://example.com/docs', true)], reason: 'target="_blank"');
      semantics.dispose();
    });

    testWidgets('should render internal destinations without opening a new tab', (t) async {
      final semantics = t.ensureSemantics();
      final opened = <(String, bool)>[];
      await render(
        t,
        _box(
          SuggestedAction(
            label: 'Deploy',
            link: '/app/app-1/deploy',
            description: 'Push versions to environments',
            onOpenLink: (link, {required external}) => opened.add((link, external)),
          ),
        ),
      );
      final link = named('Deploy');
      expect(isLink(link), isTrue);
      expect(data(link).linkUrl, Uri.parse('/app/app-1/deploy'));
      expect(data(link).hint, 'Push versions to environments');
      await t.tap(find.text('Deploy'));
      expect(opened, [('/app/app-1/deploy', false)]);
      semantics.dispose();
    });

    testWidgets('should use native disabled button semantics for unavailable links', (t) async {
      final semantics = t.ensureSemantics();
      var clicks = 0;
      await render(
        t,
        _box(
          SuggestedAction(
            label: 'Disabled action',
            link: 'https://example.com/docs',
            disabled: true,
            description: 'Unavailable until published',
            onPressed: () => clicks++,
          ),
        ),
      );
      final action = named('Disabled action');
      await t.tap(find.text('Disabled action'));
      expect(isButton(action), isTrue);
      expect(isLink(action), isFalse);
      expect(isDisabled(action), isTrue);
      expect(isFocusable(action), isFalse);
      expect(clicks, 0);
      semantics.dispose();
    });

    testWidgets('should keep an explained disabled action in the keyboard tab order', (t) async {
      final semantics = t.ensureSemantics();
      var clicks = 0;
      await render(
        t,
        _box(
          SuggestedAction(
            label: 'Disabled action with explanation',
            disabled: true,
            focusableWhenDisabled: true,
            onPressed: () => clicks++,
          ),
        ),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      final action = named('Disabled action with explanation');
      expect(isFocused(action), isTrue);
      expect(isDisabled(action), isTrue, reason: 'aria-disabled');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(clicks, 0);
      semantics.dispose();
    });

    testWidgets('should render and trigger an enabled button action', (t) async {
      final semantics = t.ensureSemantics();
      var clicks = 0;
      await render(
        t,
        _box(
          SuggestedAction(
            label: 'Workflow as Tool',
            description: 'Use as a tool in other apps',
            onPressed: () => clicks++,
          ),
        ),
      );
      expect(isButton(named('Workflow as Tool')), isTrue);
      await t.tap(find.text('Workflow as Tool'));
      expect(clicks, 1);
      semantics.dispose();
    });

    testWidgets('should keep the main link separate from a trailing action button', (t) async {
      final semantics = t.ensureSemantics();
      var clicks = 0;
      await render(
        t,
        _box(
          SuggestedAction(
            label: 'Open web app',
            link: 'https://example.com/app',
            external: true,
            actionButton: SuggestedActionButton(
              label: 'Configure action',
              icon: const Text('config'),
              onPressed: () => clicks++,
            ),
          ),
        ),
      );
      expect(data(named('Open web app')).linkUrl, Uri.parse('https://example.com/app'));
      await t.tap(find.text('config'));
      expect(clicks, 1);
      semantics.dispose();
    });

    testWidgets('should disable both controls when an action with a trailing button is unavailable', (t) async {
      final semantics = t.ensureSemantics();
      var clicks = 0;
      await render(
        t,
        _box(
          SuggestedAction(
            label: 'Open web app',
            link: 'https://example.com/app',
            external: true,
            disabled: true,
            actionButton: SuggestedActionButton(
              label: 'Configure action',
              icon: const Text('config'),
              onPressed: () => clicks++,
            ),
          ),
        ),
      );
      final main = named('Open web app');
      expect(isButton(main) && isDisabled(main), isTrue);
      final button = named('Configure action');
      await t.tap(find.text('config'));
      expect(isDisabled(button), isTrue);
      expect(clicks, 0);
      semantics.dispose();
    });
  });
}
