// dify-spec: web/app/components/app/create-from-dsl-modal/__tests__/dsl-confirm-modal.spec.tsx
import 'package:dify_sf_app/src/studio/app_modals.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('DSLConfirmModal', () {
    testWidgets('should render the version details', (t) async {
      await renderMembers(
        t,
        DSLConfirmModal(importedVersion: '1.0.0', systemVersion: '2.0.0', onCancel: () {}, onConfirm: () {}),
      );
      expect(find.text('app.newApp.appCreateDSLErrorTitle'), findsOneWidget);
      expect(find.textContaining('1.0.0', findRichText: true), findsOneWidget);
      expect(find.textContaining('2.0.0', findRichText: true), findsOneWidget);
    });

    testWidgets('should call the cancel and confirm handlers', (t) async {
      var cancel = 0, confirm = 0;
      await renderMembers(t, DSLConfirmModal(onCancel: () => cancel++, onConfirm: () => confirm++));
      await tapButton(t, 'app.newApp.Cancel');
      await tapButton(t, 'app.newApp.Confirm');
      expect((cancel, confirm), (1, 1));
    });
  });
}
