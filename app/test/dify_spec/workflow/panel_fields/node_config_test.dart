// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/memory-config.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/retry/__tests__/retry-on-panel.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/error-handle/__tests__/index.spec.tsx
//
// The panels take the node's data and report changes through callbacks (Dify's hooks are what the tests mock), so
// the cases check the callbacks; the collapsed state the hook reports is reached by collapsing the section.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/node_extras.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// MemorySettings: a MemoryConfig keeping its own memory.
class MemorySettings extends StatefulWidget {
  const MemorySettings({super.key, this.readonly = false, this.onChange});
  final bool readonly;
  final ValueChanged<Json?>? onChange;

  @override
  State<MemorySettings> createState() => _MemorySettingsState();
}

class _MemorySettingsState extends State<MemorySettings> {
  Json? _memory = const {
    'window': {'enabled': true, 'size': 50},
    'query_prompt_template': '{{#sys.query#}}',
    'role_prefix': {'user': 'Human', 'assistant': 'Assistant'},
  };

  @override
  Widget build(BuildContext context) => MemoryConfig(
    memory: _memory,
    readonly: widget.readonly,
    canSetRoleName: true,
    onChange: (v) {
      setState(() => _memory = v);
      widget.onChange?.call(v);
    },
  );
}

Finder numberInput([int index = 0]) =>
    find.descendant(of: find.byType(DifyNumberField).at(index), matching: find.byType(TextField));

Finder labelled(String label) => find.descendant(of: find.bySemanticsLabel(label), matching: find.byType(TextField));

String textOf(WidgetTester t, Finder f) => t.widget<TextField>(f).controller!.text;

Future<void> tab(WidgetTester t) async {
  await t.sendKeyEvent(LogicalKeyboardKey.tab);
  await t.pump();
}

/// The card footer, on a screen wide enough for the test translator's long keys.
Future<void> renderCard(WidgetTester t, Node n) async {
  t.view.physicalSize = const Size(2400, 600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await render(t, Builder(builder: (_) => NodeExtras.build(n)), width: 2200);
}

void main() {
  group('memory settings', () {
    testWidgets('keeps a valid window while clearing, and synchronizes integer edits with the slider', (t) async {
      final changes = <Json?>[];
      await render(t, MemorySettings(onChange: changes.add), width: 600);
      final input = numberInput();

      await t.tap(input);
      await t.enterText(input, '');
      expect(changes, isEmpty);
      await tab(t);
      expect(textOf(t, input), '50');

      await t.tap(input);
      await t.enterText(input, '8.9');
      await tab(t);
      expect(textOf(t, input), '9');
      expect(t.getSemantics(find.byType(DifySlider)).value, '9');
      expect(changes.last!['window'], {'enabled': true, 'size': 9});

      final slider = t.getTopLeft(find.byType(DifySlider));
      await t.tapAt(slider + Offset(144 * 8 / 99, 10));
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(textOf(t, input), '10');
    });

    testWidgets('clamps the window to its business limit without changing the role prefixes', (t) async {
      final changes = <Json?>[];
      await render(t, MemorySettings(onChange: changes.add), width: 600);
      final input = numberInput();

      await t.tap(input);
      await t.enterText(input, '999');
      await tab(t);

      expect(textOf(t, input), '100');
      expect(changes.last!['window'], {'enabled': true, 'size': 100});
      expect(changes.last!['role_prefix'], {'user': 'Human', 'assistant': 'Assistant'});
    });

    testWidgets('connects role labels to editable inputs and preserves readonly settings', (t) async {
      await render(t, const MemorySettings(), width: 600);
      final input = labelled('workflow.nodes.common.memory.user');

      await t.tap(find.text('workflow.nodes.common.memory.user'));
      await t.pump();
      expect(t.widget<TextField>(input).focusNode!.hasFocus, isTrue);
      await t.enterText(input, 'User');
      await t.pump();
      expect(textOf(t, input), 'User');

      await render(t, const MemorySettings(readonly: true), width: 600);
      await t.enterText(input, 'User changed');
      await t.pump();
      expect(textOf(t, input), 'User');
      expect(t.widget<TextField>(numberInput()).enabled, isFalse);
    });
  });

  group('RetryOnPanel', () {
    const data = {'retry_enabled': true, 'max_retries': 3, 'retry_interval': 1000};

    testWidgets('should label the retry switch and grouped value controls', (t) async {
      await render(t, RetryOnPanel(retryConfig: data, onChange: (_) {}), width: 420);

      expect(
        t.getSemantics(find.bySemanticsLabel('workflow.nodes.common.retry.retryOnFailure')),
        isSemantics(isToggled: true),
      );

      final sliders = find.byType(DifySlider);
      expect(t.getSemantics(sliders.at(0)).label, 'workflow.nodes.common.retry.maxRetries');
      expect(t.getSemantics(sliders.at(0)).value, '3 workflow.nodes.common.retry.times');
      expect(textOf(t, numberInput(0)), '3');
      expect(find.text('workflow.nodes.common.retry.times'), findsOneWidget);

      expect(t.getSemantics(sliders.at(1)).label, 'workflow.nodes.common.retry.retryInterval');
      expect(t.getSemantics(sliders.at(1)).value, '1000 workflow.nodes.common.retry.ms');
      expect(textOf(t, numberInput(1)), '1000');
      expect(find.text('workflow.nodes.common.retry.ms'), findsOneWidget);
    });

    testWidgets('should update retry configuration through native control interactions', (t) async {
      final changes = <Json>[];
      await render(t, RetryOnPanel(retryConfig: data, onChange: changes.add), width: 420);

      await t.tap(find.bySemanticsLabel('workflow.nodes.common.retry.retryOnFailure'));
      expect(changes.last, {'retry_enabled': false, 'max_retries': 3, 'retry_interval': 1000});

      await t.tap(numberInput(0));
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(changes.last, {'retry_enabled': true, 'max_retries': 4, 'retry_interval': 1000});
    });
  });

  group('error-handle path', () {
    group('Leaf Components', () {
      testWidgets('should render the fail-branch card with the resolved learn-more link', (t) async {
        final links = <String>[];
        await render(t, FailBranchCard(onOpenLink: links.add));

        expect(find.text('workflow.nodes.common.errorHandle.failBranch.customize'), findsOneWidget);
        await t.tap(find.text('workflow.common.learnMore'));
        expect(links.single, endsWith('/use-dify/debug/error-type'));
      });

      testWidgets('should edit a labeled string default and preserve the array editor', (t) async {
        final forms = <Json>[];
        await render(
          t,
          DefaultValue(
            forms: const [
              {'key': 'message', 'type': 'string', 'value': 'hello'},
              {'key': 'items', 'type': 'array[string]', 'value': '["a"]'},
            ],
            onFormChange: forms.add,
          ),
        );

        final input = labelled('message');
        await t.tap(find.text('message'));
        await t.pump();
        expect(t.widget<TextField>(input).focusNode!.hasFocus, isTrue);
        await t.enterText(input, 'hello!');

        expect(forms.last, {'key': 'message', 'type': 'string', 'value': 'hello!'});
        expect(find.text('items'), findsOneWidget);
      });

      testWidgets('should report a numeric default as a string to the workflow owner', (t) async {
        final forms = <Json>[];
        await render(
          t,
          DefaultValue(
            forms: const [
              {'key': 'count', 'type': 'number', 'value': 12},
            ],
            onFormChange: forms.add,
          ),
        );

        await t.enterText(labelled('count'), '123');

        expect(forms.last, {'key': 'count', 'type': 'number', 'value': '123'});
      });

      testWidgets('should toggle the selector popup and report the selected strategy', (t) async {
        final selected = <ErrorHandleType>[];
        await render(
          t,
          Align(
            alignment: Alignment.topRight,
            child: ErrorHandleTypeSelector(value: ErrorHandleType.none, onSelected: selected.add),
          ),
        );

        await t.tap(find.text('workflow.nodes.common.errorHandle.none.title'));
        await t.pumpAndSettle();
        await t.tap(find.text('workflow.nodes.common.errorHandle.defaultValue.title'));

        expect(selected.first, ErrorHandleType.defaultValue);
      });

      testWidgets('should render the error tip only when a strategy exists', (t) async {
        await render(t, const ErrorHandleTip());
        expect(find.byType(Text), findsNothing);

        await render(t, const ErrorHandleTip(type: ErrorHandleType.failBranch));
        expect(find.text('workflow.nodes.common.errorHandle.failBranch.inLog'), findsOneWidget);

        await render(t, const ErrorHandleTip(type: ErrorHandleType.defaultValue));
        expect(find.text('workflow.nodes.common.errorHandle.defaultValue.inLog'), findsOneWidget);
      });
    });

    group('Containers', () {
      Widget panel({
        String? strategy,
        List<Json>? defaults,
        ValueChanged<Json>? onForm,
      }) => ErrorHandleOnPanel(
        errorStrategy: strategy,
        defaultValue: defaults,
        onStrategyChange: (_) {},
        onDefaultValueChange: onForm ?? (_) {},
        onOpenLink: (_) {},
      );

      testWidgets('should render the fail-branch panel body when the strategy is active', (t) async {
        await render(t, panel(strategy: 'fail-branch'));

        expect(find.text('workflow.nodes.common.errorHandle.title'.toUpperCase()), findsOneWidget);
        expect(find.text('workflow.nodes.common.errorHandle.failBranch.customize'), findsOneWidget);
      });

      testWidgets('should render the default-value panel body and delegate form updates', (t) async {
        final forms = <Json>[];
        await render(
          t,
          panel(
            strategy: 'default-value',
            defaults: const [
              {'key': 'answer', 'type': 'string', 'value': 'draft'},
            ],
            onForm: forms.add,
          ),
        );

        await t.enterText(find.widgetWithText(TextField, 'draft'), 'next');

        expect(forms.single, {'key': 'answer', 'type': 'string', 'value': 'next'});
      });

      // ErrorHandleOnNode is the card's footer (cards/node_extras.dart); the fail branch's handle is drawn by the
      // canvas on the row NodeExtras.failBranchY gives.
      testWidgets('should render the default-value node badge', (t) async {
        const n = Node(id: 'node-1', type: 'code', config: {'error_strategy': VString('default-value')});
        await renderCard(t, n);

        expect(find.text('workflow.nodes.common.errorHandle.defaultValue.output'), findsOneWidget);
      });

      testWidgets('should render the fail-branch node badge when the node throws an exception', (t) async {
        const n = Node(id: 'node-1', type: 'code', config: {'error_strategy': VString('fail-branch')});
        await renderCard(t, n);

        expect(find.text('workflow.common.onFailure'.toUpperCase()), findsOneWidget);
        expect(find.text('workflow.nodes.common.errorHandle.failBranch.title'), findsOneWidget);
        expect(NodeExtras.failBranchY(n), isNotNull);
      });

      testWidgets('should hide the panel body when the hook reports a collapsed section', (t) async {
        await render(t, panel(strategy: 'fail-branch'));

        await t.tap(find.text('workflow.nodes.common.errorHandle.title'.toUpperCase()));
        await t.pump();

        expect(find.text('workflow.nodes.common.errorHandle.failBranch.customize'), findsNothing);
      });
    });
  });

  group('error handling data', () {
    test('choosing a strategy sets the data Dify sets', () {
      expect(errorStrategyChange('fail-branch', ErrorHandleType.failBranch, 'llm'), isNull);
      expect(errorStrategyChange(null, ErrorHandleType.defaultValue, 'llm')!.changes['default_value'], [
        {'key': 'text', 'type': 'string', 'value': ''},
      ]);
      expect(errorStrategyChange('default-value', ErrorHandleType.none, 'llm')!.deleteFailBranch, isTrue);
      expect(errorDefaultValues('code', codeOutputs: const {'a': 'array[number]'}), [
        {'key': 'a', 'type': 'array[number]', 'value': '[]'},
      ]);
      expect(
        defaultValueFormChange(
          const [
            {'key': 'text', 'type': 'string', 'value': ''},
          ],
          const {'key': 'text', 'type': 'string', 'value': 'x'},
        ),
        [
          {'key': 'text', 'type': 'string', 'value': 'x'},
        ],
      );
    });
  });
}
