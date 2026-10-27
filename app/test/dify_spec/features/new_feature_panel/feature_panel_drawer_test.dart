// dify-spec: web/app/components/base/features/new-feature-panel/__tests__/feature-panel-drawer.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> renderDrawer(WidgetTester t, {required bool show, VoidCallback? onClose}) async {
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: FeaturePanelDrawer(
          show: show,
          onClose: onClose,
          child: const Text('Content', key: ValueKey('content')),
        ),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 250));
}

void main() {
  testWidgets('portal uses the full viewport and leaves a dismissible gutter beside a phone sidebar', (t) async {
    t.view.physicalSize = const Size(390, 760);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var closed = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Material(
          child: Row(
            children: [
              const SizedBox(width: 64),
              Expanded(
                child: FeaturePanelDrawer(
                  show: true,
                  onClose: () => closed++,
                  child: const Text('Viewport drawer'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(t.getRect(find.byType(DifyDrawerPopup)), const Rect.fromLTWH(32, 112, 358, 640));
    await t.tapAt(const Offset(16, 400));
    await t.pump();
    expect(closed, 1);
    expect(t.takeException(), isNull);
  });

  group('FeaturePanelDrawer', () {
    group('Rendering', () {
      testWidgets('should render children when show is true', (t) async {
        await renderDrawer(t, show: true);
        expect(find.byKey(const ValueKey('content')), findsOneWidget);
      });

      testWidgets('should not render children when show is false', (t) async {
        await renderDrawer(t, show: false);
        expect(find.byKey(const ValueKey('content')), findsNothing);
      });
    });

    group('Close behavior', () {
      testWidgets('should call onClose when escape is pressed', (t) async {
        var closed = 0;
        await renderDrawer(t, show: true, onClose: () => closed++);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        expect(closed, 1);
      });

      testWidgets('should not throw when escape is pressed without onClose', (t) async {
        await renderDrawer(t, show: true);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        expect(t.takeException(), isNull);
      });
    });
  });
}
