// dify-spec: web/app/components/workflow/nodes/end/__tests__/node.spec.tsx
// dify-spec: web/app/components/workflow/nodes/answer/__tests__/node.spec.tsx
//
// The canvas cards are dify-sf's EndBody and AnswerBody; Dify's mocked upstream nodes are the card's lookup.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/answer_body.dart';
import 'package:dify_sf_app/src/cards/bodies/basic_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/cards/node_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final _nodes = difyNodes([
  difyNode('start', 'start', {'variables': <Object?>[]}, 'Start'),
  difyNode('source-node', 'code', {
    'outputs': {
      'answer': {'type': 'string'},
      'name': {'type': 'string'},
    },
  }, 'Source Node'),
]);

Future<void> renderNode(WidgetTester t, NodeBody body, Node node, {List<Node> before = const []}) {
  useDifyTestTranslator();
  final byId = {for (final n in before) n.id: n};
  return t.pumpWidget(
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 240,
            child: Builder(
              builder: (c) => body.build(c, BodyContext(node, (id) => byId[id], start: byId['start'])),
            ),
          ),
        ),
      ),
    ),
  );
}

Node endNode(List<Map<String, Object?>> outputs) => difyNodes([
  ..._raw,
  difyNode('end', 'end', {'outputs': outputs}, 'End'),
]).last;

final _raw = [
  difyNode('start', 'start', {'variables': <Object?>[]}, 'Start'),
  difyNode('source-node', 'code', {
    'outputs': {
      'answer': {'type': 'string'},
      'name': {'type': 'string'},
    },
  }, 'Source Node'),
];

Node answerNode(String answer) => difyNodes([
  ..._raw,
  difyNode('answer', 'answer', {'variables': <Object?>[], 'answer': answer}, 'Answer'),
]).last;

/// Text of the card's inline paragraphs (written with zero-width spaces between characters for `break-all`).
Finder _inText(String text) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText().replaceAll('\u200B', '').contains(text),
  description: 'inline text "$text"',
);

void main() {
  group('EndNode', () {
    group('Rendering', () {
      testWidgets('should render resolved output labels for referenced nodes', (t) async {
        await renderNode(
          t,
          const EndBody(),
          endNode([
            {
              'variable': 'answer',
              'value_selector': ['source-node', 'answer'],
            },
          ]),
          before: _nodes,
        );
        expect(find.text('Source Node'), findsOneWidget);
        expect(find.text('answer'), findsOneWidget);
        expect(find.text('String'), findsOneWidget);
      });

      testWidgets('should fall back to the start node when the selector node cannot be found', (t) async {
        await renderNode(
          t,
          const EndBody(),
          endNode([
            {
              'variable': 'answer',
              'value_selector': ['missing', 'answer'],
            },
          ]),
          before: _nodes,
        );
        expect(find.text('Start'), findsOneWidget);
        expect(find.text('answer'), findsOneWidget);
      });

      testWidgets('should render nothing when every output selector is empty', (t) async {
        final node = endNode([
          {'variable': 'answer', 'value_selector': <Object?>[]},
        ]);
        await renderNode(t, const EndBody(), node, before: _nodes);
        expect(find.byType(Text), findsNothing);
        expect(const EndBody().height(BodyContext(node, (_) => null)), 0);
      });
    });
  });

  group('AnswerNode', () {
    group('Rendering', () {
      testWidgets('should render the answer title and text content', (t) async {
        await renderNode(t, const AnswerBody(), answerNode('Plain answer'));
        expect(find.text('WORKFLOW.NODES.ANSWER.ANSWER'), findsOneWidget);
        expect(_inText('Plain answer'), findsWidgets);
      });

      testWidgets('should render referenced variables inside the readonly content', (t) async {
        await renderNode(t, const AnswerBody(), answerNode('Hello {{#source-node.name#}}'), before: _nodes);
        expect(_inText('Hello'), findsWidgets);
        expect(find.text('Source Node'), findsOneWidget);
        expect(find.text('name'), findsOneWidget);
      });
    });
  });
}
