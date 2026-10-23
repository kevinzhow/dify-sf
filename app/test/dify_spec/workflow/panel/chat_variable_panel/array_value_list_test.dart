// dify-spec: web/app/components/workflow/panel/chat-variable-panel/components/__tests__/array-value-list.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_values.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

/// `NumericArray`: the list kept in state.
class NumericArray extends StatefulWidget {
  const NumericArray({super.key, required this.onChange});
  final ValueChanged<List<Object?>> onChange;

  @override
  State<NumericArray> createState() => _NumericArrayState();
}

class _NumericArrayState extends State<NumericArray> {
  List<Object?> list = [1];

  @override
  Widget build(BuildContext context) => ArrayValueList(
    isString: false,
    list: list,
    onChange: (v) {
      setState(() => list = v);
      widget.onChange(v);
    },
  );
}

void main() {
  setUp(useDifyTestTranslator);

  Future<void> render(WidgetTester t, Widget w) async {
    final store = WorkflowStore();
    addTearDown(store.dispose);
    await pumpPanel(
      t,
      SizedBox(
        width: 328,
        child: Align(alignment: Alignment.topCenter, child: w),
      ),
      store: store,
    );
  }

  const placeholder = 'workflow.chatVariable.modal.arrayValue';

  group('ArrayValueList', () {
    testWidgets('updates string items, appends a row, and removes an item', (t) async {
      final changes = <List<Object?>>[];
      await render(t, ArrayValueList(isString: true, list: const ['alpha', 'beta'], onChange: changes.add));

      await type(t, byDisplayValue('alpha'), 'alphax');
      await tap(t, find.text('workflow.chatVariable.modal.addArrayValue'));
      await tap(t, buttonNamed('common.operation.remove'));

      expect(changes, [
        ['alphax', 'beta'],
        ['alpha', 'beta', null],
        ['beta'],
      ]);
    });

    testWidgets('edits decimal numbers and keeps cleared rows empty instead of converting them to zero', (t) async {
      final changes = <List<Object?>>[];
      await render(t, NumericArray(onChange: changes.add));

      final input = byPlaceholder(placeholder);
      await type(t, input, '-7.123456');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      expect(changes.last, [-7.123456]);
      expect(byDisplayValue('-7.123456'), findsOneWidget);
      await type(t, input, '');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      expect(t.widget<TextField>(input).controller!.text, '');
      expect(changes.last, [null]);
      await tap(t, find.text('workflow.chatVariable.modal.addArrayValue'));

      expect(changes.last, [null, null]);
    });
  });
}
