// dify-spec: web/app/components/base/prompt-editor/plugins/draggable-plugin/__tests__/index.spec.tsx
//
// DraggableBlockPlugin: a line holding a form field (the HITL block, Dify's `support-drag` node) shows a drag
// handle while hovered; dragging it moves the line, with a target line where it will go.
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/form_content.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

HitlInputBlockConfig _hitl() =>
    HitlInputBlockConfig(show: true, nodeId: 'node-1', onFormInputItemRemove: (_) {}, onFormInputItemRename: (_, _) {});

Finder _menu() => find.byKey(const Key('draggable-menu'));

Future<PromptEditorController> _render(WidgetTester t, String value) async {
  final c = PromptEditorController();
  addTearDown(c.dispose);
  await render(t, DifyPromptEditor(controller: c, value: value, hitlInputBlock: _hitl()));
  return c;
}

Future<TestGesture> _mouseAt(WidgetTester t, Offset at) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  await g.moveTo(at);
  await t.pump();
  return g;
}

/// A point on the editor's line [index] (24 px lines, the field's line taller), near its left edge.
Offset _onEditor(WidgetTester t, double dy) => t.getTopLeft(find.byType(DifyPromptEditor)) + Offset(4, dy);

void main() {
  group('DraggableBlockPlugin', () {
    group('Rendering', () {
      testWidgets('should use body as default anchor and render target line', (t) async {
        final c = await _render(t, 'a\n{{#\$output.user_name#}}\nb');
        final mouse = await _mouseAt(t, t.getCenter(find.byType(InputFieldChip)));
        expect(_menu(), findsOneWidget);
        expect(find.byKey(const Key('draggable-target-line')), findsNothing);
        final bottom = t.getBottomLeft(find.byType(DifyPromptEditor)).dy;
        await mouse.moveTo(t.getCenter(_menu()));
        await mouse.down(t.getCenter(_menu()));
        await t.pump();
        await mouse.moveTo(Offset(t.getCenter(_menu()).dx, bottom - 2));
        await t.pump();
        // The target line shows where the line goes: after "b".
        expect(find.byKey(const Key('draggable-target-line')), findsOneWidget);
        await mouse.up();
        await t.pump();
        expect(find.byKey(const Key('draggable-target-line')), findsNothing);
        expect(c.prompt, 'a\nb\n{{#\$output.user_name#}}');
      });
    });

    group('Drag support detection', () {
      testWidgets('should show menu when target has support-drag class', (t) async {
        await _render(t, 'a\n{{#\$output.user_name#}}');
        await _mouseAt(t, t.getCenter(find.byType(InputFieldChip)));
        expect(_menu(), findsOneWidget);
        expect(
          find.descendant(
            of: _menu(),
            matching: find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'draggable'),
          ),
          findsOneWidget,
        );
      });

      testWidgets('should show menu when target contains a support-drag descendant', (t) async {
        // The field sits in the same line (paragraph) as "abc": hovering the text shows the line's menu.
        await _render(t, 'abc{{#\$output.user_name#}}');
        await _mouseAt(t, _onEditor(t, 10));
        expect(_menu(), findsOneWidget);
      });

      testWidgets('should show menu when target is inside a support-drag ancestor', (t) async {
        await _render(t, '{{#\$output.user_name#}}');
        // The field's name tag, inside the field.
        await _mouseAt(t, t.getCenter(find.text('user_name')));
        expect(_menu(), findsOneWidget);
      });

      testWidgets('should hide menu when target does not support drag', (t) async {
        await _render(t, 'plain line\n{{#\$output.user_name#}}');
        final mouse = await _mouseAt(t, t.getCenter(find.byType(InputFieldChip)));
        expect(_menu(), findsOneWidget);
        await mouse.moveTo(_onEditor(t, 10));
        await t.pump();
        expect(_menu(), findsNothing);
      });
    });

    group('Forwarded callbacks', () {
      testWidgets('should forward isOnMenu and detect menu membership correctly', (t) async {
        await _render(t, 'a\n{{#\$output.user_name#}}');
        final mouse = await _mouseAt(t, t.getCenter(find.byType(InputFieldChip)));
        expect(_menu(), findsOneWidget);
        // On the menu itself, the menu stays.
        await mouse.moveTo(t.getCenter(_menu()));
        await t.pump();
        expect(_menu(), findsOneWidget);
      });
    });
  });
}
