// dify-spec: web/app/components/app/annotation/edit-annotation-modal/__tests__/index.spec.tsx
// dify-spec: web/app/components/app/annotation/edit-annotation-modal/edit-item/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/app_detail/annotations/annotation_modals.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _edit = 'common.operation.edit';
const _save = 'common.operation.save';
const _removeThisCache = 'appAnnotation.editModal.removeThisCache';
const _removeConfirm = 'appDebug.feature.annotation.removeConfirm';

class _Rig {
  final edits = <({String id, String question, String answer, String? messageId})>[];
  final edited = <(String, String)>[];
  var hidden = 0, removed = 0;
  final toast = ToastLog();
  Object? error;
}

Widget _modal(
  _Rig rig, {
  bool isShow = true,
  String query = 'Test query',
  String answer = 'Test answer',
  String annotationId = 'test-annotation-id',
  String? messageId,
  int? createdAt,
  bool onlyEditResponse = false,
}) => EditAnnotationModal(
  isShow: isShow,
  onHide: () => rig.hidden++,
  annotationId: annotationId,
  messageId: messageId,
  query: query,
  answer: answer,
  createdAt: createdAt,
  onlyEditResponse: onlyEditResponse,
  onEdited: (q, a) => rig.edited.add((q, a)),
  onRemove: () => rig.removed++,
  toast: rig.toast.call,
  formatTime: (_, _) => '2023-12-01 10:30:00',
  editAnnotation: (id, {required question, required answer, messageId}) async {
    rig.edits.add((id: id, question: question, answer: answer, messageId: messageId));
    final e = rig.error;
    if (e != null) {
      rig.error = null;
      throw e;
    }
  },
);

/// Opens the first item's editor, types [text] and saves.
Future<void> _editFirst(WidgetTester t, String text) async {
  await t.tap(find.text(_edit).first);
  await settle(t);
  expect(t.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);
  t.testTextInput.enterText(text);
  await settle(t, 2);
  await tapButton(t, _save);
}

void main() {
  group('EditAnnotationModal', () {
    group('Rendering', () {
      testWidgets('should render modal when isShow is true', (t) async {
        await renderAnnotation(t, _modal(_Rig()));
        expect(find.text('appAnnotation.editModal.title'), findsOneWidget);
      });

      testWidgets('should not render modal when isShow is false', (t) async {
        await renderAnnotation(t, _modal(_Rig(), isShow: false));
        expect(find.text('appAnnotation.editModal.title'), findsNothing);
      });

      testWidgets('should display query and answer sections', (t) async {
        await renderAnnotation(t, _modal(_Rig()));
        expect(find.text('Test query'), findsOneWidget);
        expect(find.text('Test answer'), findsOneWidget);
      });
    });

    group('Props', () {
      testWidgets('should handle different query and answer content', (t) async {
        await renderAnnotation(t, _modal(_Rig(), query: 'Custom query content', answer: 'Custom answer content'));
        expect(find.text('Custom query content'), findsOneWidget);
        expect(find.text('Custom answer content'), findsOneWidget);
      });

      testWidgets('should show remove option when annotationId is provided', (t) async {
        await renderAnnotation(t, _modal(_Rig()));
        expect(find.text(_removeThisCache), findsOneWidget);
      });
    });

    group('User Interactions', () {
      testWidgets('should enable editing for query and answer sections', (t) async {
        await renderAnnotation(t, _modal(_Rig()));
        expect(find.text(_edit), findsNWidgets(2));
      });

      testWidgets('should show remove option when annotationId is provided', (t) async {
        await renderAnnotation(t, _modal(_Rig()));
        expect(find.text(_removeThisCache), findsOneWidget);
      });
    });

    group('API Calls', () {
      testWidgets('should call editAnnotation when updating existing annotation', (t) async {
        final rig = _Rig();
        await renderAnnotation(t, _modal(rig, messageId: 'test-message-id'));
        await _editFirst(t, 'Modified query');
        expect(rig.edits, [
          (id: 'test-annotation-id', question: 'Modified query', answer: 'Test answer', messageId: 'test-message-id'),
        ]);
      });
    });

    group('State Management', () {
      testWidgets('should initialize with closed confirm modal', (t) async {
        await renderAnnotation(t, _modal(_Rig()));
        expect(find.text(_removeConfirm), findsNothing);
      });

      testWidgets('should show confirm modal when remove is clicked', (t) async {
        await renderAnnotation(t, _modal(_Rig()));
        await t.tap(find.text(_removeThisCache));
        await settle(t);
        expect(find.text(_removeConfirm), findsOneWidget);
      });

      testWidgets('should call onRemove when removal is confirmed', (t) async {
        final rig = _Rig();
        await renderAnnotation(t, _modal(rig));
        await t.tap(find.text(_removeThisCache));
        await settle(t);
        await tapInDialog(t, 'common.operation.confirm');
        expect(rig.removed, 1);
      });

      testWidgets('should hide confirm modal when removal is cancelled', (t) async {
        await renderAnnotation(t, _modal(_Rig()));
        await t.tap(find.text(_removeThisCache));
        await settle(t);
        expect(find.text(_removeConfirm), findsOneWidget);
        await tapInDialog(t, 'common.operation.cancel');
        expect(find.text(_removeConfirm), findsNothing);
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle empty query and answer', (t) async {
        await renderAnnotation(t, _modal(_Rig(), query: '', answer: ''));
        expect(find.text('appAnnotation.editModal.title'), findsOneWidget);
      });

      testWidgets('should handle very long content', (t) async {
        final longQuery = 'Q' * 1000, longAnswer = 'A' * 1000;
        await renderAnnotation(t, _modal(_Rig(), query: longQuery, answer: longAnswer));
        expect(find.text(longQuery), findsOneWidget);
        expect(find.text(longAnswer), findsOneWidget);
      });

      testWidgets('should handle special characters in content', (t) async {
        const specialQuery = 'Query with & < > " \' characters', specialAnswer = 'Answer with & < > " \' characters';
        await renderAnnotation(t, _modal(_Rig(), query: specialQuery, answer: specialAnswer));
        expect(find.text(specialQuery), findsOneWidget);
        expect(find.text(specialAnswer), findsOneWidget);
      });

      testWidgets('should handle onlyEditResponse prop', (t) async {
        await renderAnnotation(t, _modal(_Rig(), onlyEditResponse: true));
        expect(find.text(_edit), findsOneWidget);
      });
    });

    group('Error Handling', () {
      testWidgets('should show error toast and skip callbacks when editAnnotation fails', (t) async {
        final rig = _Rig()..error = Exception('API Error');
        await renderAnnotation(t, _modal(rig, messageId: 'test-message-id'));
        await _editFirst(t, 'Modified query');
        expect(rig.toast.has(DifyToastType.error, 'API Error'), isTrue);
        expect(rig.edited, isEmpty);
        expect(find.byType(TextField), findsOneWidget);
        expect(button(_save), findsOneWidget);
      });

      testWidgets('should show fallback error message when editAnnotation error is not an Error instance', (t) async {
        final rig = _Rig()..error = 'oops';
        await renderAnnotation(t, _modal(rig, messageId: 'test-message-id'));
        await _editFirst(t, 'Modified query');
        expect(rig.toast.has(DifyToastType.error, 'common.api.actionFailed'), isTrue);
        expect(rig.edited, isEmpty);
        expect(find.byType(TextField), findsOneWidget);
        expect(button(_save), findsOneWidget);
      });
    });

    group('Billing & Plan Features', () {
      testWidgets('should show createdAt time when provided', (t) async {
        await renderAnnotation(t, _modal(_Rig(), createdAt: 1701381000));
        expect(find.textContaining('2023-12-01 10:30:00'), findsOneWidget);
      });

      testWidgets('should not show createdAt when not provided', (t) async {
        await renderAnnotation(t, _modal(_Rig()));
        expect(find.textContaining('2023-12-01 10:30:00'), findsNothing);
      });

      testWidgets('should display remove section when annotationId exists', (t) async {
        await renderAnnotation(t, _modal(_Rig()));
        expect(find.text(_removeThisCache), findsOneWidget);
      });
    });

    group('Toast Notifications', () {
      testWidgets('should show success notification when save operation completes', (t) async {
        final rig = _Rig();
        await renderAnnotation(t, _modal(rig));
        await _editFirst(t, 'Updated query');
        expect(rig.toast.has(DifyToastType.success, 'common.api.actionSuccess'), isTrue);
      });
    });

    group('React.memo Performance', () {
      testWidgets('should re-render when props change', (t) async {
        final rig = _Rig();
        await renderAnnotation(t, _modal(rig));
        await rerenderAnnotation(t, _modal(rig, query: 'New query content'));
        expect(find.text('New query content'), findsOneWidget);
      });
    });
  });

  group('EditTitle', () {
    testWidgets('shows the field title', (t) async {
      await renderAnnotation(t, const AnnotationEditTitle(title: 'Query'));
      expect(find.text('Query'), findsOneWidget);
    });
  });

  group('EditItem', () {
    Widget item({bool readonly = false, required Future<void> Function(String) onSave}) => AnnotationEditItem(
      type: EditItemType.query,
      content: 'Original content',
      readonly: readonly,
      onSave: onSave,
    );

    Future<void> startEditing(WidgetTester t) async {
      await t.tap(find.text(_edit));
      await settle(t);
    }

    testWidgets('does not offer editing in readonly mode', (t) async {
      await renderAnnotation(t, item(readonly: true, onSave: (_) async {}));
      expect(find.text(_edit), findsNothing);
    });

    testWidgets('saves updated content', (t) async {
      final saved = <String>[];
      await renderAnnotation(t, item(onSave: (c) async => saved.add(c)));
      await startEditing(t);
      await t.enterText(find.byType(TextField), 'Updated content');
      await tapButton(t, _save);
      expect(saved, ['Updated content']);
    });

    testWidgets('cancels editing without saving', (t) async {
      final saved = <String>[];
      await renderAnnotation(t, item(onSave: (c) async => saved.add(c)));
      await startEditing(t);
      await tapButton(t, 'common.operation.cancel');
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Original content'), findsOneWidget);
      expect(saved, isEmpty);
    });

    testWidgets('can restore the original content after saving an edit', (t) async {
      final saved = <String>[];
      await renderAnnotation(t, item(onSave: (c) async => saved.add(c)));
      await startEditing(t);
      await t.enterText(find.byType(TextField), 'Updated content');
      await tapButton(t, _save);
      await t.tap(find.text('common.operation.delete'));
      await settle(t);
      expect(saved, ['Updated content', 'Original content']);
    });

    testWidgets('keeps editing available when saving fails', (t) async {
      await renderAnnotation(t, item(onSave: (_) async => throw Exception('Save failed')));
      await startEditing(t);
      await t.enterText(find.byType(TextField), ' updated');
      await tapButton(t, _save);
      expect(find.byType(TextField), findsOneWidget);
      expect(button(_save), findsOneWidget);
    });
  });
}
