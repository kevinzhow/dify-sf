// dify-spec: web/app/components/workflow/__tests__/dsl-export-confirm-modal.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/workflow_editor/dsl/dsl_export_confirm_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/form_controls.dart' show DifyCheckbox;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_test_i18n.dart';

const _envList = [
  {
    'id': 'env-1',
    'name': 'SECRET_TOKEN',
    'value': 'masked-value',
    'value_type': 'secret',
    'description': 'secret token',
  },
];

const _multiEnvList = [
  ..._envList,
  {
    'id': 'env-2',
    'name': 'SERVICE_KEY',
    'value': 'another-secret',
    'value_type': 'secret',
    'description': 'service key',
  },
];

class _Calls {
  final confirmed = <bool>[];
  var closed = 0;
  Completer<void>? pending;
}

Future<_Calls> _open(WidgetTester t, {List<Map<String, Object?>> envList = _envList, bool hold = false}) async {
  useDifyTestTranslator();
  t.view.physicalSize = const Size(1400, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final calls = _Calls();
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              await showDslExportConfirm(
                context,
                envList: envList,
                onConfirm: (v) {
                  calls.confirmed.add(v);
                  if (!hold) return Future.value();
                  calls.pending = Completer<void>();
                  return calls.pending!.future;
                },
              );
              calls.closed++;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return calls;
}

Finder _button(String label) =>
    find.widgetWithText(InkWell, label).evaluate().isNotEmpty ? find.widgetWithText(InkWell, label) : find.text(label);

void main() {
  group('DSLExportConfirmModal', () {
    testWidgets('should render environment rows and close when cancel is clicked', (t) async {
      final calls = await _open(t);
      expect(find.text('SECRET_TOKEN'), findsOneWidget);
      expect(find.text('masked-value'), findsOneWidget);
      await t.tap(_button('common.operation.cancel'));
      await t.pumpAndSettle();
      expect(calls.closed, 1);
      expect(calls.confirmed, isEmpty);
    });

    testWidgets('should confirm with exportSecrets=false by default', (t) async {
      final calls = await _open(t);
      await t.tap(_button('workflow.env.export.ignore'));
      await t.pumpAndSettle();
      expect(calls.confirmed, [false]);
      expect(calls.closed, 1);
    });

    testWidgets('should confirm with exportSecrets=true after toggling the checkbox', (t) async {
      final calls = await _open(t);
      await t.tap(find.byType(DifyCheckbox));
      await t.pump();
      await t.tap(_button('workflow.env.export.export'));
      await t.pumpAndSettle();
      expect(calls.confirmed, [true]);
      expect(calls.closed, 1);
    });

    testWidgets('should also toggle exportSecrets when the label text is clicked', (t) async {
      final calls = await _open(t);
      await t.tap(find.text('workflow.env.export.checkbox'));
      await t.pump();
      await t.tap(_button('workflow.env.export.export'));
      await t.pumpAndSettle();
      expect(calls.confirmed, [true]);
      expect(calls.closed, 1);
    });

    testWidgets('should show exporting state and prevent duplicate submits while exporting', (t) async {
      final calls = await _open(t, hold: true);
      await t.tap(_button('workflow.env.export.ignore'));
      await t.pump();
      expect(find.text('common.operation.exporting'), findsOneWidget);
      // Cancel is disabled and a second click does not export again.
      await t.tap(_button('common.operation.cancel'), warnIfMissed: false);
      await t.tap(find.text('common.operation.exporting'), warnIfMissed: false);
      await t.pump();
      expect(calls.confirmed, hasLength(1));
      expect(calls.closed, 0);
      calls.pending!.complete();
      await t.pumpAndSettle();
      expect(calls.closed, 1);
    });

    testWidgets('should render border separators for all rows except the last one', (t) async {
      await _open(t, envList: _multiEnvList);
      BorderSide bottomOf(String text) {
        final cell = find.ancestor(of: find.text(text), matching: find.byType(Container)).first;
        return ((t.widget<Container>(cell).decoration! as BoxDecoration).border! as Border).bottom;
      }

      expect(bottomOf('SECRET_TOKEN'), isNot(BorderSide.none));
      expect(bottomOf('masked-value'), isNot(BorderSide.none));
      expect(bottomOf('SERVICE_KEY'), BorderSide.none);
      expect(bottomOf('another-secret'), BorderSide.none);
    });
  });

  group('exportCheck (use-DSL.ts)', () {
    Future<List<bool>> run(WidgetTester t, List<Map<String, Object?>> env) async {
      useDifyTestTranslator();
      t.view.physicalSize = const Size(1400, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final exported = <bool>[];
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => exportDslWithCheck(
                context,
                environmentVariables: env,
                export: (v) async => exported.add(v),
              ),
              child: const Text('export'),
            ),
          ),
        ),
      );
      await t.tap(find.text('export'));
      await t.pumpAndSettle();
      return exported;
    }

    testWidgets('exports without secrets at once when the environment has none', (t) async {
      final exported = await run(t, [
        {'name': 'PLAIN', 'value': 'v', 'value_type': 'string'},
      ]);
      expect(exported, [false]);
      expect(find.byType(DslExportConfirmContent), findsNothing);
    });

    testWidgets('asks first when the environment holds secrets, listing only them', (t) async {
      final exported = await run(t, [
        {'name': 'PLAIN', 'value': 'v', 'value_type': 'string'},
        ..._envList,
      ]);
      expect(exported, isEmpty);
      expect(find.text('SECRET_TOKEN'), findsOneWidget);
      expect(find.text('PLAIN'), findsNothing);
      await t.tap(find.text('workflow.env.export.ignore'));
      await t.pumpAndSettle();
      expect(exported, [false]);
    });
  });
}
