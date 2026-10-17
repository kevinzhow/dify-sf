// dify-spec: packages/dify-ui/src/button/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('Button', () {
    group('rendering', () {
      testWidgets('defaults to type="button"', (t) async {
        final semantics = t.ensureSemantics();
        await render(t, DifyButton(onPressed: () {}, child: const Text('Click me')));
        expect(t.getSemantics(find.byType(DifyButton)), isSemantics(label: 'Click me', isButton: true));
        semantics.dispose();
      });
    });

    group('disabled states', () {
      testWidgets('uses native disabled semantics for regular disabled buttons', (t) async {
        final semantics = t.ensureSemantics();
        await render(t, DifyButton(disabled: true, onPressed: () {}, child: const Text('Click me')));
        expect(
          t.getSemantics(find.byType(DifyButton)),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: false, isFocusable: false),
        );
        semantics.dispose();
      });

      testWidgets('allows loading focusability to be opted out', (t) async {
        final semantics = t.ensureSemantics();
        await render(t, DifyButton(loading: true, onPressed: () {}, child: const Text('Loading')));
        expect(
          t.getSemantics(find.byType(DifyButton)),
          isSemantics(isEnabled: false, isFocusable: true),
          reason: 'loading stays focusable by default',
        );
        await render(
          t,
          DifyButton(loading: true, focusableWhenDisabled: false, onPressed: () {}, child: const Text('Loading')),
        );
        expect(t.getSemantics(find.byType(DifyButton)), isSemantics(isEnabled: false, isFocusable: false));
        semantics.dispose();
      });
    });

    group('events', () {
      testWidgets('does not implicitly submit a form through a loading submit button', (t) async {
        // No forms in Flutter: a focused loading button ignores Enter.
        final node = FocusNode();
        addTearDown(node.dispose);
        var submits = 0;
        await render(
          t,
          DifyButton(loading: true, focusNode: node, onPressed: () => submits++, child: const Text('Submit')),
        );
        node.requestFocus();
        await t.pump();
        expect(node.hasFocus, isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(submits, 0);
      });
    });

    group('ref forwarding', () {
      testWidgets('forwards ref to the button element', (t) async {
        // The ref's Flutter counterpart: the focus node attaches to the button itself.
        final node = FocusNode();
        addTearDown(node.dispose);
        var presses = 0;
        await render(t, DifyButton(focusNode: node, onPressed: () => presses++, child: const Text('Click me')));
        expect(find.ancestor(of: find.text('Click me'), matching: find.byType(Focus)), findsWidgets);
        node.requestFocus();
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.space);
        expect(presses, 1);
      });
    });
  });
}
