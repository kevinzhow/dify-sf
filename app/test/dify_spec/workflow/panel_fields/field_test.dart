// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/field.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/collapse/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/layout/__tests__/field-title.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/layout/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/form-input-type-switch.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/toggle-expand-btn.spec.tsx
//
// Titles in `uppercase` utilities are upper-cased by the widgets, so they are looked up upper-cased.
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Matrix4 arrowTransform(WidgetTester t) => t.widget<Transform>(find.byKey(const Key('field-title-arrow'))).transform;

void main() {
  group('Field', () {
    testWidgets('should toggle folded children when supportFold is enabled', (t) async {
      await render(t, const Field(title: 'Foldable', supportFold: true, child: Text('folded content')));

      expect(find.text('folded content'), findsNothing);

      await t.tap(find.text('FOLDABLE'));
      await t.pump();
      expect(find.text('folded content'), findsOneWidget);

      await t.tap(find.text('FOLDABLE'));
      await t.pump();
      expect(find.text('folded content'), findsNothing);
    });
  });

  group('Collapse', () {
    group('Interaction', () {
      testWidgets('should expand collapsed content and notify onCollapse when clicked', (t) async {
        final calls = <bool>[];
        await render(t, PanelCollapse(title: 'Advanced', onCollapse: calls.add, child: const Text('Collapse content')));

        expect(find.text('Collapse content'), findsNothing);

        await t.tap(find.text('ADVANCED'));
        await t.pump();

        expect(find.text('Collapse content'), findsOneWidget);
        expect(calls, [false]);
      });

      testWidgets('should keep content collapsed when disabled', (t) async {
        final calls = <bool>[];
        await render(
          t,
          PanelCollapse(
            title: 'Disabled section',
            disabled: true,
            onCollapse: calls.add,
            child: const Text('Hidden content'),
          ),
        );

        await t.tap(find.text('DISABLED SECTION'));
        await t.pump();

        expect(find.text('Hidden content'), findsNothing);
        expect(calls, isEmpty);
      });

      testWidgets('should respect controlled collapse state and render actions separately', (t) async {
        final calls = <bool>[];
        await render(
          t,
          PanelCollapse(
            title: 'Controlled section',
            collapsed: false,
            actions: TextButton(onPressed: () {}, child: const Text('Operation')),
            onCollapse: calls.add,
            child: const Text('Visible content'),
          ),
        );

        expect(find.text('Visible content'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Operation'), findsOneWidget);

        await t.tap(find.text('CONTROLLED SECTION'));
        await t.pump();

        expect(calls, [true]);
        expect(find.text('Visible content'), findsOneWidget);
      });
    });
  });

  group('FieldTitle', () {
    testWidgets('should render title, subtitle, operation, tooltip and warning dot', (t) async {
      await render(
        t,
        FieldTitle(
          title: 'Embedding',
          subTitle: const Text('subtitle'),
          operation: TextButton(onPressed: () {}, child: const Text('action')),
          tooltip: 'Tooltip copy',
          warningDot: true,
        ),
      );

      expect(find.text('EMBEDDING'), findsOneWidget);
      expect(find.text('subtitle'), findsOneWidget);
      expect(find.bySemanticsLabel('Tooltip copy'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'action'), findsOneWidget);
      expect(find.byKey(const Key('warning-dot')), findsOneWidget);
    });

    testWidgets('should toggle local collapsed state and notify onCollapse when enabled', (t) async {
      final calls = <bool>[];
      await render(t, FieldTitle(title: 'Models', showArrow: true, onCollapse: calls.add));

      expect(arrowTransform(t), isNot(Matrix4.identity()));

      await t.tap(find.text('MODELS'));
      await t.pump();

      expect(calls, [false]);
      expect(arrowTransform(t), Matrix4.identity());
    });

    testWidgets('should respect controlled collapsed state and ignore clicks when disabled', (t) async {
      final calls = <bool>[];
      await render(
        t,
        FieldTitle(title: 'Controlled', showArrow: true, collapsed: false, disabled: true, onCollapse: calls.add),
      );

      await t.tap(find.text('CONTROLLED'));
      await t.pump();

      expect(calls, isEmpty);
      expect(arrowTransform(t), Matrix4.identity());
    });
  });

  group('layout index', () {
    group('Rendering', () {
      testWidgets('should render BoxGroup with nested children', (t) async {
        await render(t, const BoxGroup(child: Text('Inside box group')));

        expect(find.text('Inside box group'), findsOneWidget);
      });

      testWidgets('should render BoxGroupField from the barrel export', (t) async {
        await render(
          t,
          const BoxGroupField(
            field: LayoutField(title: 'Input', child: Text('Body content')),
          ),
        );

        expect(find.text('INPUT'), findsOneWidget);
        expect(find.text('Body content'), findsOneWidget);
      });

      testWidgets('should collapse and expand Field children when supportCollapse is enabled', (t) async {
        await render(t, const LayoutField(title: 'Advanced', supportCollapse: true, child: Text('Extra details')));

        expect(find.text('Extra details'), findsOneWidget);

        await t.tap(find.text('ADVANCED'));
        await t.pump();
        expect(find.text('Extra details'), findsNothing);

        await t.tap(find.text('ADVANCED'));
        await t.pump();
        expect(find.text('Extra details'), findsOneWidget);
      });
    });
  });

  group('FormInputTypeSwitch', () {
    testWidgets('changes the required input type selection', (t) async {
      final changes = <VarKindType>[];
      await render(t, FormInputTypeSwitch(value: VarKindType.variable, onChanged: changes.add));

      expect(
        t.getSemantics(find.bySemanticsLabel('workflow.nodes.common.typeSwitch.variable')),
        isSemantics(isChecked: true, isInMutuallyExclusiveGroup: true),
      );

      await t.tap(find.bySemanticsLabel('workflow.nodes.common.typeSwitch.input'));

      expect(changes, [VarKindType.constant]);
    });

    testWidgets('disables both input type options when read-only', (t) async {
      await render(t, FormInputTypeSwitch(value: VarKindType.constant, onChanged: (_) {}, readonly: true));

      for (final label in ['workflow.nodes.common.typeSwitch.variable', 'workflow.nodes.common.typeSwitch.input']) {
        expect(t.getSemantics(find.bySemanticsLabel(label)), isSemantics(hasEnabledState: true, isEnabled: false));
      }
    });
  });

  group('ToggleExpandBtn', () {
    testWidgets('exposes the localized next action and toggles expansion', (t) async {
      final changes = <bool>[];
      await render(t, ToggleExpandBtn(isExpand: false, onExpandChange: changes.add));

      await t.tap(find.bySemanticsLabel('share.chat.expand'));
      expect(changes, [true]);

      await render(t, ToggleExpandBtn(isExpand: true, onExpandChange: changes.add));
      await t.tap(find.bySemanticsLabel('share.chat.collapse'));
      expect(changes.last, isFalse);
    });
  });
}
