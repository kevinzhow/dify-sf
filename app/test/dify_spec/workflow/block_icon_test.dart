// dify-spec: web/app/components/workflow/__tests__/block-icon.spec.tsx
import 'package:dify_sf_app/src/cards/card_chrome.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester t, Widget w) => t.pumpWidget(
  MaterialApp(
    home: Align(alignment: Alignment.topLeft, child: w),
  ),
);

void main() {
  group('BlockIcon', () {
    testWidgets('renders the default workflow icon container for regular nodes', (t) async {
      await _pump(t, const BlockIcon(type: 'start', size: BlockIconSize.xs));
      final box = t.widget<Container>(find.byType(Container).first);
      expect(t.getSize(find.byType(BlockIcon)), const Size(16, 16));
      expect((box.decoration! as BoxDecoration).color, DifyColors.utilColorsBlueBrandBlueBrand500);
      expect(t.widget<DifyIcon>(find.byType(DifyIcon)).name, 'vender/workflow/user-input');
    });
  });

  group('VarBlockIcon', () {
    testWidgets('renders the compact icon variant without the default container wrapper', (t) async {
      await _pump(t, const VarBlockIcon(type: 'answer'));
      expect(find.byType(DifyIcon), findsOneWidget);
      expect(t.widget<DifyIcon>(find.byType(DifyIcon)).name, 'vender/workflow/answer');
      // No coloured tile around the glyph.
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).color != null,
        ),
        findsNothing,
      );
    });
  });
}
