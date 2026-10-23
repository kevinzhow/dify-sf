// dify-spec: web/app/components/workflow/nodes/_base/components/variable/variable-label/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/cards/variable_label.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> render(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: Center(child: child)),
  ),
);

Iterable<DifyIcon> icons(WidgetTester tester) => tester.widgetList<DifyIcon>(find.byType(DifyIcon));

void main() {
  group('variable-label index', () {
    group('Rendering', () {
      testWidgets('should render the node variant with node label and variable type', (tester) async {
        await render(
          tester,
          const SizedBox(
            width: 240,
            child: VariableLabel(
              variant: VarLabelStyle.inNode,
              nodeType: 'code',
              nodeTitle: 'Source Node',
              variables: ['source-node', 'answer'],
              variableType: 'string',
            ),
          ),
        );

        expect(find.text('Source Node'), findsOneWidget);
        expect(find.text('answer'), findsOneWidget);
        expect(find.text('String'), findsOneWidget);
      });

      testWidgets('should render the text variant with the shortened variable path', (tester) async {
        await render(
          tester,
          const VariableLabel(
            variant: VarLabelStyle.inText,
            nodeType: 'code',
            nodeTitle: 'Source Node',
            variables: ['source-node', 'payload', 'answer'],
            notShowFullPath: true,
            isExceptionVariable: true,
          ),
        );

        expect(find.byKey(const Key('exception-variable')), findsOneWidget);
        expect(find.text('Source Node'), findsOneWidget);
        expect(find.text('answer'), findsOneWidget);
      });

      testWidgets('should render the select variant with the full variable path', (tester) async {
        await render(
          tester,
          const VariableLabel(
            nodeType: 'code',
            nodeTitle: 'Source Node',
            variables: ['source-node', 'payload', 'answer'],
          ),
        );

        expect(find.text('payload.answer'), findsOneWidget);
      });

      testWidgets('should render the editor variant with selected styles and inline error feedback', (tester) async {
        await render(
          tester,
          const VariableLabel(
            variant: VarLabelStyle.inEditor,
            nodeType: 'code',
            nodeTitle: 'Source Node',
            variables: ['source-node', 'payload'],
            isSelected: true,
            errorMsg: 'Invalid variable',
            rightSlot: Text('suffix'),
          ),
        );

        expect(find.text('payload'), findsOneWidget);
        expect(find.text('suffix'), findsOneWidget);

        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: tester.getCenter(find.text('payload')));
        await tester.pump();

        expect(icons(tester).where((i) => i.name == 'vender/line/alertsAndFeedback/warning'), isNotEmpty);
      });

      testWidgets('should render the icon helpers for environment and exception variables', (tester) async {
        await render(
          tester,
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              VariableIcon(variables: ['env', 'API_KEY']),
              VariableIconWithColor(variables: ['conversation', 'message'], isExceptionVariable: true),
            ],
          ),
        );

        expect(icons(tester).length, greaterThan(0));
      });

      testWidgets('should render the base variable name with shortened path and title', (tester) async {
        await render(tester, const VariableName(variables: ['node-id', 'payload', 'answer'], notShowFullPath: true));

        expect(find.text('answer'), findsOneWidget);
        final tooltip = tester.widget<DifyTooltip>(
          find.ancestor(of: find.text('answer'), matching: find.byType(DifyTooltip)),
        );
        expect((tooltip.content as DifyTextLine).data, 'answer');
      });

      testWidgets('should show the full name in a tooltip after the delay when hovering', (tester) async {
        await render(tester, const VariableName(variables: ['node-id', 'payload', 'answer'], notShowFullPath: true));
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(find.text('answer')));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.text('answer'), findsOneWidget, reason: 'only the inline label so far, no tooltip copy');
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(find.text('answer'), findsNWidgets(2), reason: 'the label and the tooltip');
        await gesture.moveTo(Offset.zero);
        await tester.pump(const Duration(milliseconds: 250), EnginePhase.build);
        await tester.pumpAndSettle();
        expect(find.text('answer'), findsOneWidget, reason: 'closed when the pointer leaves');
      });

      testWidgets('should render the base node label only when node type exists', (tester) async {
        await render(tester, const VariableNodeLabel());

        expect(find.byType(Text), findsNothing);

        await render(tester, const VariableNodeLabel(nodeType: 'code', nodeTitle: 'Code Node'));

        expect(find.text('Code Node'), findsOneWidget);
      });

      testWidgets('should render the base label with variable type and right slot', (tester) async {
        await render(
          tester,
          const VariableLabel(
            nodeType: 'code',
            nodeTitle: 'Source Node',
            variables: ['sys', 'query'],
            variableType: 'string',
            rightSlot: Text('slot'),
          ),
        );

        expect(find.text('Source Node'), findsOneWidget);
        expect(find.text('query'), findsOneWidget);
        expect(find.text('String'), findsOneWidget);
        expect(find.text('slot'), findsOneWidget);
      });
    });
  });
}
