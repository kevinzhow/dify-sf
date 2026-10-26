import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/material.dart' show TextSelectionToolbar;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? copied;
  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        if (call.method == 'Clipboard.hasStrings') return {'value': true};
        return null;
      },
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  testWidgets('selection uses app locale, shared vertical rows and preserves editable focus for keyboard copying', (
    t,
  ) async {
    await t.runAsync(() => DifyI18n.load('zh-Hans'));
    final controller = TextEditingController(text: '中文🙂 editable'), focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: DifyPage(
          body: Column(
            children: [DifyTextField(controller: controller, focusNode: focus)],
          ),
        ),
      ),
    );
    await t.tap(find.byType(EditableText));
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await t.pump();
    t.state<EditableTextState>(find.byType(EditableText)).showToolbar();
    await t.pump();
    await t.pump();
    expect(find.byType(DifyMenuPopup), findsOneWidget);
    expect(find.byType(TextSelectionToolbar), findsNothing);
    expect(find.text('复制'), findsOneWidget);
    expect(focus.hasFocus, true);
    final copy = t.getRect(find.text('复制')), all = t.getRect(find.text('全选'));
    expect(copy.left, all.left);
    expect(copy.top, lessThan(all.top));
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
    expect(copied, '中文🙂');
    expect(focus.hasFocus, true);
    expect(find.byType(DifySelectionMenu), findsNothing);
    await t.runAsync(() => DifyI18n.load('en-US'));
  });

  testWidgets('selection popup stays inside narrow viewport and above the keyboard', (t) async {
    await t.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(320, 640), viewInsets: EdgeInsets.only(bottom: 280)),
          child: Stack(
            children: [
              DifySelectionMenu(
                anchors: const TextSelectionToolbarAnchors(primaryAnchor: Offset(319, 620)),
                buttonItems: [ContextMenuButtonItem(label: 'Copy a long label', onPressed: () {})],
              ),
            ],
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump();
    final rect = t.getRect(find.byType(DifyMenuPopup));
    expect(rect.left, greaterThanOrEqualTo(5));
    expect(rect.right, lessThanOrEqualTo(315));
    expect(rect.bottom, lessThanOrEqualTo(355));
    expect(t.takeException(), null);
  });
}
