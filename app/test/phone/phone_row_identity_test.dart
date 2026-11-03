// Row actions find their row by its identity when they run (PR #90 review, Winnie): a phone's "…" sheet (Edit, Delete,
// Move up / down) or an edit form may be open while a collaborator changes the list. The action applies to the row it
// was opened on (by its name, id or key), wherever that row is now, or does nothing once it is gone; it writes only
// its own change on the latest list (rows added or changed meanwhile survive). At 411x914.
//
// The first seven cases are Winnie's review tests (pr90_row_identity_review2_test.dart: 4, review7: 1, review8: 2),
// adapted to this suite's harness; her review17, review25 and review32 are in the groups below.

import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/start_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_tables.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/pe_params.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

typedef _Json = Map<String, Object?>;

_Json _item(String id, {String? label}) => {
  'variable': id,
  'label': label ?? id,
  'type': 'text-input',
  'required': false,
};

/// A Start input list on a phone page whose list another client can change ([update]).
class _StartHost {
  _StartHost(this.items);
  List<_Json> items;
  late StateSetter update;

  List<Object?> get names => [for (final v in items) v['variable']];

  Future<void> pump(WidgetTester t) async {
    phoneWindow(t);
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: DifyPage(
          edgeToEdge: true,
          body: StatefulBuilder(
            builder: (context, set) {
              update = set;
              return Padding(
                padding: const EdgeInsets.only(top: 80),
                child: StartVarList(
                  readonly: false,
                  list: items,
                  onChange: (next, [more]) => update(() => items = next.cast<_Json>()),
                ),
              );
            },
          ),
        ),
      ),
    );
    await settle(t, 400);
  }

  /// Another client's change: the page rebuilds with [next].
  Future<void> remote(WidgetTester t, List<_Json> next) async {
    update(() => items = next);
    await settle(t, 300);
  }
}

Finder _more(String rowName) => find.byKey(ValueKey('dify-action-row-more-$rowName'));

Future<void> _openMenu(WidgetTester t, String rowName) async {
  await t.tap(_more(rowName));
  await settle(t, 600);
}

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });

  group("Winnie's review cases", () {
    for (final change in ['none', 'reorder', 'remove']) {
      testWidgets('Delete from an open alpha menu keeps the selected identity after $change', (t) async {
        final h = _StartHost([_item('alpha'), _item('beta')]);
        await h.pump(t);
        await _openMenu(t, 'alpha, alpha, Short Text');
        expect(find.text('Delete'), findsOneWidget);
        if (change == 'reorder') await h.remote(t, [h.items[1], h.items[0]]);
        if (change == 'remove') await h.remote(t, [h.items[1]]);
        await t.tap(find.text('Delete'));
        await settle(t, 700);
        expect(h.names, ['beta'], reason: 'menu targeted alpha; a current row at its old index must not be deleted');
        expect(t.takeException(), isNull);
        await unmount(t);
      });
    }

    testWidgets('Move down from an open alpha menu targets alpha after another row is inserted before it', (t) async {
      final h = _StartHost([_item('alpha'), _item('beta')]);
      await h.pump(t);
      await _openMenu(t, 'alpha, alpha, Short Text');
      await h.remote(t, [_item('new'), ...h.items]);
      await t.tap(find.text('Move down'));
      await settle(t, 700);
      expect(h.names, ['new', 'beta', 'alpha'], reason: 'the selected alpha moves down from its CURRENT position');
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('Edit safely does nothing after the selected row disappeared while its menu was open', (t) async {
      final h = _StartHost([_item('alpha'), _item('beta')]);
      try {
        await h.pump(t);
        await _openMenu(t, 'alpha, alpha, Short Text');
        await h.remote(t, [h.items[1]]);
        await t.tap(find.text('Edit'));
        await settle(t, 700);
        expect(
          t.takeException(),
          isNull,
          reason: 'an action for a deleted row must not use its disposed State/context',
        );
        expect(find.byKey(const Key('config-var-modal')), findsNothing);
        expect(h.names, ['beta']);
      } finally {
        await unmount(t);
      }
    });

    for (final updateKind in ['insert', 'edit']) {
      testWidgets('Webhook row deletion preserves the latest table after an external $updateKind', (t) async {
        phoneWindow(t);
        var rows = <_Json>[
          {'key': 'alpha', 'value': '1'},
          {'key': 'beta', 'value': 'old'},
        ];
        late StateSetter update;
        try {
          await t.pumpWidget(
            DifyApplication(
              theme: difyTheme(),
              home: DifyPage(
                edgeToEdge: true,
                body: StatefulBuilder(
                  builder: (context, set) {
                    update = set;
                    return Padding(
                      padding: const EdgeInsets.only(top: 80),
                      child: GenericTable(
                        title: 'Headers',
                        columns: const [
                          TableColumn(key: 'key', title: 'Key', type: ColumnType.input),
                          TableColumn(key: 'value', title: 'Value', type: ColumnType.input),
                        ],
                        data: rows,
                        onChange: (next) => update(() => rows = next),
                        emptyRowData: const {'key': '', 'value': ''},
                      ),
                    );
                  },
                ),
              ),
            ),
          );
          await settle(t, 400);
          await _openMenu(t, 'alpha');
          if (updateKind == 'insert') {
            update(
              () => rows = [
                {'key': 'new', 'value': 'added'},
                ...rows,
              ],
            );
          } else {
            update(
              () => rows = [
                rows[0],
                {'key': 'beta', 'value': 'updated'},
              ],
            );
          }
          await settle(t, 300);
          await t.tap(find.text('Delete'));
          await settle(t, 700);
          if (updateKind == 'insert') {
            expect(rows, [
              {'key': 'new', 'value': 'added'},
              {'key': 'beta', 'value': 'old'},
            ], reason: 'deleting alpha must preserve the new row');
          } else {
            expect(rows, [
              {'key': 'beta', 'value': 'updated'},
            ], reason: 'deleting alpha must preserve the latest value of beta');
          }
          expect(t.takeException(), isNull);
        } finally {
          await unmount(t);
        }
      });
    }
  });

  group('Start inputs: Edit and the latest list', () {
    testWidgets('Delete of B with its menu open: C changed and D added meanwhile survive', (t) async {
      final h = _StartHost([_item('a'), _item('b'), _item('c')]);
      await h.pump(t);
      await _openMenu(t, 'b, b, Short Text');
      await h.remote(t, [h.items[0], h.items[1], _item('c', label: 'C changed'), _item('d')]);
      await t.tap(find.text('Delete'));
      await settle(t, 700);
      expect(h.names, ['a', 'c', 'd']);
      expect(h.items[1]['label'], 'C changed', reason: "the other client's change to c survives");
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets("Edit from alpha's menu after a reorder opens alpha's form; its Save goes to alpha", (t) async {
      final h = _StartHost([_item('alpha'), _item('beta')]);
      await h.pump(t);
      await _openMenu(t, 'alpha, alpha, Short Text');
      await h.remote(t, [h.items[1], h.items[0]]);
      await t.tap(find.text('Edit'));
      await settle(t, 800);
      final modal = find.byKey(const Key('config-var-modal'));
      expect(modal, findsOneWidget);
      final fields = find.descendant(of: modal, matching: find.byType(EditableText));
      expect(t.widget<EditableText>(fields.first).controller.text, 'alpha', reason: "alpha's form, not beta's");
      await t.enterText(fields.at(1), 'Alpha label');
      await t.tap(find.widgetWithText(DifyButton, 'Save').last);
      await settle(t, 800);
      expect(h.names, ['beta', 'alpha']);
      expect(h.items[1]['label'], 'Alpha label');
      expect(h.items[0]['label'], 'beta', reason: 'beta untouched');
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets("an open edit form's Save writes its own row on the latest list: C changed meanwhile survives; once "
        'its row is deleted underneath, Save closes the form and writes nothing', (t) async {
      final h = _StartHost([_item('a'), _item('b'), _item('c')]);
      await h.pump(t);
      await t.tap(find.bySemanticsLabel('b, b, Short Text'));
      await settle(t, 800);
      final modal = find.byKey(const Key('config-var-modal'));
      expect(modal, findsOneWidget);
      await h.remote(t, [_item('new'), h.items[0], h.items[1], _item('c', label: 'C changed')]);
      final fields = find.descendant(of: modal, matching: find.byType(EditableText));
      await t.enterText(fields.at(1), 'B label');
      await t.tap(find.widgetWithText(DifyButton, 'Save').last);
      await settle(t, 800);
      expect(h.names, ['new', 'a', 'b', 'c']);
      expect([for (final v in h.items) v['label']], ['new', 'a', 'B label', 'C changed']);

      // The form open on b; b deleted by another client; Save writes nothing.
      await t.tap(find.bySemanticsLabel('b, B label, Short Text'));
      await settle(t, 800);
      await h.remote(t, [h.items[0], h.items[1], h.items[3]]);
      await t.enterText(find.descendant(of: modal, matching: find.byType(EditableText)).at(1), 'stale');
      await t.tap(find.widgetWithText(DifyButton, 'Save').last);
      await settle(t, 800);
      expect(modal, findsNothing, reason: 'the form closes');
      expect(h.names, ['new', 'a', 'c']);
      expect([for (final v in h.items) v['label']], ['new', 'a', 'C changed'], reason: 'nothing written');
      expect(t.takeException(), isNull);
      await unmount(t);
    });
  });

  testWidgets('extract parameters: Delete and Edit from a menu find the parameter by its name in the latest list', (
    t,
  ) async {
    phoneWindow(t);
    _Json p(String name, [String description = 'd']) => {
      'name': name,
      'type': 'string',
      'required': false,
      'description': description,
    };
    var list = [p('alpha'), p('beta')];
    late StateSetter update;
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: DifyPage(
          edgeToEdge: true,
          body: StatefulBuilder(
            builder: (context, set) {
              update = set;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 80, 16, 0),
                child: ExtractParamList(list: list, onChange: (next, _) => update(() => list = next)),
              );
            },
          ),
        ),
      ),
    );
    await settle(t, 400);
    List<Object?> names() => [for (final x in list) x['name']];

    await _openMenu(t, 'alpha, String, d');
    update(() => list = [p('new'), list[0], p('beta', 'changed')]);
    await settle(t, 300);
    await t.tap(find.text('Delete'));
    await settle(t, 700);
    expect(names(), ['new', 'beta']);
    expect(list[1]['description'], 'changed', reason: "the other client's change survives");

    // Edit from beta's menu after beta moved: beta's form; once beta is gone, Edit does nothing.
    await _openMenu(t, 'beta, String, changed');
    update(() => list = [list[1], list[0]]);
    await settle(t, 300);
    await t.tap(find.text('Edit'));
    await settle(t, 800);
    final name = find.descendant(of: find.byType(ExtractParameterForm), matching: find.byType(EditableText)).first;
    expect(t.widget<EditableText>(name).controller.text, 'beta');
    await t.tap(find.widgetWithText(DifyButton, 'Cancel').last);
    await settle(t, 600);
    await _openMenu(t, 'beta, String, changed');
    update(() => list = [list[1]]);
    await settle(t, 300);
    await t.tap(find.text('Edit'));
    await settle(t, 800);
    expect(find.byType(ExtractParameterForm), findsNothing);
    expect(names(), ['new']);
    expect(t.takeException(), isNull);
    await unmount(t);
  });

  group('webhook table cells edit their own row (Winnie review17 and more)', () {
    /// A table (name input, type select) whose rows another client can change.
    Future<StateSetter> pumpTable(WidgetTester t, List<_Json> Function() rows, void Function(List<_Json>) set) async {
      phoneWindow(t);
      late StateSetter update;
      await t.pumpWidget(
        DifyApplication(
          theme: difyTheme(),
          home: DifyPage(
            edgeToEdge: true,
            body: StatefulBuilder(
              builder: (context, s) {
                update = s;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 80, 16, 0),
                  child: GenericTable(
                    title: 'Query parameters',
                    columns: const [
                      TableColumn(key: 'name', title: 'Name', type: ColumnType.input),
                      TableColumn(
                        key: 'type',
                        title: 'Type',
                        type: ColumnType.select,
                        options: [(name: 'String', value: 'string'), (name: 'Number', value: 'number')],
                      ),
                    ],
                    data: rows(),
                    onChange: (next) => update(() => set(next)),
                    emptyRowData: const {'name': '', 'type': ''},
                  ),
                );
              },
            ),
          ),
        ),
      );
      await settle(t, 400);
      return update;
    }

    // Winnie's pr90_table_selector_identity_review17_test.dart, adapted: in "remove" the picker closes with its row
    // (rows follow their identity), so Number is tapped only if the picker is still open; either way nothing is
    // written.
    for (final change in ['none', 'insert', 'remove']) {
      testWidgets('Webhook type picker targets its original row after $change', (t) async {
        var rows = <_Json>[
          {'name': 'alpha', 'type': 'string'},
          {'name': 'beta', 'type': 'string', 'description': 'original'},
        ];
        try {
          final update = await pumpTable(t, () => rows, (next) => rows = next);
          await t.tap(find.bySemanticsLabel('Type, String').first);
          await settle(t, 600);
          expect(find.text('Number'), findsOneWidget);
          if (change == 'insert') {
            update(
              () => rows = [
                {'name': 'new', 'type': 'string'},
                rows[0],
                {...rows[1], 'description': 'updated'},
              ],
            );
          }
          if (change == 'remove') {
            update(
              () => rows = [
                {...rows[1], 'description': 'updated'},
              ],
            );
          }
          await settle(t, 300);
          if (change == 'remove') {
            expect(find.text('Number'), findsNothing, reason: "alpha's picker closed with alpha");
          } else {
            await t.tap(find.text('Number'));
          }
          await settle(t, 700);
          if (change == 'none') {
            expect(rows, [
              {'name': 'alpha', 'type': 'number'},
              {'name': 'beta', 'type': 'string', 'description': 'original'},
            ]);
          }
          if (change == 'insert') {
            expect(rows, [
              {'name': 'new', 'type': 'string'},
              {'name': 'alpha', 'type': 'number'},
              {'name': 'beta', 'type': 'string', 'description': 'updated'},
            ], reason: 'the picker was opened for alpha; preserve new and beta');
          }
          if (change == 'remove') {
            expect(rows, [
              {'name': 'beta', 'type': 'string', 'description': 'updated'},
            ], reason: 'alpha no longer exists; discard the selection');
          }
          expect(t.takeException(), isNull);
        } finally {
          await unmount(t);
        }
      });
    }

    testWidgets("B's type picker after A was deleted elsewhere and B moved: the pick goes to B, C keeps its own type", (
      t,
    ) async {
      var rows = <_Json>[
        {'name': 'a', 'type': 'string'},
        {'name': 'b', 'type': 'string'},
        {'name': 'c', 'type': 'string', 'description': 'old'},
      ];
      final update = await pumpTable(t, () => rows, (next) => rows = next);
      await t.tap(find.bySemanticsLabel('Type, String').at(1));
      await settle(t, 600);
      // Another user deletes a and edits c: b is first now, c where b was.
      update(
        () => rows = [
          rows[1],
          {'name': 'c', 'type': 'string', 'description': 'new'},
        ],
      );
      await settle(t, 300);
      await t.tap(find.text('Number'));
      await settle(t, 700);
      expect(rows, [
        {'name': 'b', 'type': 'number'},
        {'name': 'c', 'type': 'string', 'description': 'new'},
      ]);
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    for (final insertMidway in [false, true]) {
      testWidgets('typing in B\'s name one character at a time: every character lands in B, the field keeps the focus '
          'and the caret${insertMidway ? ', also when another user inserts a row above B midway' : ''}', (t) async {
        var rows = <_Json>[
          {'name': 'a', 'type': 'string'},
          {'name': 'b', 'type': 'string'},
        ];
        final update = await pumpTable(t, () => rows, (next) => rows = next);
        await t.tap(find.byWidgetPredicate((w) => w is EditableText && w.controller.text == 'b'));
        await settle(t, 300);
        final focused = find.byWidgetPredicate((w) => w is EditableText && w.focusNode.hasFocus);
        final node = t.widget<EditableText>(focused).focusNode;
        var text = 'b';
        for (final ch in 'xyz'.split('')) {
          if (insertMidway && ch == 'y') {
            update(
              () => rows = [
                {'name': 'new', 'type': 'number'},
                ...rows,
              ],
            );
            await settle(t, 300);
          }
          text += ch;
          t.testTextInput.updateEditingValue(
            TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            ),
          );
          await settle(t, 100);
          expect(node.hasFocus, isTrue, reason: 'after "$text": the same field has the focus');
          final field = t.widget<EditableText>(focused);
          expect(field.focusNode, same(node));
          expect(field.controller.selection, TextSelection.collapsed(offset: text.length), reason: 'the caret');
        }
        expect([for (final r in rows) r['name']], [if (insertMidway) 'new', 'a', 'bxyz']);
        expect(rows.last['type'], 'string');

        // The empty row: a typed name appends a row, and the field keeps the focus as the row gets its key.
        final empty = find.byWidgetPredicate((w) => w is EditableText && w.controller.text.isEmpty);
        await t.tap(empty.last);
        await settle(t, 300);
        final emptyNode = t.widget<EditableText>(focused).focusNode;
        for (final value in ['d', 'd1']) {
          t.testTextInput.updateEditingValue(
            TextEditingValue(
              text: value,
              selection: TextSelection.collapsed(offset: value.length),
            ),
          );
          await settle(t, 100);
          expect(emptyNode.hasFocus, isTrue, reason: 'the new row keeps the focus after "$value"');
        }
        expect(rows.last, {'name': 'd1', 'type': ''});
        expect(t.takeException(), isNull);
        await unmount(t);
      });
    }
  });

  group('a row another user puts where a removed row was is a new row (Winnie review25 and more)', () {
    /// Winnie's pr90_replaced_row_review25_test.dart, adapted to this suite's harness.
    for (final action in ['deletion', 'selection']) {
      testWidgets('replacement $action never transfers a removed row identity to the new row at its position', (
        t,
      ) async {
        phoneWindow(t);
        var rows = <_Json>[
          {'name': 'alpha', 'type': 'string'},
          {'name': 'beta', 'type': 'string', 'description': 'old'},
        ];
        late StateSetter update;
        try {
          await t.pumpWidget(
            DifyApplication(
              theme: difyTheme(),
              home: DifyPage(
                edgeToEdge: true,
                body: StatefulBuilder(
                  builder: (context, set) {
                    update = set;
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 80, 16, 0),
                      child: GenericTable(
                        title: 'Parameters',
                        columns: const [
                          TableColumn(key: 'name', title: 'Name', type: ColumnType.input),
                          TableColumn(
                            key: 'type',
                            title: 'Type',
                            type: ColumnType.select,
                            options: [(name: 'String', value: 'string'), (name: 'Number', value: 'number')],
                          ),
                        ],
                        data: rows,
                        onChange: (next) => update(() => rows = next),
                        emptyRowData: const {'name': '', 'type': ''},
                      ),
                    );
                  },
                ),
              ),
            ),
          );
          await settle(t, 400);
          if (action == 'deletion') {
            await t.tap(find.byKey(const ValueKey('dify-action-row-more-alpha')));
          } else {
            await t.tap(find.bySemanticsLabel('Type, String').first);
          }
          await settle(t, 600);
          // One remote update: alpha removed, a distinct new row inserted at its old position, beta changed.
          final replacement = <_Json>[
            {'name': 'new', 'type': 'string', 'description': 'brand new'},
            {'name': 'beta', 'type': 'string', 'description': 'updated'},
          ];
          update(() => rows = replacement);
          await settle(t, 300);
          if (action == 'deletion') {
            if (find.text('Delete').evaluate().isNotEmpty) await t.tap(find.text('Delete'));
          } else {
            expect(find.text('Number'), findsNothing, reason: "alpha's picker closed with alpha");
            if (find.text('Number').evaluate().isNotEmpty) await t.tap(find.text('Number'));
          }
          await settle(t, 700);
          expect(
            rows,
            replacement,
            reason: 'alpha is gone: never delete or edit the distinct new row occupying its position',
          );
          expect(t.takeException(), isNull);
        } finally {
          await unmount(t);
        }
      });
    }

    testWidgets("alpha's name field focused when another user replaces alpha at its place: typing writes nothing into "
        'the new row', (t) async {
      var rows = <_Json>[
        {'name': 'alpha', 'type': 'string'},
        {'name': 'beta', 'type': 'string'},
      ];
      phoneWindow(t);
      late StateSetter update;
      await t.pumpWidget(
        DifyApplication(
          theme: difyTheme(),
          home: DifyPage(
            edgeToEdge: true,
            body: StatefulBuilder(
              builder: (context, set) {
                update = set;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 80, 16, 0),
                  child: GenericTable(
                    title: 'Parameters',
                    columns: const [TableColumn(key: 'name', title: 'Name', type: ColumnType.input)],
                    data: rows,
                    onChange: (next) => update(() => rows = next),
                    emptyRowData: const {'name': ''},
                  ),
                );
              },
            ),
          ),
        ),
      );
      await settle(t, 400);
      await t.tap(find.byWidgetPredicate((w) => w is EditableText && w.controller.text == 'alpha'));
      await settle(t, 300);
      final replacement = <_Json>[
        {'name': 'new', 'type': 'string'},
        {'name': 'beta', 'type': 'string'},
      ];
      update(() => rows = replacement);
      await settle(t, 300);
      final newField = t.widget<EditableText>(
        find.byWidgetPredicate((w) => w is EditableText && w.controller.text == 'new'),
      );
      expect(newField.focusNode.hasFocus, isFalse, reason: "alpha's field went with alpha; the new row's is not it");
      if (t.testTextInput.hasAnyClients) {
        t.testTextInput.updateEditingValue(
          const TextEditingValue(text: 'alphax', selection: TextSelection.collapsed(offset: 6)),
        );
        await settle(t, 300);
      }
      expect(rows, replacement, reason: 'nothing written into the new row');
      expect(t.takeException(), isNull);
      await unmount(t);
    });
  });

  group('a keystroke and another user\'s change in the same frame', () {
    /// A name-only table; [update] is the other client's change, [rows] the owner's list.
    Future<StateSetter> pumpNames(WidgetTester t, List<_Json> Function() rows, void Function(List<_Json>) set) async {
      phoneWindow(t);
      late StateSetter update;
      await t.pumpWidget(
        DifyApplication(
          theme: difyTheme(),
          home: DifyPage(
            edgeToEdge: true,
            body: StatefulBuilder(
              builder: (context, s) {
                update = s;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 80, 16, 0),
                  child: GenericTable(
                    title: 'Parameters',
                    columns: const [TableColumn(key: 'name', title: 'Name', type: ColumnType.input)],
                    data: rows(),
                    onChange: (next) => update(() => set(next)),
                    emptyRowData: const {'name': ''},
                  ),
                );
              },
            ),
          ),
        ),
      );
      await settle(t, 400);
      return update;
    }

    /// Types [text] into the focused field through the platform's text input (no frame yet).
    Future<void> keystroke(WidgetTester t, String text) async {
      t.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
      await Future<void>.value();
    }

    Finder field(String text) => find.byWidgetPredicate((w) => w is EditableText && w.controller.text == text);

    testWidgets('a keystroke in alpha, then (before the table rebuilds) another user deletes alpha and puts a new row '
        'at its index: the new row is not alpha (no focus, no keystroke into it)', (t) async {
      var rows = <_Json>[
        {'name': 'alpha'},
        {'name': 'beta'},
      ];
      final update = await pumpNames(t, () => rows, (next) => rows = next);
      await t.tap(field('alpha'));
      await settle(t, 300);
      await keystroke(t, 'alphax');
      expect(rows.first, {'name': 'alphax'}, reason: 'the keystroke reached the owner; the table has not rebuilt');
      final replacement = <_Json>[
        {'name': 'new'},
        {'name': 'beta'},
      ];
      update(() => rows = replacement);
      await t.pump();
      await settle(t, 300);
      final newField = t.widget<EditableText>(field('new'));
      expect(newField.focusNode.hasFocus, isFalse, reason: "alpha's field is not handed to the new row");
      if (t.testTextInput.hasAnyClients) await keystroke(t, 'alphaxy');
      await settle(t, 300);
      expect(rows, replacement, reason: 'nothing typed into the new row');
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('a keystroke in beta, then (before the table rebuilds) another user inserts a row above beta: beta '
        'keeps its field, the focus and the caret; the next keystrokes land in beta', (t) async {
      var rows = <_Json>[
        {'name': 'alpha'},
        {'name': 'beta'},
      ];
      final update = await pumpNames(t, () => rows, (next) => rows = next);
      await t.tap(field('beta'));
      await settle(t, 300);
      final node = t.widget<EditableText>(field('beta')).focusNode;
      await keystroke(t, 'betax');
      // The other client's list holds this client's keystroke (the document merged it) and a row above beta.
      update(
        () => rows = [
          {'name': 'new'},
          ...rows,
        ],
      );
      await t.pump();
      await settle(t, 300);
      expect(node.hasFocus, isTrue, reason: 'beta keeps the focus');
      final beta = t.widget<EditableText>(field('betax'));
      expect(beta.focusNode, same(node));
      expect(beta.controller.selection, const TextSelection.collapsed(offset: 5), reason: 'the caret');
      await keystroke(t, 'betaxy');
      await settle(t, 300);
      expect([for (final r in rows) r['name']], ['new', 'alpha', 'betaxy']);

      // The same when the other client's list does not hold the keystroke yet (beta by its old name).
      await keystroke(t, 'betaxyz');
      update(
        () => rows = [
          {'name': 'top'},
          {'name': 'new'},
          {'name': 'alpha'},
          {'name': 'betaxy'},
        ],
      );
      await t.pump();
      await settle(t, 300);
      expect(node.hasFocus, isTrue, reason: 'beta (by its name before the keystroke) keeps the focus');
      await keystroke(t, 'betaxy!');
      await settle(t, 300);
      expect([for (final r in rows) r['name']], ['top', 'new', 'alpha', 'betaxy!']);
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    // Winnie's pr90_coalesced_edit_review32_test.dart, adapted to this suite's harness.
    for (final replaced in [false, true]) {
      testWidgets('coalesced local name input and external update preserve the original target; replaced=$replaced', (
        t,
      ) async {
        phoneWindow(t);
        var rows = <_Json>[
          {'name': 'alpha', 'type': 'string'},
          {'name': 'beta', 'type': 'string', 'description': 'old'},
        ];
        late StateSetter update;
        var writes = 0;
        try {
          await t.pumpWidget(
            DifyApplication(
              theme: difyTheme(),
              home: DifyPage(
                edgeToEdge: true,
                body: StatefulBuilder(
                  builder: (context, set) {
                    update = set;
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 80, 16, 0),
                      child: GenericTable(
                        title: 'Parameters',
                        columns: const [TableColumn(key: 'name', title: 'Name', type: ColumnType.input)],
                        data: rows,
                        onChange: (next) => update(() {
                          rows = next;
                          writes++;
                        }),
                        emptyRowData: const {'name': ''},
                      ),
                    );
                  },
                ),
              ),
            ),
          );
          await settle(t, 400);
          final first = find.byType(EditableText).first;
          await t.tap(first);
          await settle(t, 200);
          // Both setState calls happen before a frame: the second document is not an echo of our local write.
          t.testTextInput.updateEditingValue(
            const TextEditingValue(text: 'alpha1', selection: TextSelection.collapsed(offset: 6)),
          );
          expect(writes, 1);
          final next = <_Json>[
            {'name': replaced ? 'new' : 'alpha1', 'type': 'string'},
            {'name': 'beta', 'type': 'string', 'description': 'updated'},
          ];
          update(() => rows = next);
          await settle(t, 300);
          if (t.testTextInput.hasAnyClients) {
            t.testTextInput.updateEditingValue(
              const TextEditingValue(text: 'alpha12', selection: TextSelection.collapsed(offset: 7)),
            );
            await settle(t, 300);
          }
          if (replaced) {
            expect(
              rows,
              next,
              reason:
                  'an external replacement is not our pending local rename acknowledgment; stale typing must not '
                  'write new',
            );
            expect(writes, 1, reason: 'only the local input before the replacement may write');
          } else {
            expect(rows, [
              {'name': 'alpha12', 'type': 'string'},
              {'name': 'beta', 'type': 'string', 'description': 'updated'},
            ], reason: 'the surviving original keeps focus and beta keeps the new value');
            expect(writes, 2);
          }
          expect(t.takeException(), isNull);
        } finally {
          await unmount(t);
        }
      });
    }
  });
}
