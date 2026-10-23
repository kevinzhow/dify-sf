// dify-spec: web/app/components/app/annotation/add-annotation-modal/__tests__/index.spec.tsx
// dify-spec: web/app/components/app/annotation/add-annotation-modal/edit-item/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/app_detail/annotations/annotation_modals.dart';
import 'package:dify_sf_app/src/app_detail/annotations/annotation_types.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import '../../support/field_hints.dart';

const _queryPlaceholder = 'appAnnotation.addModal.queryPlaceholder';
const _answerPlaceholder = 'appAnnotation.addModal.answerPlaceholder';
const _add = 'common.operation.add';

class _Rig {
  final added = <AnnotationItemBasic>[];
  var hidden = 0;
  final toast = ToastLog();
}

Future<_Rig> _render(WidgetTester t) async {
  final rig = _Rig();
  await renderAnnotation(
    t,
    AddAnnotationModal(
      isShow: true,
      onHide: () => rig.hidden++,
      onAdd: (p) async => rig.added.add(p),
      toast: rig.toast.call,
    ),
  );
  return rig;
}

void main() {
  group('AddAnnotationModal', () {
    testWidgets('should render modal title when drawer is visible', (t) async {
      await _render(t);
      expect(find.text('appAnnotation.addModal.title'), findsOneWidget);
    });

    testWidgets('should capture query input text when typing', (t) async {
      await _render(t);
      await typeInto(t, _queryPlaceholder, 'Sample question');
      expect(find.text('Sample question'), findsOneWidget);
    });

    testWidgets('should capture answer input text when typing', (t) async {
      await _render(t);
      await typeInto(t, _answerPlaceholder, 'Sample answer');
      expect(find.text('Sample answer'), findsOneWidget);
    });

    testWidgets('should call onAdd with form values when create next enabled', (t) async {
      final rig = await _render(t);
      await typeInto(t, _queryPlaceholder, 'Question value');
      await typeInto(t, _answerPlaceholder, 'Answer value');
      await t.tap(find.text('appAnnotation.addModal.createNext'));
      await settle(t);
      await tapButton(t, _add);
      expect(rig.added, [(question: 'Question value', answer: 'Answer value')]);
    });

    testWidgets('should reset fields after saving when create next enabled', (t) async {
      final rig = await _render(t);
      await typeInto(t, _queryPlaceholder, 'Question value');
      await typeInto(t, _answerPlaceholder, 'Answer value');
      await t.tap(find.text('appAnnotation.addModal.createNext'));
      await settle(t);
      await tapButton(t, _add);
      expect(rig.added, hasLength(1));
      expect(find.text('Question value'), findsNothing);
      expect(find.text('Answer value'), findsNothing);
      expect(find.text(_queryPlaceholder), findsOneWidget);
      expect(rig.hidden, 0);
    });

    testWidgets('should show toast when validation fails for missing question', (t) async {
      final rig = await _render(t);
      await tapButton(t, _add);
      expect(rig.toast.has(DifyToastType.error, 'appAnnotation.errorMessage.queryRequired'), isTrue);
      expect(rig.added, isEmpty);
    });

    testWidgets('should show toast when validation fails for missing answer', (t) async {
      final rig = await _render(t);
      await typeInto(t, _queryPlaceholder, 'Filled question');
      await tapButton(t, _add);
      expect(rig.toast.has(DifyToastType.error, 'appAnnotation.errorMessage.answerRequired'), isTrue);
    });

    testWidgets('should close modal when save completes and create next unchecked', (t) async {
      final rig = await _render(t);
      await typeInto(t, _queryPlaceholder, 'Q');
      await typeInto(t, _answerPlaceholder, 'A');
      await tapButton(t, _add);
      expect(rig.hidden, 1);
    });

    testWidgets('should allow cancel button to close the drawer', (t) async {
      final rig = await _render(t);
      await tapButton(t, 'common.operation.cancel');
      expect(rig.hidden, 1);
    });
  });

  group('AddAnnotationModal/EditItem', () {
    testWidgets('should render query inputs with user avatar and placeholder strings', (t) async {
      await renderAnnotation(t, AddAnnotationEditItem(type: EditItemType.query, content: 'Why?', onChange: (_) {}));
      expect(find.text('appAnnotation.addModal.queryName'), findsOneWidget);
      expect(find.text(_queryPlaceholder), findsOneWidget);
      expect(find.text('Why?'), findsOneWidget);
    });

    testWidgets('should render answer name and placeholder text', (t) async {
      await renderAnnotation(
        t,
        AddAnnotationEditItem(type: EditItemType.answer, content: 'Existing answer', onChange: (_) {}),
      );
      expect(find.text('appAnnotation.addModal.answerName'), findsOneWidget);
      // The field has a value, so its hint (the placeholder) is set but not drawn.
      expect(hintTextOf(t.widget<TextField>(find.byType(TextField))), _answerPlaceholder);
      expect(find.text('Existing answer'), findsOneWidget);
    });

    testWidgets('should propagate changes when answer content updates', (t) async {
      final changes = <String>[];
      await renderAnnotation(t, AddAnnotationEditItem(type: EditItemType.answer, content: '', onChange: changes.add));
      await typeInto(t, _answerPlaceholder, 'Because');
      expect(changes, ['Because']);
    });
  });
}
