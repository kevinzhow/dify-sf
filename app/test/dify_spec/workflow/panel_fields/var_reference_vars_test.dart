// dify-spec: web/app/components/workflow/nodes/_base/components/variable/__tests__/var-reference-vars.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/variable/__tests__/var-reference-vars.helpers.spec.ts
//
// Text Dify upper-cases or capitalises with CSS (`uppercase`, `capitalize`) is transformed in the widget here, so
// those strings are looked up transformed.
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

typedef Change = (List<String>, PickerVar);

void main() {
  group('VarReferenceVars', () {
    const baseVars = [
      VarGroup(title: 'Node A', nodeId: 'node-a', vars: [PickerVar('valid_name', 'string')]),
    ];

    testWidgets('should filter, clear without leaving the search group, and close on escape', (t) async {
      var closed = 0, blurred = 0;
      await render(
        t,
        VarReferenceVars(vars: baseVars, onChange: (_, _) {}, onClose: () => closed++, onBlur: () => blurred++),
      );

      final box = find.byType(TextField);
      expect(find.bySemanticsLabel('workflow.common.searchVar'), findsWidgets);
      await t.tap(box);
      await t.enterText(box, 'valid');
      await t.pump();
      expect(find.text('valid_name'), findsOneWidget);

      await t.tap(find.bySemanticsLabel('common.operation.clear'));
      await t.pump();
      expect(t.widget<TextField>(box).controller!.text, '');
      expect(t.widget<TextField>(box).focusNode!.hasFocus, isTrue);
      expect(blurred, 0);

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(closed, 1);
    });

    testWidgets('should select the first visible variable by default and support arrow navigation in slash mode', (
      t,
    ) async {
      final changes = <Change>[];
      await render(
        t,
        VarReferenceVars(
          hideSearch: true,
          vars: const [
            VarGroup(
              title: 'Node A',
              nodeId: 'node-a',
              vars: [PickerVar('first_value', 'string'), PickerVar('second_value', 'string')],
            ),
          ],
          onChange: (s, v) => changes.add((s, v)),
        ),
      );

      expect(itemOf(t, 'first_value').isSelected, isTrue);
      expect(itemOf(t, 'second_value').isSelected, isFalse);

      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();

      expect(itemOf(t, 'first_value').isSelected, isFalse);
      expect(itemOf(t, 'second_value').isSelected, isTrue);

      await t.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(changes.single.$1, ['node-a', 'second_value']);
      expect(changes.single.$2.variable, 'second_value');
    });

    testWidgets('should call onChange when a variable item is chosen', (t) async {
      final changes = <Change>[];
      await render(t, VarReferenceVars(vars: baseVars, onChange: (s, v) => changes.add((s, v))));

      await t.tap(find.text('valid_name'));

      expect(changes.single.$1, ['node-a', 'valid_name']);
      expect(changes.single.$2.variable, 'valid_name');
    });

    testWidgets('should render empty state and manage input action', (t) async {
      var managed = 0;
      await render(
        t,
        VarReferenceVars(
          vars: const [],
          onChange: (_, _) {},
          showManageInputField: true,
          onManageInputField: () => managed++,
        ),
      );

      expect(find.text('workflow.common.noVar'.toUpperCase()), findsOneWidget);

      await t.tap(find.text('pipeline.inputField.manage'));
      expect(managed, 1);
    });

    testWidgets('should render special variable labels and schema types', (t) async {
      await render(
        t,
        VarReferenceVars(
          hideSearch: true,
          preferSchemaType: true,
          vars: const [
            VarGroup(
              title: 'Specials',
              nodeId: 'node-special',
              vars: [
                PickerVar('env.API_KEY', 'string', schemaType: 'secret'),
                PickerVar('conversation.user_name', 'string', des: 'User name'),
                PickerVar('retrieval.source.title', 'string', isRagVariable: true),
              ],
            ),
          ],
          onChange: (_, _) {},
        ),
      );

      expect(find.byType(TextField), findsNothing);
      expect(find.text('API_KEY'), findsOneWidget);
      expect(find.text('user_name'), findsOneWidget);
      expect(find.text('Secret'), findsOneWidget);
    });

    testWidgets('should render flat vars and the last output separator', (t) async {
      await render(
        t,
        VarReferenceVars(
          hideSearch: true,
          vars: const [
            VarGroup(title: 'Flat', nodeId: 'node-flat', isFlat: true, vars: [PickerVar('current', 'string')]),
            VarGroup(title: 'Node B', nodeId: 'node-b', vars: [PickerVar('payload', 'string')]),
          ],
          onChange: (_, _) {},
        ),
      );

      expect(find.text('workflow.debug.lastOutput'.toUpperCase()), findsOneWidget);
      expect(find.text('current_prompt'), findsOneWidget);
    });

    const specials = [
      VarGroup(
        title: 'Specials',
        nodeId: 'node-special',
        vars: [
          PickerVar('env.API_KEY', 'string'),
          PickerVar('conversation.user_name', 'string', des: 'User name'),
          PickerVar('current', 'string'),
          PickerVar('asset', 'file'),
        ],
      ),
    ];

    void expectSpecials(List<Change> changes) {
      expect(
        [for (final c in changes) c.$1],
        [
          ['env', 'API_KEY'],
          ['conversation', 'user_name'],
          ['node-special', 'current'],
          ['node-special', 'asset'],
        ],
      );
      expect([for (final c in changes) c.$2.variable], ['env.API_KEY', 'conversation.user_name', 'current', 'asset']);
    }

    testWidgets('should resolve selectors for special variables and file support', (t) async {
      final changes = <Change>[];
      await render(
        t,
        VarReferenceVars(
          hideSearch: true,
          isSupportFileVar: true,
          vars: specials,
          onChange: (s, v) => changes.add((s, v)),
        ),
      );

      for (final text in ['API_KEY', 'user_name', 'current', 'asset']) {
        await t.tap(find.text(text));
      }

      expectSpecials(changes);
    });

    testWidgets('should resolve selectors for special variables and file support from keyboard selection', (t) async {
      final changes = <Change>[];
      await render(
        t,
        VarReferenceVars(
          hideSearch: true,
          isSupportFileVar: true,
          vars: specials,
          onChange: (s, v) => changes.add((s, v)),
        ),
      );

      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      for (var i = 0; i < 3; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
      }

      expectSpecials(changes);
    });

    testWidgets('should render object vars and select them by node path', (t) async {
      final changes = <Change>[];
      await render(
        t,
        VarReferenceVars(
          hideSearch: true,
          vars: const [
            VarGroup(
              title: 'Object vars',
              nodeId: 'node-obj',
              vars: [
                PickerVar('payload', 'object', children: [PickerVar('child', 'string')]),
              ],
            ),
          ],
          onChange: (s, v) => changes.add((s, v)),
        ),
      );

      await t.tap(find.text('payload'));
      expect(changes.single.$1, ['node-obj', 'payload']);
      expect(changes.single.$2.variable, 'payload');
    });

    testWidgets('should filter by externally controlled search text and match child variables', (t) async {
      await render(
        t,
        VarReferenceVars(
          hideSearch: true,
          searchText: 'child',
          vars: const [
            VarGroup(
              title: 'Object vars',
              nodeId: 'node-obj',
              vars: [
                PickerVar('payload', 'object', children: [PickerVar('child_name', 'string')]),
                PickerVar('other_value', 'string'),
              ],
            ),
          ],
          onChange: (_, _) {},
        ),
      );

      expect(find.byType(TextField), findsNothing);
      expect(find.text('payload'), findsOneWidget);
      expect(find.text('other_value'), findsNothing);
    });

    testWidgets('should ignore file vars when file support is disabled and forward blur-sm events', (t) async {
      final changes = <Change>[];
      var blurred = 0;
      await render(
        t,
        VarReferenceVars(
          vars: const [
            VarGroup(title: 'Files', nodeId: 'node-files', vars: [PickerVar('asset', 'file')]),
          ],
          onChange: (s, v) => changes.add((s, v)),
          onBlur: () => blurred++,
        ),
      );

      final focus = t.widget<TextField>(find.byType(TextField)).focusNode!;
      focus.requestFocus();
      await t.pump();
      focus.unfocus();
      await t.pump();
      expect(blurred, 1);

      await t.tap(find.text('asset'));
      expect(changes, isEmpty);
    });

    testWidgets('should ignore file vars when file support is disabled during keyboard selection', (t) async {
      final changes = <Change>[];
      await render(
        t,
        VarReferenceVars(
          hideSearch: true,
          vars: const [
            VarGroup(title: 'Files', nodeId: 'node-files', vars: [PickerVar('asset', 'file')]),
          ],
          onChange: (s, v) => changes.add((s, v)),
        ),
      );

      await t.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(changes, isEmpty);
    });
  });

  group('var-reference-vars helpers', () {
    test('should derive display names for flat and mapped variables', () {
      expect(varsDisplayName('sys.files', false), 'files');
      expect(varsDisplayName('current', true, isInCodeGeneratorInstructionEditor: true), 'current_code');
      expect(varsDisplayName('foo', true), 'foo');
    });

    test('should resolve variable categories', () {
      expect(varsVariableCategory(isEnv: true, isChatVar: false), 'environment');
      expect(varsVariableCategory(isEnv: false, isChatVar: true), 'conversation');
      expect(varsVariableCategory(isEnv: false, isChatVar: false, isLoopVar: true), 'loop');
      expect(varsVariableCategory(isEnv: false, isChatVar: false, isRagVariable: true), 'rag');
    });

    test('should build selectors by variable scope and file support', () {
      expect(
        varsValueSelector(
          item: const PickerVar('output', 'string'),
          isFlat: true,
          isSupportFileVar: true,
          isFile: false,
          isSys: false,
          isEnv: false,
          isChatVar: false,
          nodeId: 'node-1',
          objPath: const [],
        ),
        ['output'],
      );
      expect(
        varsValueSelector(
          item: const PickerVar('env.apiKey', 'string'),
          isSupportFileVar: true,
          isFile: false,
          isSys: false,
          isEnv: true,
          isChatVar: false,
          nodeId: 'node-1',
          objPath: const ['parent'],
        ),
        ['parent', 'env', 'apiKey'],
      );
      expect(
        varsValueSelector(
          item: const PickerVar('file', 'file'),
          isFile: true,
          isSys: false,
          isEnv: false,
          isChatVar: false,
          nodeId: 'node-1',
          objPath: const [],
        ),
        isNull,
      );
    });

    test('should filter out invalid vars and apply search text', () {
      final vars = filterReferenceVars(const [
        VarGroup(
          title: 'Node A',
          nodeId: 'node-a',
          vars: [PickerVar('valid_name', 'string'), PickerVar('invalid-key', 'string')],
        ),
        VarGroup(title: 'Node B', nodeId: 'node-b', vars: [PickerVar('another_value', 'string')]),
      ], 'another');

      expect(vars, hasLength(1));
      expect(vars[0].title, 'Node B');
      expect([for (final v in vars[0].vars) v.variable], ['another_value']);
    });

    test('should keep parent vars when search text matches a child variable', () {
      final vars = filterReferenceVars(const [
        VarGroup(
          title: 'Node A',
          nodeId: 'node-a',
          vars: [
            PickerVar('payload', 'object', children: [PickerVar('child_name', 'string')]),
          ],
        ),
        VarGroup(title: 'Node B', nodeId: 'node-b', vars: [PickerVar('other_value', 'string')]),
      ], 'child');

      expect(vars, hasLength(1));
      expect(vars[0].title, 'Node A');
      expect([for (final v in vars[0].vars) v.variable], ['payload']);
    });
  });
}
