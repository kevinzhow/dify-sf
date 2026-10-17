// dify-spec: web/app/components/workflow/note-node/note-editor/__tests__/editor.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  group('Editor', () {
    group('Rendering', () {
      testWidgets('should render the placeholder text and content editable surface', (t) async {
        await pumpInEditor(t, const SizedBox(width: 214, height: 60, child: NoteEditor(placeholder: 'Type note')));
        expect(find.text('Type note'), findsOneWidget);
        expect(find.byType(EditableText), findsOneWidget);
      });

      testWidgets('should render linked text with distinct link styling', (t) async {
        final c = await pumpInEditor(
          t,
          editorBox,
          value: lexical([('Linked docs', const NoteStyle(url: 'https://example.com/docs'))]),
        );
        final span = c.buildTextSpan(context: t.element(find.byType(EditableText)), withComposing: false);
        TextSpan? link;
        span.visitChildren((s) {
          if (s is TextSpan && s.text == 'Linked docs') link = s;
          return link == null;
        });
        expect(link, isNotNull);
        expect(link!.style!.color, DifyColors.textAccent);
        expect(link!.style!.fontWeight, FontWeight.w500);
        expect(link!.style!.decoration, TextDecoration.underline);
        expect(find.text('Linked docs', findRichText: true), findsOneWidget);
      });
    });

    group('Focus Management', () {
      testWidgets('should disable shortcuts on focus and re-enable them on blur-sm', (t) async {
        final calls = <bool>[];
        final c = await pumpInEditor(
          t,
          SizedBox(width: 214, height: 60, child: NoteEditor(setHistoryShortcutsEnabled: calls.add)),
        );
        await t.tap(find.byType(EditableText));
        await t.pump(Duration.zero);
        FocusManager.instance.primaryFocus?.unfocus();
        await t.pump(Duration.zero);
        expect(calls, [false, true]);
        expect(c.text, '');
      });
    });

    group('Change Handling', () {
      testWidgets('should pass editor updates through onChange', (t) async {
        final changes = <String>[];
        await pumpInEditor(
          t,
          SizedBox(width: 214, height: 60, child: NoteEditor(onChange: (n) => changes.add(n.text))),
        );
        await t.enterText(find.byType(EditableText), 'hello');
        await t.enterText(find.byType(EditableText), 'hello world');
        await t.pump(Duration.zero);
        expect(changes, contains('hello world'));
      });
    });
  });
}
