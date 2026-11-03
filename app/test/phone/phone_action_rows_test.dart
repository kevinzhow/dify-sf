// Rows whose actions Dify shows on hover, by touch on a phone (fixes after PR #90, item 4): the variable aggregator's
// groups, the agent (v2) outputs, the question classifier's classes, the LLM's messages and IF/ELSE's cases and
// conditions. Each row is at least 48 dp; its 44 dp "…" (and a long press) open its actions (Edit, Delete, Move up,
// Move down, as they apply); the hover-only controls are gone. Every action finds its row by identity when it runs,
// so another user's change made while the action sheet is open does not redirect it. At 411x914 and 360x780.
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/if_else_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/variable_aggregator_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_v2_logic.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_v2_outputs.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/qc_class_list.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart' show VarScope;
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/config_prompt.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

typedef _Json = Map<String, Object?>;

/// Pumps [build] on a phone page of [size]; the returned setter is another user's change (the page rebuilds).
Future<StateSetter> _pump(WidgetTester t, Size size, Widget Function() build) async {
  phoneWindow(t, size: size);
  late StateSetter update;
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      home: DifyPage(
        edgeToEdge: true,
        body: StatefulBuilder(
          builder: (context, set) {
            update = set;
            return SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 80, 16, 40), child: build());
          },
        ),
      ),
    ),
  );
  await settle(t, 400);
  return update;
}

Finder _more(String label) => find.byKey(ValueKey('dify-action-row-more-$label'));

/// The touch row around [f].
Finder _rowOf(Finder f) => find.ancestor(of: f, matching: find.byType(DifyActionRow)).first;

void _touchSizes(WidgetTester t, String label) {
  expect(_more(label), findsOneWidget, reason: '"…" of $label');
  final more = t.getSize(_more(label));
  expect(more.width, greaterThanOrEqualTo(44), reason: label);
  expect(more.height, greaterThanOrEqualTo(44), reason: label);
  expect(t.getSize(_rowOf(_more(label))).height, greaterThanOrEqualTo(48), reason: '$label row');
}

Future<void> _tapText(WidgetTester t, String text) async {
  await t.tap(find.text(text).last);
  await settle(t, 600);
}

/// An action of the open action sheet.
Finder _action(String label) => find.text(label);

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in phoneSizes) {
    final at = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$at variable aggregator groups: the header is a touch row; "…" and a long press offer Rename and '
        'Delete; Delete removes its own group after another user changed the groups', (t) async {
      _Json g(String id, String name) => {'groupId': id, 'group_name': name, 'output_type': 'any', 'variables': []};
      var inputs = <String, Object?>{
        'output_type': 'any',
        'variables': <Object?>[],
        'advanced_settings': {
          'group_enabled': true,
          'groups': [g('g1', 'Group1'), g('g2', 'Group2'), g('g3', 'Group3')],
        },
      };
      late StateSetter update;
      final config = VariableAggregatorConfig(
        id: 'agg',
        inputs: () => inputs,
        setInputs: (next) => update(() => inputs = next),
        handleOutVarRenameChange: (_, _, _) {},
        isVarUsedInNodes: (_) => false,
        removeUsedVarInNodes: (_) {},
        renameDebounce: Duration.zero,
      );
      List<_Json> groups() => [
        for (final x in (inputs['advanced_settings'] as Map)['groups'] as List) (x as Map).cast<String, Object?>(),
      ];
      update = await _pump(
        t,
        size,
        () => Column(
          children: [
            for (final x in groups())
              VarGroupItem(
                key: ValueKey(x['groupId']),
                readOnly: false,
                payload: x,
                onChange: config.handleListOrTypeChangeInGroup('${x['groupId']}'),
                groupEnabled: true,
                canRemove: groups().length > 1,
                onRemove: config.handleGroupRemoved('${x['groupId']}'),
                onGroupNameChange: config.handleVarGroupNameChange('${x['groupId']}'),
                scope: const VarScope(),
                addScope: const VarScope(),
              ),
          ],
        ),
      );
      for (final name in ['Group1', 'Group2', 'Group3']) {
        _touchSizes(t, name);
      }
      // No hover-only bin on a phone.
      expect(find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == 'Remove'), findsNothing);
      await t.tap(_more('Group2'));
      await settle(t, 600);
      expect(_action('Rename'), findsOneWidget);
      expect(_action('Delete'), findsOneWidget);
      // Another user removes Group1 and adds Group0 at the top while the sheet is open.
      update(() {
        inputs = {
          ...inputs,
          'advanced_settings': {
            'group_enabled': true,
            'groups': [g('g0', 'Group0'), ...groups().skip(1)],
          },
        };
      });
      await settle(t, 300);
      await _tapText(t, 'Delete');
      expect([for (final x in groups()) x['group_name']], ['Group0', 'Group3']);
      // A long press offers the same actions; Rename turns the name into a field.
      await t.longPress(_rowOf(_more('Group3')));
      await settle(t, 600);
      expect(_action('Delete'), findsOneWidget);
      await _tapText(t, 'Rename');
      expect(find.byWidgetPredicate((w) => w is EditableText && w.controller.text == 'Group3'), findsOneWidget);
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('$at agent outputs: rows are touch rows (a tap edits; "…" and a long press offer Edit, Add and '
        'Delete); the hover buttons are gone; Delete finds its output and child by name after a change', (t) async {
      var outputs = <_Json>[
        agentV2SystemTextOutput,
        {'name': 'alpha', 'type': 'string', 'required': true},
        {
          'name': 'beta',
          'type': 'object',
          'required': false,
          'children': [
            {'name': 'x', 'type': 'string', 'required': false},
            {'name': 'y', 'type': 'string', 'required': false},
          ],
        },
      ];
      final update = await _pump(
        t,
        size,
        () => AgentOutputVariables(outputs: outputs, collapsed: false, onChange: (next) => outputs = next),
      );
      void remote(List<_Json> next) => update(() => outputs = next);
      for (final name in ['alpha', 'beta', 'x', 'y']) {
        _touchSizes(t, name);
      }
      expect(_more('text'), findsNothing, reason: 'the system output has no actions');
      expect(
        find.byWidgetPredicate(
          (w) => w is DifyIconButton && w.icon is RemixIcon && (w.icon as RemixIcon).name == 'pencil-line',
        ),
        findsNothing,
        reason: 'no hover Edit / Delete buttons on a phone',
      );
      // Delete alpha after another user put "new" before it.
      await t.tap(_more('alpha'));
      await settle(t, 600);
      expect(_action('Edit'), findsOneWidget);
      remote([
        outputs[0],
        {'name': 'new', 'type': 'string'},
        ...outputs.skip(1),
      ]);
      await settle(t, 300);
      await _tapText(t, 'Delete');
      remote(outputs);
      await settle(t, 300);
      expect([for (final o in outputs) o['name']], ['text', 'new', 'beta']);
      // Delete the child y after another user moved beta up and reordered its children.
      await t.tap(_more('y'));
      await settle(t, 600);
      final beta = outputs[2];
      remote([
        outputs[0],
        {
          ...beta,
          'children': [...(beta['children'] as List).reversed],
        },
        outputs[1],
      ]);
      await settle(t, 300);
      await _tapText(t, 'Delete');
      remote(outputs);
      await settle(t, 300);
      expect([for (final o in outputs) o['name']], ['text', 'beta', 'new']);
      expect([for (final c in outputs[1]['children'] as List) (c as Map)['name']], ['x']);
      // A long press on beta offers Add (its child) too; a tap opens beta's editor.
      await t.longPress(_rowOf(_more('beta')));
      await settle(t, 600);
      expect(_action('Add beta'), findsOneWidget);
      await _tapText(t, 'Edit');
      expect(find.byType(OutputEditCard), findsOneWidget);
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('$at question classifier classes: no hover drag handle; the class editor\'s "…" and a long press on '
        'its header offer Move up / Move down, which move the class by its id after another user\'s change', (
      t,
    ) async {
      _Json c(String id) => {'id': id, 'name': '', 'label': id.toUpperCase()};
      var classes = [c('a'), c('b'), c('c')];
      final update = await _pump(
        t,
        size,
        () => ClassList(
          list: classes,
          env: const PromptEditorEnv(),
          onChange: (next) => classes = next,
          onSort: (next) => classes = next,
          onRemove: (i) => classes = [...classes]..removeAt(i),
        ),
      );
      List<Object?> ids() => [for (final x in classes) x['id']];
      expect(find.byKey(const ValueKey('class-sort-handle-1')), findsNothing, reason: 'no hover drag handle');
      Finder more(String id) => find.descendant(
        of: find.byKey(ValueKey('class-item-$id')),
        matching: find.byKey(const Key('prompt-editor-more')),
      );
      expect(
        t.getSize(find.ancestor(of: more('b'), matching: find.byType(DifyTouchArea)).first).height,
        greaterThanOrEqualTo(44),
      );
      await t.ensureVisible(more('b'));
      await t.tap(more('b'));
      await settle(t, 600);
      expect(_action('Move up'), findsOneWidget);
      expect(_action('Move down'), findsOneWidget);
      // Another user adds "n" at the top.
      update(() => classes = [c('n'), ...classes]);
      await settle(t, 300);
      await _tapText(t, 'Move up');
      update(() {});
      await settle(t, 300);
      expect(ids(), ['n', 'b', 'a', 'c']);
      // A long press on c's header: Move up.
      await t.ensureVisible(find.text('C'));
      await t.longPress(find.text('C'));
      await settle(t, 600);
      await _tapText(t, 'Move up');
      update(() {});
      await settle(t, 300);
      expect(ids(), ['n', 'b', 'c', 'a']);
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('$at LLM messages: no hover drag handle; a message\'s "…" offers Move up / Move down (not the leading '
        'system prompt\'s) and Remove, each finding the message by its id after another user\'s change', (t) async {
      var prompts = const [
        PromptItem(id: 's', role: PromptRole.system, text: 'sys'),
        PromptItem(id: 'u1', role: PromptRole.user, text: 'one'),
        PromptItem(id: 'a1', role: PromptRole.assistant, text: 'two'),
        PromptItem(id: 'u2', role: PromptRole.user, text: 'three'),
      ];
      final update = await _pump(
        t,
        size,
        () => ConfigPrompt(
          payload: prompts,
          nodeId: 'n',
          isChatModel: true,
          onChange: (next) => prompts = (next as List).cast<PromptItem>(),
        ),
      );
      List<String?> ids() => [for (final p in prompts) p.id];
      expect(find.byKey(const ValueKey('sort-handle-1')), findsNothing, reason: 'no hover drag handle');
      Finder more(int i) => find.descendant(
        of: find.byType(DifyPromptEditorPanel).at(i),
        matching: find.byKey(const Key('prompt-editor-more')),
      );
      // The system prompt: no moves.
      await t.ensureVisible(more(0));
      await t.tap(more(0));
      await settle(t, 600);
      expect(_action('Move up'), findsNothing);
      expect(_action('Move down'), findsNothing);
      await t.tapAt(const Offset(10, 10));
      await settle(t, 600);
      // u2: Move up, after another user removed a1.
      await t.ensureVisible(more(3));
      expect(
        t.getSize(find.ancestor(of: more(3), matching: find.byType(DifyTouchArea)).first).height,
        greaterThanOrEqualTo(44),
      );
      await t.tap(more(3));
      await settle(t, 600);
      expect(_action('Move up'), findsOneWidget);
      update(() => prompts = [prompts[0], prompts[1], prompts[3]]);
      await settle(t, 300);
      await _tapText(t, 'Move up');
      update(() {});
      await settle(t, 300);
      expect(ids(), ['s', 'u2', 'u1']);
      // u1 (now last): a long press on its header; Remove, after another user inserted a message before it.
      await t.ensureVisible(more(2));
      await t.longPress(
        find.descendant(of: find.byType(DifyPromptEditorPanel).at(2), matching: find.byType(PromptRoleTitle)),
      );
      await settle(t, 600);
      expect(_action('Move down'), findsOneWidget, reason: 'a long press opens the same sheet');
      update(
        () => prompts = [prompts[0], prompts[1], const PromptItem(id: 'x', role: PromptRole.assistant), prompts[2]],
      );
      await settle(t, 300);
      await _tapText(t, 'Remove');
      update(() {});
      await settle(t, 300);
      expect(ids(), ['s', 'u2', 'x']);
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('$at IF/ELSE: cases and conditions are touch rows; no hover drag handle; a case\'s "…" offers Delete, '
        'Move up and Move down, a condition\'s Delete, each by id after another user\'s change', (t) async {
      _Json cond(String id, String v) => {
        'id': id,
        'variable_selector': ['n', v],
        'varType': 'string',
        'comparison_operator': 'contains',
        'value': '',
      };
      var cases = <_Json>[
        {
          'case_id': 'c1',
          'logical_operator': 'and',
          'conditions': [cond('k1', 'query')],
        },
        {'case_id': 'c2', 'logical_operator': 'and', 'conditions': <Object?>[]},
        {'case_id': 'c3', 'logical_operator': 'and', 'conditions': <Object?>[]},
      ];
      late StateSetter update;
      List<Object?> caseIds() => [for (final c in cases) c['case_id']];
      update = await _pump(
        t,
        size,
        () => IfElseConditionWrap(
          cases: cases,
          env: IfElseEnv(
            onRemoveCase: (id) => update(
              () => cases = [
                for (final c in cases)
                  if (c['case_id'] != id) c,
              ],
            ),
            onSortCase: (next) => update(() => cases = next),
            onRemoveCondition: (caseId, id) => update(
              () => cases = [
                for (final c in cases)
                  c['case_id'] != caseId
                      ? c
                      : {
                          ...c,
                          'conditions': [
                            for (final k in c['conditions'] as List)
                              if ((k as Map)['id'] != id) k,
                          ],
                        },
              ],
            ),
          ),
        ),
      );
      expect(
        find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'draggable'),
        findsNothing,
        reason: 'no hover drag handle',
      );
      for (final label in ['IF CASE1', 'ELIF CASE2', 'ELIF CASE3', 'query contains']) {
        _touchSizes(t, label);
      }
      // The condition's Delete, after another user added a condition before it.
      await t.tap(_more('query contains'));
      await settle(t, 600);
      update(
        () => cases = [
          {
            ...cases[0],
            'conditions': [cond('k0', 'other'), ...cases[0]['conditions'] as List],
          },
          ...cases.skip(1),
        ],
      );
      await settle(t, 300);
      await _tapText(t, 'Delete');
      expect([for (final k in cases[0]['conditions'] as List) (k as Map)['id']], ['k0']);
      // CASE3's Move up, after another user deleted CASE1.
      await t.tap(_more('ELIF CASE3'));
      await settle(t, 600);
      expect(_action('Delete'), findsOneWidget);
      expect(_action('Move down'), findsOneWidget);
      update(() => cases = cases.skip(1).toList());
      await settle(t, 300);
      await _tapText(t, 'Move up');
      expect(caseIds(), ['c3', 'c2']);
      // A long press on a case opens its actions too: Delete.
      await t.longPress(_rowOf(_more('ELIF CASE2')));
      await settle(t, 600);
      await _tapText(t, 'Delete');
      expect(caseIds(), ['c3']);
      expect(t.takeException(), isNull);
      await unmount(t);
    });
  }
}
