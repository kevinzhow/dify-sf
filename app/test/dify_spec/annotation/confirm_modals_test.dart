// dify-spec: web/app/components/app/annotation/remove-annotation-confirm-modal/__tests__/index.spec.tsx
// dify-spec: web/app/components/app/annotation/clear-all-annotations-confirm-modal/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/app_detail/annotations/confirm_modals.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

// Dify's specs translate the title, Cancel and Confirm; the test translator's keys stand in for them.
const _remove = 'appDebug.feature.annotation.removeConfirm';
const _clear = 'appAnnotation.table.header.clearAllConfirm';
const _cancel = 'common.operation.cancel';
const _confirm = 'common.operation.confirm';

void main() {
  group('RemoveAnnotationConfirmModal', () {
    group('Rendering', () {
      testWidgets('should display the confirm modal when visible', (t) async {
        await renderAnnotation(t, RemoveAnnotationConfirmModal(isShow: true, onHide: () {}, onRemove: () {}));
        expect(find.text(_remove), findsOneWidget);
        expect(button(_cancel), findsOneWidget);
        expect(button(_confirm), findsOneWidget);
      });

      testWidgets('should not render modal content when hidden', (t) async {
        await renderAnnotation(t, RemoveAnnotationConfirmModal(isShow: false, onHide: () {}, onRemove: () {}));
        expect(find.text(_remove), findsNothing);
      });
    });

    group('Interactions', () {
      testWidgets('should call onHide when cancel button is clicked', (t) async {
        var hide = 0, remove = 0;
        await renderAnnotation(
          t,
          RemoveAnnotationConfirmModal(isShow: true, onHide: () => hide++, onRemove: () => remove++),
        );
        await tapButton(t, _cancel);
        expect(hide, 1);
        expect(remove, 0);
      });

      testWidgets('should call onRemove when confirm button is clicked', (t) async {
        var hide = 0, remove = 0;
        await renderAnnotation(
          t,
          RemoveAnnotationConfirmModal(isShow: true, onHide: () => hide++, onRemove: () => remove++),
        );
        await tapButton(t, _confirm);
        expect(remove, 1);
        expect(hide, 0);
      });
    });
  });

  group('ClearAllAnnotationsConfirmModal', () {
    group('Rendering', () {
      testWidgets('should show confirmation dialog when isShow is true', (t) async {
        await renderAnnotation(t, ClearAllAnnotationsConfirmModal(isShow: true, onHide: () {}, onConfirm: () {}));
        expect(find.text(_clear), findsOneWidget);
        expect(button(_cancel), findsOneWidget);
        expect(button(_confirm), findsOneWidget);
      });

      testWidgets('should not render anything when isShow is false', (t) async {
        await renderAnnotation(t, ClearAllAnnotationsConfirmModal(isShow: false, onHide: () {}, onConfirm: () {}));
        expect(find.text(_clear), findsNothing);
      });
    });

    group('Interactions', () {
      testWidgets('should trigger onHide when cancel is clicked', (t) async {
        var hide = 0, confirm = 0;
        await renderAnnotation(
          t,
          ClearAllAnnotationsConfirmModal(isShow: true, onHide: () => hide++, onConfirm: () => confirm++),
        );
        await tapButton(t, _cancel);
        expect(hide, 1);
        expect(confirm, 0);
      });

      testWidgets('should trigger onConfirm when confirm is clicked', (t) async {
        var hide = 0, confirm = 0;
        await renderAnnotation(
          t,
          ClearAllAnnotationsConfirmModal(isShow: true, onHide: () => hide++, onConfirm: () => confirm++),
        );
        await tapButton(t, _confirm);
        expect(confirm, 1);
        expect(hide, 0);
      });
    });
  });
}
