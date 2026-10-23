// dify-spec: web/app/components/workflow/nodes/tool/components/__tests__/tool-date-picker.spec.tsx
// dify-spec: web/app/components/workflow/nodes/tool/components/__tests__/tool-date-range-picker.spec.tsx
import 'dart:convert';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_date_pickers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// createReactI18nextMock with the spec's overrides; month and day names as in en-US; other keys `<ns>.<key>`.
class _Translator implements Translator {
  static const _overrides = {
    'time.dateFormats.display': 'MMMM D, YYYY',
    'time.operation.pickDate': 'Select date',
    'time.defaultPlaceholder': 'Select date',
    'common.operation.clear': 'Clear',
    'workflow.nodes.tool.dateRange.start': 'Start',
    'workflow.nodes.tool.dateRange.end': 'End',
    'workflow.nodes.tool.dateRange.startPlaceholder': 'Start date',
    'workflow.nodes.tool.dateRange.endPlaceholder': 'End date',
  };

  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) {
    final full = '$ns.$key';
    if (_overrides[full] case final v?) return v;
    if (ns == 'time' && (key.startsWith('months.') || key.startsWith('daysInWeek.'))) return key.split('.').last;
    return full;
  }
}

Future<void> render(WidgetTester t, Widget child) {
  DifyI18n.current = _Translator();
  return t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 360, child: child),
        ),
      ),
    ),
  );
}

Finder button(String label) =>
    find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == label, description: 'button "$label"');

/// The accessible name of the focused button.
String? focusedButton() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  return ctx?.findAncestorWidgetOfExactType<DifyPressable>()?.semanticLabel;
}

bool dialogOpen(WidgetTester t) => find.text('May 2024').evaluate().isNotEmpty;

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('ToolDatePicker', () {
    testWidgets('preserves a stored date-only value when rendering in a negative timezone', (t) async {
      await render(t, ToolDatePicker(value: '2024-05-01', onChange: (_) {}, placeholder: 'Select date'));
      expect(button('Select date: May 1, 2024'), findsOneWidget);
    });

    testWidgets('returns an empty string when clearing the date', (t) async {
      final changes = <String>[];
      await render(t, ToolDatePicker(value: '2024-05-01', onChange: changes.add, placeholder: 'Select date'));
      await t.tap(button('Clear'));
      await settle(t);
      expect(changes, ['']);
    });

    testWidgets('disables interaction and clearing when read only', (t) async {
      await render(
        t,
        ToolDatePicker(value: '2024-05-01', onChange: (_) {}, placeholder: 'Select date', readOnly: true),
      );
      expect(t.widget<DifyPressable>(button('Select date: May 1, 2024')).disabled, isTrue);
      expect(button('Clear'), findsNothing);
    });

    testWidgets('opens from the keyboard and restores focus to the date button on dismissal', (t) async {
      await render(t, ToolDatePicker(value: '2024-05-01', onChange: (_) {}));
      expect(
        find.descendant(of: button('Select date: May 1, 2024'), matching: find.byType(DifyPressable)),
        findsNothing,
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await settle(t);
      expect(focusedButton(), 'Select date: May 1, 2024');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(t);
      expect(dialogOpen(t), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);
      expect(dialogOpen(t), isFalse);
      expect(focusedButton(), 'Select date: May 1, 2024');
    });

    testWidgets('lets the keyboard reach and activate clear without opening the calendar', (t) async {
      final changes = <String>[];
      await render(t, ToolDatePicker(value: '2024-05-01', onChange: changes.add));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await settle(t);
      expect(focusedButton(), 'Clear');
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await settle(t);
      expect(changes, ['']);
      expect(dialogOpen(t), isFalse);
    });
  });

  group('ToolDateRangePicker', () {
    final range = jsonEncode({'start': '2024-05-01', 'end': '2024-05-03'});

    testWidgets('preserves stored date-only values when rendering in a negative timezone', (t) async {
      await render(t, ToolDateRangePicker(value: range, onChange: (_) {}));
      expect(button('Start date: May 1, 2024'), findsOneWidget);
      expect(button('End date: May 3, 2024'), findsOneWidget);
    });

    testWidgets('clears one boundary without changing the other', (t) async {
      final changes = <String>[];
      await render(t, ToolDateRangePicker(value: range, onChange: changes.add));
      await t.tap(button('Start date: Clear'));
      await settle(t);
      expect(changes, [
        jsonEncode({'end': '2024-05-03'}),
      ]);
    });

    testWidgets('keeps both clear actions separate from their date triggers in keyboard order', (t) async {
      await render(t, ToolDateRangePicker(value: range, onChange: (_) {}));
      for (final name in ['Start date: May 1, 2024', 'Start date: Clear', 'End date: May 3, 2024', 'End date: Clear']) {
        expect(find.descendant(of: button(name), matching: find.byType(DifyPressable)), findsNothing);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await settle(t);
        expect(focusedButton(), name);
      }
    });

    testWidgets('returns an empty value when clearing the last boundary', (t) async {
      final changes = <String>[];
      await render(t, ToolDateRangePicker(value: jsonEncode({'start': '2024-05-01'}), onChange: changes.add));
      await t.tap(button('Start date: Clear'));
      await settle(t);
      expect(changes, ['']);
    });
  });
}
