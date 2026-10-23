// dify-spec: web/app/components/workflow/nodes/_base/components/variable/__tests__/var-reference-picker.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/variable/__tests__/var-reference-picker.branches.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/variable/__tests__/var-reference-picker.trigger.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/variable/__tests__/var-reference-picker.helpers.spec.ts
//
// The trigger is part of VarReferencePicker here (Dify renders it separately with its state as props), so the
// trigger cases drive a picker in the matching state. Clearing reports an empty selector: Dify reports `''` for a
// picker in its default constant kind, which every reader treats as "no value". Hover-only controls (the clear and
// table remove buttons) are reached with a mouse hover first.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

typedef Change = (List<String>, PickerVar?);

const startNode = Node(id: 'start-node', type: 'start', title: 'Start');
const sourceNode = Node(id: 'node-a', type: 'code', title: 'Source Node');
const currentNode = Node(id: 'node-current', type: 'code', title: 'Current Node');

const availableVars = [
  VarGroup(
    nodeId: 'node-a',
    title: 'Source Node',
    vars: [
      PickerVar('answer', 'string'),
      PickerVar('payload', 'object', children: [PickerVar('child', 'string')]),
    ],
  ),
];

final _trigger = find.byKey(const Key('var-reference-picker-trigger'));

Future<List<Change>> renderPicker(
  WidgetTester t, {
  List<String> value = const [],
  List<VarGroup> vars = availableVars,
  bool readonly = false,
  String? placeholder,
  Widget? trigger,
  ValueChanged<bool>? onOpen,
  ValueChanged<String>? onJump,
  ValueChanged<String>? onConstantChange,
  VoidCallback? onRemove,
  bool isSupportConstantValue = false,
  VarKindType defaultVarKindType = VarKindType.constant,
  ConstantSchema? constantSchema,
  String constantValue = '',
  bool isAddBtnTrigger = false,
  bool isInTable = false,
  bool isLoading = false,
  String? typePlaceHolder,
  String? valueTypePlaceHolder,
  String? type,
}) async {
  final changes = <Change>[];
  await render(
    t,
    VarReferencePicker(
      value: value,
      scope: scopeOf(vars, nodes: const [startNode, sourceNode, currentNode], start: startNode, type: type),
      onChange: (s, v) => changes.add((s, v)),
      readonly: readonly,
      placeholder: placeholder,
      trigger: trigger,
      onOpen: onOpen,
      onJump: onJump,
      onConstantChange: onConstantChange,
      onRemove: onRemove,
      isSupportConstantValue: isSupportConstantValue,
      defaultVarKindType: defaultVarKindType,
      constantSchema: constantSchema,
      constantValue: constantValue,
      isAddBtnTrigger: isAddBtnTrigger,
      isInTable: isInTable,
      isLoading: isLoading,
      typePlaceHolder: typePlaceHolder,
      valueTypePlaceHolder: valueTypePlaceHolder,
    ),
  );
  return changes;
}

Future<void> hoverTrigger(WidgetTester t) async {
  final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(t.getCenter(_trigger));
  await t.pump();
}

Future<void> ctrlTap(WidgetTester t, Finder f) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.tap(f);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
}

String? get focusedLabel => FocusManager.instance.primaryFocus?.debugLabel;

void main() {
  group('VarReferencePicker', () {
    testWidgets('should open the popup and select a variable from the available list', (t) async {
      final changes = await renderPicker(t);

      await t.tap(_trigger);
      await t.pumpAndSettle();
      expect(focusedLabel, 'var picker search');
      await t.tap(find.text('answer'));

      expect(changes.single.$1, ['node-a', 'answer']);
      expect(changes.single.$2!.variable, 'answer');
      expect(changes.single.$2!.type, 'string');
    });

    testWidgets('should render the selected node and variable name, then clear it', (t) async {
      final changes = await renderPicker(t, value: const ['node-a', 'answer']);

      expect(find.text('Source Node'), findsOneWidget);
      expect(find.text('answer'), findsOneWidget);

      await hoverTrigger(t);
      await t.tap(find.bySemanticsLabel('common.operation.clear'));
      expect(changes.single.$1, isEmpty);
    });

    testWidgets('should show object variables in the popup and select the root object path', (t) async {
      final changes = await renderPicker(t);

      await t.tap(_trigger);
      await t.pumpAndSettle();
      await t.tap(find.text('payload'));

      expect(changes.single.$1, ['node-a', 'payload']);
      expect(changes.single.$2!.type, 'object');
    });

    testWidgets('should render a placeholder and respect readonly mode', (t) async {
      final changes = await renderPicker(t, readonly: true, placeholder: 'Pick a variable');

      expect(find.text('Pick a variable'), findsOneWidget);

      await t.tap(_trigger);
      await t.pumpAndSettle();
      expect(find.text('answer'), findsNothing);
      expect(changes, isEmpty);
    });
  });

  group('VarReferencePicker branches', () {
    testWidgets('should toggle a custom trigger and call onOpen when opening the popup', (t) async {
      final opened = <bool>[];
      await renderPicker(t, trigger: const Text('custom-trigger'), onOpen: opened.add);

      await t.tap(find.text('custom-trigger'));
      await t.pumpAndSettle();

      expect(find.text('answer'), findsOneWidget);
      expect(opened, [true]);
    });

    testWidgets('should rewrite system selectors before forwarding the selection', (t) async {
      final changes = await renderPicker(
        t,
        vars: const [
          VarGroup(nodeId: 'start-node', title: 'Start', isStartNode: true, vars: [PickerVar('sys.query', 'string')]),
        ],
      );

      await t.tap(_trigger);
      await t.pumpAndSettle();
      await t.tap(find.text('query'));

      expect(changes.single.$1, ['sys', 'query']);
      expect(changes.single.$2!.variable, 'sys.query');
      expect(normalizeSysSelector(const ['node-a', 'sys.query']), ['sys', 'query']);
    });

    testWidgets('should clear variable-mode values to an empty selector array', (t) async {
      final changes = await renderPicker(
        t,
        defaultVarKindType: VarKindType.variable,
        isSupportConstantValue: true,
        value: const ['node-a', 'answer'],
      );

      await hoverTrigger(t);
      await t.tap(find.bySemanticsLabel('common.operation.clear'));

      expect(changes.single.$1, isEmpty);
    });

    testWidgets('should jump to the selected node when ctrl-clicking the node name', (t) async {
      final jumps = <String>[];
      final changes = await renderPicker(t, value: const ['node-a', 'answer'], onJump: jumps.add);

      await ctrlTap(t, find.text('Source Node'));

      expect(jumps, ['node-a']);
      expect(changes, isEmpty);
    });

    testWidgets('should focus the hidden control input for supported constant values', (t) async {
      await renderPicker(
        t,
        isSupportConstantValue: true,
        constantSchema: const ConstantSchema(type: 'text-input'),
        constantValue: 'constant-value',
      );

      await t.tap(_trigger);
      await t.pump();

      expect(focusedLabel, 'var picker constant');
    });

    testWidgets('should render tooltip branches for partial paths and invalid variables without changing behavior', (
      t,
    ) async {
      await renderPicker(
        t,
        vars: const [
          VarGroup(
            nodeId: 'node-a',
            title: 'Source Node',
            vars: [
              PickerVar('payload', 'object', children: [PickerVar('child', 'string')]),
            ],
          ),
        ],
        value: const ['node-a', 'payload', 'child'],
      );
      expect(find.text('child'), findsOneWidget);

      await renderPicker(t, value: const ['missing-node', 'answer']);
      expect(find.text('answer'), findsOneWidget);
      expect(find.byKey(const Key('var-reference-picker-error-icon')), findsOneWidget);
    });

    testWidgets('should not show an error icon for env variables that still exist in the workflow env list', (t) async {
      await renderPicker(
        t,
        vars: [
          ...availableVars,
          const VarGroup(nodeId: 'env', title: 'ENVIRONMENT', vars: [PickerVar('env.API_KEY', 'string')]),
        ],
        value: const ['env', 'API_KEY'],
      );

      expect(find.text('API_KEY'), findsOneWidget);
      expect(find.byKey(const Key('var-reference-picker-error-icon')), findsNothing);
    });
  });

  group('VarReferencePickerTrigger', () {
    testWidgets('should show the placeholder state and open the picker for variable mode', (t) async {
      final opened = <bool>[];
      await renderPicker(t, placeholder: 'Pick variable', onOpen: opened.add);

      expect(find.text('Pick variable'), findsOneWidget);
      await t.tap(_trigger);
      expect(opened, [true]);
    });

    testWidgets('should render the selected variable state and clear it', (t) async {
      final jumps = <String>[];
      final changes = await renderPicker(t, value: const ['node-a', 'answer'], type: 'string', onJump: jumps.add);

      expect(find.text('Source Node'), findsOneWidget);
      expect(find.text('answer'), findsOneWidget);

      await ctrlTap(t, find.text('Source Node'));
      expect(jumps, ['node-a']);

      await hoverTrigger(t);
      await t.tap(find.bySemanticsLabel('common.operation.clear'));
      expect(changes.length, 1);
    });

    testWidgets('should render the support-constant trigger and focus constant input when clicked', (t) async {
      await renderPicker(
        t,
        isSupportConstantValue: true,
        constantSchema: const ConstantSchema(type: 'text-input'),
        constantValue: 'constant-value',
      );

      await t.tap(_trigger);
      await t.pump();
      expect(focusedLabel, 'var picker constant');

      await t.tap(find.text('Constant'));
      await t.pumpAndSettle();
      expect(find.byType(VarReferenceVars), findsNothing);
    });

    testWidgets('should render add button trigger in table mode', (t) async {
      await renderPicker(t, value: const ['node-a', 'answer'], isAddBtnTrigger: true, isInTable: true);

      expect(find.bySemanticsLabel('common.operation.add'), findsOneWidget);
    });

    testWidgets('should stay inert in readonly mode and show value type placeholder badge', (t) async {
      final opened = <bool>[];
      await renderPicker(
        t,
        placeholder: 'Readonly placeholder',
        readonly: true,
        typePlaceHolder: 'string',
        valueTypePlaceHolder: 'text',
        onOpen: opened.add,
      );

      await t.tap(_trigger);
      expect(opened, isEmpty);
      expect(find.text('string'), findsOneWidget);
      expect(find.text('Text'), findsOneWidget);
    });

    testWidgets('should show loading placeholder and remove rows in table mode', (t) async {
      var removed = 0;
      await renderPicker(
        t,
        isInTable: true,
        isLoading: true,
        onRemove: () => removed++,
        placeholder: 'Loading variable',
      );

      expect(find.text('Loading variable'), findsOneWidget);

      await hoverTrigger(t);
      await t.tap(find.bySemanticsLabel('common.operation.remove'));
      expect(removed, 1);
    });
  });

  group('var-reference-picker.helpers', () {
    test('should detect whether the picker has a variable value', () {
      expect(pickerHasValue(false, const ['node-1', 'answer']), isTrue);
      expect(pickerHasValue(true, const ['constant']), isFalse);
      expect(pickerHasValue(false, const []), isFalse);
    });

    test('should detect iteration and loop variables by parent node id', () {
      expect(isContainerVar(true, const ['iter-parent', 'item'], 'iter-parent'), isTrue);
      expect(isContainerVar(true, const ['iter-parent', 'value'], 'iter-parent'), isFalse);
      expect(isContainerVar(true, const ['loop-parent', 'index'], 'loop-parent'), isTrue);
      expect(isContainerVar(false, const ['loop-parent', 'item'], 'loop-parent'), isFalse);
    });

    test('should resolve output variable nodes for normal, system, iteration, and loop variables', () {
      const start = Node(id: 'inset-s-1', type: 'start', title: 'Start Node');
      const normal = Node(id: 'node-a', type: 'code', title: 'Answer Node');
      const iteration = Node(id: 'iter-parent', type: 'iteration', title: 'Iteration Parent');
      const loop = Node(id: 'loop-parent', type: 'loop', title: 'Loop Parent');
      Node? lookup(String id) => id == 'node-a' ? normal : null;

      expect(
        outputVarNodeOf(hasValue: true, isConstant: false, value: const ['node-a', 'answer'], lookup: lookup)?.title,
        'Answer Node',
      );
      expect(
        outputVarNodeOf(
          hasValue: true,
          isConstant: false,
          value: const ['sys', 'files'],
          lookup: lookup,
          startNode: start,
        ),
        start,
      );
      expect(
        outputVarNodeOf(
          hasValue: true,
          isConstant: false,
          value: const ['iter-parent', 'item'],
          lookup: lookup,
          isIterationVar: true,
          iterationNode: iteration,
        ),
        iteration,
      );
      expect(
        outputVarNodeOf(
          hasValue: true,
          isConstant: false,
          value: const ['loop-parent', 'item'],
          lookup: lookup,
          isLoopVar: true,
          loopNode: loop,
        ),
        loop,
      );
      expect(
        outputVarNodeOf(hasValue: true, isConstant: false, value: const ['missing-node', 'answer'], lookup: lookup),
        isNull,
      );
    });

    test('should format display names and output node ids correctly', () {
      expect(pickerOutputVarNodeId(true, const ['node-a', 'answer']), 'node-a');
      expect(pickerOutputVarNodeId(false, const []), '');

      expect(pickerVarDisplayName(true, const ['sys', 'query']), 'query');
      expect(pickerVarDisplayName(true, const ['node-a', 'answer']), 'answer');
      expect(pickerVarDisplayName(false, const []), '');
    });

    test('should derive variable meta and category from selectors', () {
      const envVars = [
        VarGroup(nodeId: 'env', title: 'ENVIRONMENT', vars: [PickerVar('env.API_KEY', 'string')]),
      ];
      final meta = pickerVariableMeta(
        null,
        const ['env', 'API_KEY'],
        'API_KEY',
        availableVars: envVars,
        canValidateSpecialVars: true,
      );
      expect((meta.isEnv, meta.isValidVar, meta.isException), (true, true, false));
      final missing = pickerVariableMeta(
        null,
        const ['env', 'MISSING_KEY'],
        'MISSING_KEY',
        availableVars: envVars,
        canValidateSpecialVars: true,
      );
      expect((missing.isEnv, missing.isValidVar), (true, false));
      final unchecked = pickerVariableMeta(null, const ['env', 'MISSING_KEY'], 'MISSING_KEY', availableVars: envVars);
      expect((unchecked.isEnv, unchecked.isValidVar), (true, true));

      expect(pickerVariableCategory(isChatVar: true), 'conversation');
      expect(pickerVariableCategory(isGlobal: true), 'global');
      expect(pickerVariableCategory(isLoopVar: true), 'loop');
      expect(pickerVariableCategory(isEnv: true), 'environment');
      expect(pickerVariableCategory(isRagVar: true), 'rag');
    });

    test('should calculate width allocations and tooltip behavior', () {
      expect(
        pickerWidthAllocations(240, 'Node', 'answer', 'string'),
        isA<({int maxNodeNameWidth, int maxTypeWidth, int maxVarNameWidth})>(),
      );
      expect(pickerWidthAllocations(240, '', 'sys.user_id', 'String'), (
        maxNodeNameWidth: 0,
        maxTypeWidth: 64,
        maxVarNameWidth: 119,
      ));
      expect(pickerWidthAllocations(240, 'User Input', 'aa', 'String').maxVarNameWidth, 16);

      expect(pickerTooltipContent(true, true, true), PickerHover.fullPath);
      expect(pickerTooltipContent(true, false, false), PickerHover.invalidVariable);
      expect(pickerTooltipContent(false, false, true), isNull);
    });

    test('should produce dynamic select schemas and detect partial selectors', () {
      const schema = ConstantSchema(type: 'dynamic-select');
      expect(
        dynamicSelectSchema(
          dynamicOptions: const [(value: 'a', label: 'A')],
          isLoading: false,
          schema: schema,
          value: 'selected',
        )!.options.map((o) => o.value),
        ['a'],
      );
      expect(
        dynamicSelectSchema(
          dynamicOptions: null,
          isLoading: true,
          schema: schema,
          value: 'selected',
        )!.options.map((o) => o.value),
        ['selected'],
      );
      expect(
        dynamicSelectSchema(dynamicOptions: null, isLoading: false, schema: schema, value: 'selected')!.options,
        isEmpty,
      );

      expect(isShowAPartSelector(const ['node-a', 'payload', 'child']), isTrue);
      expect(isShowAPartSelector(const ['rag', 'node-a', 'payload']), isFalse);
    });

    test('should keep mapped variable names for known workflow aliases', () {
      expect(pickerVarDisplayName(true, const ['sys', 'files']), 'files');
      final meta = pickerVariableMeta('string', const ['conversation', 'name'], 'name', hasOutputVarNode: true);
      expect((meta.isChatVar, meta.isValidVar), (true, true));
    });

    test('should preserve non-dynamic schemas', () {
      const schema = ConstantSchema(type: 'text-input');
      expect(dynamicSelectSchema(dynamicOptions: null, isLoading: false, schema: schema, value: ''), same(schema));
    });
  });
}
