// dify-spec: web/app/components/workflow/nodes/human-input/__tests__/node.spec.tsx
//
// The canvas card (HumanInputBody): handles are its `sources`; the header text is the card's own "Delivery Method"
// (it does not go through i18n; see the report), upper-cased like Dify's CSS.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/entry_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> createData([Map<String, Object?> overrides = const {}]) => {
  'title': 'Human Input',
  'desc': '',
  'type': 'human-input',
  'delivery_methods': [
    {'id': 'dm-webapp', 'type': 'webapp', 'enabled': true},
    {'id': 'dm-email', 'type': 'email', 'enabled': true},
  ],
  'form_content': 'Please review this request',
  'inputs': [
    {
      'type': 'paragraph',
      'output_variable_name': 'review_result',
      'default': {'selector': <Object?>[], 'type': 'constant', 'value': ''},
    },
  ],
  'user_actions': [
    {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
    {'id': 'reject', 'title': 'Reject', 'button_style': 'default'},
  ],
  'timeout': 3,
  'timeout_unit': 'day',
  ...overrides,
};

Future<BodyContext> render(WidgetTester t, Map<String, Object?> data) async {
  final node = nodeFromDify(
    {
      'id': 'human-input-node',
      'position': {'x': 0, 'y': 0},
      'data': data,
    },
    Document(),
    id: 'human-input-node',
  );
  final ctx = BodyContext(node, (_) => null);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 238, child: Builder(builder: (c) => const HumanInputBody().build(c, ctx))),
        ),
      ),
    ),
  );
  return ctx;
}

void main() {
  group('human-input/node', () {
    testWidgets('renders delivery methods, user action handles, and the timeout handle', (t) async {
      final ctx = await render(t, createData());

      expect(find.text('DELIVERY METHOD'), findsOneWidget);
      expect(find.text('Webapp'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('APPROVE'), findsOneWidget);
      expect(find.text('REJECT'), findsOneWidget);
      expect(find.text('TIMEOUT'), findsOneWidget);
      expect(const HumanInputBody().sources(ctx).keys, ['approve', 'reject', '__timeout']);
    });

    testWidgets('keeps the timeout handle when delivery methods and actions are empty', (t) async {
      final ctx = await render(
        t,
        createData({'delivery_methods': <Object?>[], 'user_actions': <Object?>[]}),
      );

      expect(find.text('DELIVERY METHOD'), findsNothing);
      expect(find.text('TIMEOUT'), findsOneWidget);
      expect(const HumanInputBody().sources(ctx).keys, ['__timeout']);
    });
  });
}
