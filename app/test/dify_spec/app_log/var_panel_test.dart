// dify-spec: web/app/components/app/log/__tests__/var-panel.spec.tsx
import 'package:dify_sf_app/src/app_detail/logs/log_widgets.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const defaultVars = [(label: 'name', value: 'John Doe'), (label: 'age', value: '25')];

void main() {
  Future<void> renderPanel(
    WidgetTester t, {
    List<({String label, String value})> vars = defaultVars,
    List<String> files = const [],
  }) => renderLog(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 560,
        child: LogVarPanel(varList: vars, messageFiles: files),
      ),
    ),
  );

  Future<void> toggle(WidgetTester t) async {
    await t.tap(find.text('app-log.detail.variables'));
    await settle(t);
  }

  Finder thumbs() => find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('var-panel-image-') &&
        w is GestureDetector,
  );

  group('VarPanel', () {
    group('Rendering', () {
      testWidgets('should render variables section header', (t) async {
        await renderPanel(t);
        expect(find.text('app-log.detail.variables'), findsOneWidget);
      });

      testWidgets('should render variable labels with braces', (t) async {
        await renderPanel(t);
        expect(find.text('name'), findsOneWidget);
        expect(find.text('age'), findsOneWidget);
      });

      testWidgets('should render variable values', (t) async {
        await renderPanel(t);
        expect(find.text('John Doe'), findsOneWidget);
        expect(find.text('25'), findsOneWidget);
      });

      testWidgets('should render opening and closing braces', (t) async {
        await renderPanel(t);
        expect(find.text('{{'), findsNWidgets(2));
        expect(find.text('}}'), findsNWidgets(2));
      });

      testWidgets('should render Variable02 icon', (t) async {
        await renderPanel(t);
        expect(
          find.byWidgetPredicate((w) => w is DifyIcon && w.name == 'vender/solid/development/variable-02'),
          findsOneWidget,
        );
      });
    });

    group('Collapse/Expand', () {
      testWidgets('should show expanded state by default', (t) async {
        await renderPanel(t);
        expect(find.text('John Doe'), findsOneWidget);
        expect(find.text('25'), findsOneWidget);
      });

      testWidgets('should collapse when header is clicked', (t) async {
        await renderPanel(t);
        await toggle(t);
        expect(find.text('John Doe'), findsNothing);
        expect(find.text('25'), findsNothing);
      });

      testWidgets('should expand when clicked again', (t) async {
        await renderPanel(t);
        await toggle(t);
        expect(find.text('John Doe'), findsNothing);
        await toggle(t);
        expect(find.text('John Doe'), findsOneWidget);
      });

      testWidgets('should show arrow icon when collapsed', (t) async {
        await renderPanel(t);
        await toggle(t);
        expect(find.byKey(const ValueKey('var-panel-collapsed')), findsOneWidget);
      });

      testWidgets('should show arrow icon when expanded', (t) async {
        await renderPanel(t);
        expect(find.byKey(const ValueKey('var-panel-expanded')), findsOneWidget);
      });
    });

    group('Message Files', () {
      testWidgets('should not render images section when message_files is empty', (t) async {
        await renderPanel(t);
        expect(find.text('app-log.detail.uploadImages'), findsNothing);
      });

      testWidgets('should render images section when message_files has items', (t) async {
        await renderPanel(t, files: ['https://example.com/image1.jpg', 'https://example.com/image2.jpg']);
        expect(find.text('app-log.detail.uploadImages'), findsOneWidget);
      });

      testWidgets('should render image thumbnails with correct background', (t) async {
        await renderPanel(t, files: ['https://example.com/image1.jpg']);
        final image = t.widget<Image>(find.descendant(of: thumbs(), matching: find.byType(Image)));
        expect((image.image as NetworkImage).url, 'https://example.com/image1.jpg');
      });

      testWidgets('should open image preview when thumbnail is clicked', (t) async {
        await renderPanel(t, files: ['https://example.com/image1.jpg']);
        await t.tap(thumbs());
        await settle(t);
        final preview = find.byKey(const ValueKey('var-panel-image-preview'));
        expect(preview, findsOneWidget);
        final image = t.widget<Image>(find.descendant(of: preview, matching: find.byType(Image)));
        expect((image.image as NetworkImage).url, 'https://example.com/image1.jpg');
      });

      testWidgets('should close image preview when close button is clicked', (t) async {
        await renderPanel(t, files: ['https://example.com/image1.jpg']);
        await t.tap(thumbs());
        await settle(t);
        expect(find.byKey(const ValueKey('var-panel-image-preview')), findsOneWidget);
        await tapButton(t, 'common.operation.close');
        expect(find.byKey(const ValueKey('var-panel-image-preview')), findsNothing);
      });
    });

    group('Empty State', () {
      testWidgets('should render with empty varList', (t) async {
        await renderPanel(t, vars: const []);
        expect(find.text('app-log.detail.variables'), findsOneWidget);
      });
    });

    group('Multiple Images', () {
      testWidgets('should render multiple image thumbnails', (t) async {
        await renderPanel(
          t,
          files: ['https://example.com/image1.jpg', 'https://example.com/image2.jpg', 'https://example.com/image3.jpg'],
        );
        expect(thumbs(), findsNWidgets(3));
      });
    });
  });
}
