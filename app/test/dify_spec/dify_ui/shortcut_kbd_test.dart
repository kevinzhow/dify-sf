// dify-spec: web/app/components/workflow/shortcuts/__tests__/shortcut-kbd.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('ShortcutKbd', () {
    testWidgets('renders shortcut chords as separate design-system keycaps', (t) async {
      await render(
        t,
        const DifyShortcutKbd(
          shortcut: 'workflow.copy',
          platform: DifyPlatform.mac,
          color: DifyKbdColor.white,
          secondaryText: true,
        ),
      );
      final row = t.widget<Row>(find.descendant(of: find.byType(DifyKbdGroup), matching: find.byType(Row)));
      expect(row.spacing, 2);
      expect(row.crossAxisAlignment, CrossAxisAlignment.center);
      expect(find.byType(DifyKbd), findsNWidgets(2));
      expect(find.text('⌘'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      final first = find.byType(DifyKbd).first;
      expect(t.getSize(first), const Size(16, 16)); // h-4 min-w-4
      final box = t.widget<Container>(find.descendant(of: first, matching: find.byType(Container)));
      final deco = box.decoration! as BoxDecoration;
      expect(deco.borderRadius, BorderRadius.circular(4)); // rounded-sm
      expect(deco.color, DifyColors.componentsKbdBgWhite);
      final text = t.widget<Text>(find.text('⌘'));
      expect(text.style!.fontSize, 12); // system-kbd
      expect(text.style!.fontWeight, FontWeight.w500);
      expect(text.style!.fontStyle, FontStyle.normal); // not-italic
      expect(text.style!.color, DifyColors.textTertiary);
    });

    testWidgets('keeps single-key shortcuts in one keycap', (t) async {
      await render(t, const DifyShortcutKbd(shortcut: 'workflow.delete', platform: DifyPlatform.windows));
      expect(find.byType(DifyKbd), findsOneWidget);
      expect(find.text('⌦'), findsOneWidget);
    });

    testWidgets('uses TanStack non-mac modifier labels', (t) async {
      await render(t, const DifyShortcutKbd(shortcut: 'workflow.copy', platform: DifyPlatform.windows));
      expect(find.text('Ctrl'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
    });
  });
}
