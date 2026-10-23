// dify-spec: web/app/components/workflow/nodes/trigger-webhook/components/__tests__/generic-table.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_tables.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const columns = [
  TableColumn(key: 'name', title: 'Name', type: ColumnType.input, placeholder: 'Name', width: 140),
  TableColumn(key: 'enabled', title: 'Enabled', type: ColumnType.toggle, width: 80),
];

final advancedColumns = [
  const TableColumn(
    key: 'method',
    title: 'Method',
    type: ColumnType.select,
    placeholder: 'Choose method',
    options: [(name: 'POST', value: 'post')],
    width: 120,
  ),
  TableColumn(
    key: 'preview',
    title: 'Preview',
    type: ColumnType.custom,
    width: 120,
    render: (value, row, index, onChange) => TextButton(
      onPressed: () => onChange('$index:${(row['method'] as String?)?.isNotEmpty == true ? row['method'] : 'empty'}'),
      child: const Text('custom-render'),
    ),
  ),
  const TableColumn(key: 'unsupported', title: 'Unsupported', type: ColumnType.unsupported, width: 80),
];

void main() {
  group('GenericTable', () {
    testWidgets('should render an empty editable row and append a configured row when typing into the virtual row', (
      t,
    ) async {
      final calls = <List<Json>>[];
      await t.pumpWidget(
        wrap(
          GenericTable(
            title: 'Headers',
            columns: columns,
            data: const [],
            emptyRowData: const {'name': '', 'enabled': false},
            onChange: calls.add,
          ),
        ),
      );

      await t.enterText(textboxes(), 'my key');

      expect(calls.last, [
        {'name': 'my_key', 'enabled': false},
      ]);
    });

    testWidgets('should skip intermediate empty rows and blur-sm the current input when enter is pressed', (t) async {
      await t.pumpWidget(
        wrap(
          GenericTable(
            title: 'Headers',
            columns: columns,
            data: const [
              {'name': 'alpha', 'enabled': false},
              {'name': '', 'enabled': false},
              {'name': 'beta', 'enabled': true},
            ],
            emptyRowData: const {'name': '', 'enabled': false},
            onChange: (_) {},
          ),
        ),
      );

      expect(textboxes(), findsNWidgets(3));
      expect(buttonNamed('Delete row'), findsNWidgets(2));

      await t.tap(textboxes().first);
      await t.pump();
      final focus = t.widget<TextField>(textboxes().first).focusNode!;
      expect(focus.hasFocus, isTrue);
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(focus.hasFocus, isFalse);
    });

    testWidgets('should update existing rows, show delete action, and remove rows by primary key', (t) async {
      final calls = <List<Json>>[];
      await t.pumpWidget(
        wrap(
          GenericTable(
            title: 'Headers',
            columns: columns,
            data: const [
              {'name': 'alpha', 'enabled': false},
            ],
            emptyRowData: const {'name': '', 'enabled': false},
            onChange: calls.add,
            showHeader: true,
          ),
        ),
      );

      expect(find.text('NAME'), findsOneWidget);

      await t.tap(checkboxes().first);
      expect(calls, [
        [
          {'name': 'alpha', 'enabled': true},
        ],
      ]);

      await t.tap(buttonNamed('Delete row'));
      expect(calls.last, isEmpty);
    });

    testWidgets('should update select and custom cells for existing rows', (t) async {
      final calls = <List<Json>>[];
      var data = <Json>[
        {'method': '', 'preview': ''},
      ];
      await t.pumpWidget(
        wrap(
          StatefulBuilder(
            builder: (context, setState) => GenericTable(
              title: 'Advanced',
              columns: advancedColumns,
              data: data,
              emptyRowData: const {'method': '', 'preview': ''},
              onChange: (next) {
                calls.add(next);
                setState(() => data = next);
              },
            ),
          ),
        ),
      );

      expect(find.text('Choose method'), findsOneWidget);
      await t.tap(find.text('Choose method'));
      await settle(t);
      await t.tap(find.text('POST'));
      await settle(t);

      expect(calls, [
        [
          {'method': 'post', 'preview': ''},
        ],
      ]);
      expect(find.text('POST'), findsOneWidget);

      calls.clear();
      await t.tap(find.text('custom-render').first);
      expect(calls, [
        [
          {'method': 'post', 'preview': '0:post'},
        ],
      ]);
    });

    testWidgets('should ignore custom-cell updates when readonly rows are rendered', (t) async {
      final calls = <List<Json>>[];
      await t.pumpWidget(
        wrap(
          GenericTable(
            title: 'Advanced',
            columns: advancedColumns,
            data: const [
              {'method': 'post', 'preview': ''},
            ],
            emptyRowData: const {'method': '', 'preview': ''},
            onChange: calls.add,
            readonly: true,
          ),
        ),
      );

      await t.tap(find.text('custom-render'));

      expect(calls, isEmpty);
    });

    testWidgets('should show readonly placeholder without rendering editable rows', (t) async {
      await t.pumpWidget(
        wrap(
          GenericTable(
            title: 'Headers',
            columns: columns,
            data: const [],
            emptyRowData: const {'name': '', 'enabled': false},
            onChange: (_) {},
            readonly: true,
            placeholder: 'No data',
          ),
        ),
      );

      expect(find.text('No data'), findsOneWidget);
      expect(textboxes(), findsNothing);
    });
  });
}
