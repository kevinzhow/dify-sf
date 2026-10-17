// dify-spec: web/app/components/workflow/nodes/http/__tests__/node.spec.tsx
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/data_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Node createData({String method = 'get', String url = 'https://api.example.com'}) => Node(
  id: 'http-node',
  type: 'http-request',
  title: 'HTTP Request',
  config: {'method': VString(method), 'url': VString(url)},
);

Future<void> render(WidgetTester t, Node node) => t.pumpWidget(
  MaterialApp(
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 238,
          child: Builder(builder: (c) => const HttpRequestBody().build(c, BodyContext(node, (_) => null))),
        ),
      ),
    ),
  ),
);

/// Text shown in a RichText (the URL's ReadonlyInputWithSelectVar; break-all puts zero-width spaces between letters).
Finder richText(String text) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText().replaceAll('\u200b', '').contains(text),
  description: 'text "$text"',
);

void main() {
  group('http/node', () {
    testWidgets('renders the request method and forwards the URL to the readonly input', (t) async {
      await render(t, createData(method: 'post', url: 'https://api.example.com/users'));

      // CSS `uppercase` is applied to the text.
      expect(find.text('POST'), findsOneWidget);
      expect(richText('https://api.example.com/users'), findsWidgets);
      expect(const HttpRequestBody().height(BodyContext(createData(), (_) => null)), greaterThan(0));
    });

    testWidgets('renders nothing when the request URL is empty', (t) async {
      final node = createData(url: '');
      await render(t, node);

      expect(find.byType(Text), findsNothing);
      expect(const HttpRequestBody().height(BodyContext(node, (_) => null)), 0);
    });
  });
}
