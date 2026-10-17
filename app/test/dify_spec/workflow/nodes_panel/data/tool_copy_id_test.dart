// dify-spec: web/app/components/workflow/nodes/tool/components/__tests__/copy-id.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/copy_id.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Finder button(String label) =>
    find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == label, description: 'button "$label"');

void main() {
  late List<String?> copied;

  setUp(() {
    useDifyTestTranslator();
    copied = [];
  });

  Future<void> render(WidgetTester t, {VoidCallback? onParentTap}) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String?);
      return null;
    });
    await t.pumpWidget(
      MaterialApp(
        home: Material(
          child: GestureDetector(
            onTap: onParentTap,
            child: const Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 200, child: CopyId(content: 'tool-123')),
            ),
          ),
        ),
      ),
    );
  }

  group('tool/copy-id', () {
    testWidgets('should copy content and reset copied state when mouse leaves', (t) async {
      await render(t);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(button('appOverview.overview.appInfo.embedded.copy')));
      await t.tap(button('appOverview.overview.appInfo.embedded.copy'));
      await t.pump(const Duration(milliseconds: 100));
      expect(copied, ['tool-123']);
      expect(button('appOverview.overview.appInfo.embedded.copied'), findsOneWidget);

      await mouse.moveTo(const Offset(700, 500));
      await t.pump(const Duration(milliseconds: 100));
      expect(button('appOverview.overview.appInfo.embedded.copy'), findsOneWidget);
      await mouse.removePointer();
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('should stop click propagation from the copy button', (t) async {
      var parentTaps = 0;
      await render(t, onParentTap: () => parentTaps++);
      await t.tap(button('appOverview.overview.appInfo.embedded.copy'));
      await t.pump(const Duration(milliseconds: 100));
      expect(parentTaps, 0);
      await t.pump(const Duration(seconds: 1));
    });
  });
}
