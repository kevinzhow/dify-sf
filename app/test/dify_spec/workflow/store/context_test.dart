// dify-spec: web/app/components/workflow/__tests__/context.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class StoreConsumer extends StatelessWidget {
  const StoreConsumer({super.key});

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ValueListenableBuilder(
      valueListenable: store.showSingleRunPanel,
      builder: (context, showSingleRunPanel, _) => GestureDetector(
        onTap: () => store.setShowSingleRunPanel(!showSingleRunPanel),
        child: Text(showSingleRunPanel ? 'open' : 'closed'),
      ),
    );
  }
}

void main() {
  group('WorkflowContextProvider', () {
    testWidgets('provides the workflow store to descendants and keeps the same store across rerenders', (t) async {
      Widget app() => const Directionality(
        textDirection: TextDirection.ltr,
        child: WorkflowStoreProvider(child: StoreConsumer()),
      );
      await t.pumpWidget(app());

      expect(find.text('closed'), findsOneWidget);

      await t.tap(find.text('closed'));
      await t.pump();
      expect(find.text('open'), findsOneWidget);

      await t.pumpWidget(app());

      expect(find.text('open'), findsOneWidget);
    });
  });
}
