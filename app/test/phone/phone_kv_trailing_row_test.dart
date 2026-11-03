// The key / value tables' trailing empty row on a phone (fixes after PR #90, item 1): typing fast into the last row's
// VALUE adds the next empty row once. Several keystrokes in one frame (the platform's text input coalesced before the
// table rebuilds) and keystrokes across frames give exactly one trailing empty row, also after the value is committed.
// The HTTP Request node's headers (string-backed rows) and form-data body (document rows), and the Webhook trigger's
// tables (a virtual trailing row), in the real editor at 411x914 and 360x780.
import 'package:collab_client/collab_client.dart' show Document, Edge, Node;
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart' show HistoryEvent;
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart' show nodeFromDify;
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/edit_body.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/http/key_value.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_tables.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/workflow_steps_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

Future<(EditorController, DemoBackend)> _editor(
  WidgetTester t,
  Size size,
  String type,
  Map<String, Object?> data,
) async {
  phoneWindow(t, size: size);
  final demo = DemoBackend(withBo: false);
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      home: EditorPage(backend: demo, docId: 'demo', clientId: 'phone-kv', journaled: false),
    ),
  );
  await settle(t, 2000);
  final c = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
  final nodes = <Node>[];
  void add(String id, String type, String title, Map<String, Object?> data) => nodes.add(
    nodeFromDify(
      {
        'id': id,
        'position': {'x': nodes.length * 300, 'y': 0},
        'data': {'type': type, 'title': title, ...data},
      },
      Document(nodes: nodes),
      id: id,
    ),
  );
  if (type == 'http-request') {
    add('n-start', 'start', 'Start', {'variables': <Object?>[]});
  }
  add('n-x', type, 'Under test', data);
  c.applyGraphChange(
    event: HistoryEvent.nodeAdd,
    removeNodes: [...c.doc.nodes.keys],
    addNodes: nodes,
    addEdges: [if (type == 'http-request') Edge(id: 'e-0', source: 'n-start', target: 'n-x')],
  );
  c.selectNode(null);
  await settle(t, 800);
  await t.tap(find.descendant(of: find.byType(WorkflowStepsView), matching: find.text('Under test')).first);
  await settle(t, 800);
  return (c, demo);
}

Map<String, Object?> _http({String headers = '', Map<String, Object?>? body}) => {
  'variables': <Object?>[],
  'method': 'post',
  'url': '',
  'authorization': {'type': 'no-auth', 'config': null},
  'headers': headers,
  'params': '',
  'body': body ?? {'type': 'none', 'data': <Object?>[]},
  'timeout': {'connect': 5, 'read': 10, 'write': 15},
  'ssl_verify': true,
};

/// Types [text] into the focused field through the platform's text input, without a frame.
void _keystroke(WidgetTester t, String text) => t.testTextInput.updateEditingValue(
  TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  ),
);

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in phoneSizes) {
    final at = '${size.width.toInt()}x${size.height.toInt()}';

    for (final where in ['headers', 'form-data body']) {
      testWidgets('$at HTTP $where: fast typing in the last row\'s VALUE adds one trailing empty row, in one frame and '
          'across frames, and the value commits to its row', (t) async {
        final isHeaders = where == 'headers';
        final (c, demo) = await _editor(
          t,
          size,
          'http-request',
          _http(
            body: isHeaders
                ? null
                : {
                    'type': 'form-data',
                    'data': [
                      {'id': 'r1', 'type': 'text', 'key': 'a', 'value': '1'},
                      {'id': 'r2', 'type': 'text', 'key': 'b', 'value': ''},
                    ],
                  },
          ),
        );
        final table = isHeaders ? find.byType(KeyValueLines).first : find.byType(EditBody);
        final rows = find.descendant(of: table, matching: find.byType(KeyValueRow));
        Finder cell(int i) => find.descendant(of: table, matching: find.byType(EditableText)).at(i);
        // The headers: one blank row; its KEY is typed first (a key adds no row). The body: a:1 and b with no value.
        final n0 = isHeaders ? 1 : 2;
        expect(rows, findsNWidgets(n0));
        if (isHeaders) {
          await t.ensureVisible(cell(0));
          await settle(t, 300);
          await t.tap(cell(0));
          await settle(t, 400);
          _keystroke(t, 'b');
          await settle(t, 300);
          expect(rows, findsNWidgets(1), reason: 'a key adds no row');
        }
        final value = cell(isHeaders ? 1 : 3);
        await t.ensureVisible(value);
        await settle(t, 300);
        await t.tap(value);
        await settle(t, 400);
        final node = t.widget<EditableText>(value).focusNode;
        expect(node.hasFocus, isTrue);
        // Three keystrokes before the table rebuilds.
        for (final s in ['x', 'xy', 'xyz']) {
          _keystroke(t, s);
        }
        await t.pump();
        expect(rows, findsNWidgets(n0 + 1), reason: 'one frame of keystrokes: one trailing empty row');
        // More keystrokes, a frame each.
        for (final s in ['xyz1', 'xyz12', 'xyz123']) {
          _keystroke(t, s);
          await t.pump();
          expect(rows, findsNWidgets(n0 + 1), reason: 'after "$s": still one trailing empty row');
        }
        await settle(t, 300);
        expect(rows, findsNWidgets(n0 + 1));
        expect(node.hasFocus, isTrue, reason: 'the value keeps the focus');
        // The value commits on blur, to its own row; the trailing row stays one.
        node.unfocus();
        await settle(t, 400);
        expect(rows, findsNWidgets(n0 + 1), reason: 'after the commit');
        final data = plainOf(c.doc.nodes['n-x']!.config[isHeaders ? 'headers' : 'body']);
        if (isHeaders) {
          expect(data, 'b:xyz123');
        } else {
          final list = [for (final r in jsList((data as Map)['data'])) r as Map];
          expect([for (final r in list) '${r['key']}:${r['value']}'], ['a:1', 'b:xyz123', ':']);
        }
        expect(t.takeException(), isNull);
        await unmount(t);
        await demo.dispose();
        await t.pump(const Duration(seconds: 20));
      });
    }

    testWidgets(
      '$at Webhook parameters: fast typing in the trailing row adds one row and keeps one trailing empty row, '
      'in one frame and across frames',
      (t) async {
        final (c, demo) = await _editor(t, size, 'trigger-webhook', {
          'method': 'POST',
          'content_type': 'application/json',
          'headers': <Object?>[],
          'params': [
            {'name': 'city', 'type': 'string', 'required': false},
          ],
          'body': <Object?>[],
          'async_mode': true,
          'status_code': 200,
          'response_body': '',
          'variables': <Object?>[],
          'webhook_url': 'https://example.com/hook',
          'webhook_debug_url': 'https://example.com/hook-debug',
        });
        final table = find.byType(ParameterTable).first;
        final fields = find.descendant(of: table, matching: find.byType(EditableText));
        expect(fields, findsNWidgets(2), reason: 'city and the trailing empty row');
        await t.ensureVisible(fields.last);
        await settle(t, 300);
        await t.tap(fields.last);
        await settle(t, 400);
        final node = t.widget<EditableText>(fields.last).focusNode;
        for (final s in ['d', 'da', 'day']) {
          _keystroke(t, s);
        }
        await t.pump();
        expect(fields, findsNWidgets(3), reason: 'one frame: the typed row and one trailing empty row');
        for (final s in ['days', 'days1', 'days12']) {
          _keystroke(t, s);
          await t.pump();
          expect(fields, findsNWidgets(3), reason: 'after "$s"');
          expect(node.hasFocus, isTrue, reason: 'after "$s": the typed row keeps the focus');
        }
        await settle(t, 300);
        expect(fields, findsNWidgets(3));
        expect(
          [for (final p in jsList(plainOf(c.doc.nodes['n-x']!.config['params']))) (p as Map)['name']],
          [
            'city',
            'days12',
          ],
        );
        expect(t.takeException(), isNull);
        await unmount(t);
        await demo.dispose();
        await t.pump(const Duration(seconds: 20));
      },
    );
  }
}
