// dify-spec: packages/dify-ui/src/kbd/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('Kbd', () {
    testWidgets('renders a native kbd element with the default gray variant', (t) async {
      await render(t, const DifyKbd('⌘'));
      expect(find.text('⌘'), findsOneWidget);
      final kbd = t.widget<DifyKbd>(find.byType(DifyKbd));
      expect(kbd.color, DifyKbdColor.gray);
      final box = t.widget<Container>(find.ancestor(of: find.text('⌘'), matching: find.byType(Container)));
      expect((box.decoration! as BoxDecoration).color, DifyColors.componentsKbdBgGray);
      expect(t.widget<Text>(find.text('⌘')).style!.color, DifyColors.textTertiary);
    });

    testWidgets('marks disabled keycaps visually without adding widget semantics', (t) async {
      final semantics = t.ensureSemantics();
      await render(t, const DifyKbd('⌘', disabled: true));
      expect(t.widget<Opacity>(find.byType(Opacity)).opacity, 0.3);
      expect(t.getSemantics(find.text('⌘')), isSemantics(label: '⌘', hasEnabledState: false));
      semantics.dispose();
    });
  });

  group('KbdGroup', () {
    testWidgets('groups keycaps without replacing individual kbd semantics', (t) async {
      final semantics = t.ensureSemantics();
      await render(
        t,
        const DifyKbdGroup(semanticLabel: 'Command Shift K', children: [DifyKbd('⌘'), DifyKbd('⇧'), DifyKbd('K')]),
      );
      expect(find.bySemanticsLabel('Command Shift K'), findsOneWidget);
      expect(find.descendant(of: find.byType(DifyKbdGroup), matching: find.byType(DifyKbd)), findsNWidgets(3));
      final keys = [for (final e in find.byType(DifyKbd).evaluate()) t.getRect(find.byWidget(e.widget))];
      expect(keys[1].left - keys[0].right, 2, reason: 'gap-0.5');
      semantics.dispose();
    });
  });
}
