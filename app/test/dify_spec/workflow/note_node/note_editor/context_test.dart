// dify-spec: web/app/components/workflow/note-node/note-editor/__tests__/context.spec.tsx
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

const _empty = '{"root":{"children":[]}}';
const _populated =
    '{"root":{"children":[{"children":[{"detail":0,"format":0,"mode":"normal","style":"","text":"hello",'
    '"type":"text","version":1}],"direction":null,"format":"","indent":0,"textFormat":0,"textStyle":"",'
    '"type":"paragraph","version":1}],"direction":null,"format":"","indent":0,"type":"root","version":1}}';

/// Shows whether the store has the selection bold, as Dify's ContextProbe does.
Widget _probe() => Builder(
  builder: (context) {
    final store = NoteEditorScope.of(context).controller.store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Text(store.selectedIsBold ? 'bold' : 'not-bold'),
    );
  },
);

void main() {
  group('NoteEditorContextProvider', () {
    group('Rendering', () {
      testWidgets('should render children with the note editor store defaults', (t) async {
        final c = await pumpInEditor(t, _probe(), value: _empty);
        expect(find.text('not-bold'), findsOneWidget);
        expect(c.editable, isTrue);
        expect(c.text, '');
      });
    });

    group('Editor State Initialization', () {
      testWidgets('should use an empty editor state when \$name', (t) async {
        // value is malformed json; root has no children
        for (final value in ['{invalid', _empty]) {
          final c = await pumpInEditor(t, _probe(), value: value);
          expect(c.text, '', reason: value);
          await t.pumpWidget(const SizedBox());
        }
      });

      testWidgets('should restore lexical content and forward editable prop', (t) async {
        final c = await pumpInEditor(t, editorBox, value: _populated, editable: false);
        expect(c.text, 'hello');
        expect(c.editable, isFalse);
        expect(t.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      });
    });
  });
}
