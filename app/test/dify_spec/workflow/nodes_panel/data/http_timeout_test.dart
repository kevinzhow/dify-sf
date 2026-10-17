// dify-spec: web/app/components/workflow/nodes/http/components/timeout/index.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/timeout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../dify_test_i18n.dart';

/// TimeoutHarness: the section over its own payload (expanded), reporting each change to [changes].
Future<void> render(WidgetTester t, List<Map<String, Object?>> changes, {bool readonly = false}) {
  useDifyTestTranslator();
  var payload = <String, Object?>{'connect': 5, 'read': 10, 'write': 15};
  return t.pumpWidget(
    MaterialApp(
      home: Material(
        child: StatefulBuilder(
          builder: (context, setState) => HttpTimeout(
            payload: payload,
            readonly: readonly,
            onChange: (next) {
              setState(() => payload = next);
              changes.add(next);
            },
          ),
        ),
      ),
    ),
  );
}

Future<void> expand(WidgetTester t) async {
  await t.tap(find.text('WORKFLOW.NODES.HTTP.TIMEOUT.TITLE'));
  await t.pumpAndSettle();
}

/// The input labelled [label] (`getByRole('textbox', { name })`).
Finder input(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label),
  matching: find.byType(TextField),
);

Future<void> blur(WidgetTester t) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await t.pumpAndSettle();
}

void main() {
  group('HTTP timeout fields', () {
    testWidgets('associates every timeout with its visible label and description', (t) async {
      await render(t, []);
      await expand(t);

      for (final k in ['connect', 'read', 'write']) {
        final label = 'workflow.nodes.http.timeout.${k}Label';
        final description = 'workflow.nodes.http.timeout.${k}Placeholder';
        final semantics = t.widget<Semantics>(
          find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label),
        );
        expect(semantics.properties.hint, description);
        expect(find.text(label), findsOneWidget);
        expect(input(label), findsOneWidget);
      }
    });

    testWidgets('stores integer values and maps an empty field to the backend default', (t) async {
      final changes = <Map<String, Object?>>[];
      await render(t, changes);
      await expand(t);
      final connect = input('workflow.nodes.http.timeout.connectLabel');

      await t.enterText(connect, '');
      await blur(t);

      expect(changes.last, {'connect': null, 'read': 10, 'write': 15});

      await t.enterText(connect, '8.9');
      await blur(t);

      expect(changes.last, {'connect': 9, 'read': 10, 'write': 15});
    });

    testWidgets('does not update read-only timeout fields', (t) async {
      final changes = <Map<String, Object?>>[];
      await render(t, changes, readonly: true);
      await expand(t);
      final connect = input('workflow.nodes.http.timeout.connectLabel');

      expect(t.widget<TextField>(connect).readOnly, isTrue);

      await t.tap(connect);
      await blur(t);

      expect(changes, isEmpty);
    });
  });
}
