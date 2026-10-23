// dify-spec: web/app/components/base/search-input/__tests__/index.spec.tsx
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

/// The search box's semantics node (a text field named [label]).
SemanticsNode _box(WidgetTester t, [String label = 'common.operation.search']) => t.getSemantics(
  find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label).first,
);

EditableText _editable(WidgetTester t) => t.widget<EditableText>(find.byType(EditableText));

class _Controlled extends StatefulWidget {
  const _Controlled({required this.initial});
  final String initial;
  @override
  State<_Controlled> createState() => _ControlledState();
}

class _ControlledState extends State<_Controlled> {
  late String value = widget.initial;
  @override
  Widget build(BuildContext context) => DifySearchInput(
    value: value,
    onValueChange: (v) => setState(() => value = v),
  );
}

Future<void> _render(WidgetTester t, Widget w) => renderMembers(t, Center(child: SizedBox(width: 240, child: w)));

void main() {
  group('SearchInput', () {
    group('Render', () {
      testWidgets('renders correctly with default props', (t) async {
        await _render(t, DifySearchInput(value: '', onValueChange: (_) {}));
        final node = _box(t);
        expect(node.label, 'common.operation.search');
        expect(_editable(t).controller.text, '');
        expect(find.text('common.operation.search'), findsOneWidget, reason: 'the placeholder');
      });

      testWidgets('renders custom placeholder', (t) async {
        await _render(t, DifySearchInput(value: '', onValueChange: (_) {}, placeholder: 'Custom Placeholder'));
        expect(find.text('Custom Placeholder'), findsOneWidget);
        expect(_box(t).label, 'common.operation.search');
      });

      testWidgets('uses custom aria label', (t) async {
        await _render(t, DifySearchInput(value: '', onValueChange: (_) {}, semanticLabel: 'Search providers'));
        expect(_box(t, 'Search providers').label, 'Search providers');
      });

      testWidgets('exposes the input element through its ref', (t) async {
        final node = FocusNode();
        addTearDown(node.dispose);
        await _render(t, DifySearchInput(value: '', onValueChange: (_) {}, focusNode: node));
        expect(_editable(t).focusNode, same(node));
      });

      testWidgets('focuses the searchbox when autoFocus is enabled', (t) async {
        await _render(t, DifySearchInput(value: '', onValueChange: (_) {}, autofocus: true));
        expect(_editable(t).focusNode.hasFocus, isTrue);
      });

      testWidgets('shows clear button when value is present', (t) async {
        await _render(t, DifySearchInput(value: 'has value', onValueChange: (_) {}));
        expect(button('common.operation.clear'), findsOneWidget);
      });

      testWidgets('keeps a disabled searchbox inert and exposes its description', (t) async {
        await _render(
          t,
          DifySearchInput(value: 'has value', onValueChange: (_) {}, disabled: true, description: 'Search unavailable'),
        );
        expect(_editable(t).readOnly || !(_editable(t).focusNode.canRequestFocus), isTrue);
        final hinted = find.byWidgetPredicate((w) => w is Semantics && w.properties.hint == 'Search unavailable');
        expect(hinted, findsOneWidget);
        expect(button('common.operation.clear'), findsNothing);
        final node = _box(t);
        expect(node.getSemanticsData().flagsCollection.isEnabled, isNot(Tristate.isTrue));
      });
    });

    group('Interaction', () {
      testWidgets('calls onValueChange when typing', (t) async {
        final calls = <String>[];
        await _render(t, DifySearchInput(value: '', onValueChange: calls.add));
        await t.enterText(find.byType(EditableText), 'test');
        expect(calls, ['test']);
      });

      testWidgets('clears the value and returns focus to the searchbox', (t) async {
        await _render(t, const _Controlled(initial: 'has value'));
        await t.tap(find.byKey(const ValueKey('search-input-clear')));
        await t.pump();
        expect(_editable(t).controller.text, '');
        expect(_editable(t).focusNode.hasFocus, isTrue);
      });
    });
  });
}
