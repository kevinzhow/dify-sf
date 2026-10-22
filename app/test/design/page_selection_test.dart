import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/markdown.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String? copied;
  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        if (call.method == 'Clipboard.hasStrings') return {'value': copied?.isNotEmpty ?? false};
        return null;
      },
    );
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );

  Future<void> copy(WidgetTester t) async {
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyC);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump();
  }

  testWidgets('page text supports mouse selection across paragraphs and rich text', (t) async {
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: const DifyPage(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Alpha paragraph'),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: 'Beta '),
                    TextSpan(
                      text: 'bold',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              DifyButton(child: Text('Action')),
            ],
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump();
    final a = t.getRect(find.text('Alpha paragraph')), b = t.getRect(find.text('Beta bold'));
    final mouse = await t.startGesture(a.centerLeft + const Offset(1, 0), kind: PointerDeviceKind.mouse);
    await mouse.moveTo(b.centerRight - const Offset(1, 0));
    await mouse.up();
    await t.pump();
    await copy(t);
    expect(copied, 'Alpha paragraph\nBeta bold');
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await copy(t);
    expect(copied, isNot(contains('Action')));
  });

  testWidgets('input editing selection stays local inside a selectable page', (t) async {
    final input = TextEditingController(text: 'editable text');
    addTearDown(input.dispose);
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: DifyPage(
          body: Column(
            children: [
              const Text('Page heading'),
              DifyTextField(controller: input),
            ],
          ),
        ),
      ),
    );
    await t.tap(find.byType(EditableText));
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await copy(t);
    expect(copied, 'editable text');
    expect(input.selection, const TextSelection(baseOffset: 0, extentOffset: 13));
  });
  testWidgets('scrollable Markdown copies separate paragraphs with line breaks', (t) async {
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: const DifyPage(
          body: SingleChildScrollView(child: DifyMarkdown(content: 'First paragraph\n\n**Second** paragraph')),
        ),
      ),
    );
    await t.pump();
    await t.pump();
    final first = t.getRect(find.text('First paragraph'));
    final last = t.getRect(find.text('Second paragraph'));
    final mouse = await t.startGesture(first.centerLeft + const Offset(1, 0), kind: PointerDeviceKind.mouse);
    await mouse.moveTo(last.centerRight - const Offset(1, 0));
    await mouse.up();
    await t.pump();
    await copy(t);
    expect(copied, 'First paragraph\nSecond paragraph');
  });

  testWidgets('a dialog has its own selection and Dify context menu', (t) async {
    final navigator = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      DifyApplication(
        navigatorKey: navigator,
        theme: difyTheme(),
        home: const DifyPage(body: Text('Background text')),
      ),
    );
    final dialog = showDifyDialog<void>(
      navigator.currentContext!,
      builder: (_) => const DifyDialogSurface(child: Text('Dialog content')),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Dialog content'));
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await copy(t);
    expect(copied, 'Dialog content');
    final mouse = await t.startGesture(
      t.getCenter(find.text('Dialog content')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await mouse.up();
    await t.pump();
    expect(find.byType(DifySelectionMenu), findsOneWidget);
    navigator.currentState!.pop();
    await t.pumpAndSettle();
    await dialog;
  });
}
