// dify-spec: web/app/components/app/annotation/view-annotation-modal/__tests__/index.spec.tsx
import 'package:collab_client/collab_client.dart' show AnnotationHitHistory;
import 'package:dify_sf_app/src/app_detail/annotations/annotation_modals.dart';
import 'package:dify_sf_app/src/app_detail/annotations/annotation_types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

class _Rig {
  final saved = <(String, String)>[];
  var hidden = 0, removed = 0;
  final fetched = <(String, int)>[];
  final formatCalls = <int>[];
  AnnotationListPage<AnnotationHitHistory> hits = (data: const [], total: 0);
}

AnnotationHitHistory _hit({String id = 'hit-id', String question = 'query'}) => AnnotationHitHistory(
  id: id,
  question: question,
  match: 'match',
  response: 'response',
  source: 'source',
  score: 0.42,
  createdAt: 1700000000,
);

Future<_Rig> _render(WidgetTester t, {_Rig? rig}) async {
  final r = rig ?? _Rig();
  final item = annotation(id: 'annotation-id', question: 'question', answer: 'answer');
  await renderAnnotation(
    t,
    ViewAnnotationModal(
      isShow: true,
      item: item,
      onHide: () => r.hidden++,
      onSave: (q, a) async => r.saved.add((q, a)),
      onRemove: () async => r.removed++,
      fetchHitHistory: (id, page) async {
        r.fetched.add((id, page));
        return r.hits;
      },
      formatTime: (seconds, _) {
        r.formatCalls.add(seconds);
        return 'formatted-time';
      },
    ),
  );
  return r;
}

/// The edit item of [type] saving "[type]-updated" (Dify's spec mocks EditItem with such a button).
Future<void> _saveUpdated(WidgetTester t, EditItemType type) async {
  final item = t.widget<AnnotationEditItem>(
    find.byWidgetPredicate((w) => w is AnnotationEditItem && w.type == type),
  );
  await item.onSave('${type.name}-updated');
  await settle(t);
}

void main() {
  group('ViewAnnotationModal', () {
    testWidgets('should render annotation tab and allow saving updated query', (t) async {
      final rig = await _render(t);
      expect(rig.fetched, isNotEmpty);
      await _saveUpdated(t, EditItemType.query);
      expect(rig.saved, [('query-updated', 'answer')]);
    });

    testWidgets('should render annotation tab and allow saving updated answer', (t) async {
      final rig = await _render(t);
      expect(rig.fetched, isNotEmpty);
      await _saveUpdated(t, EditItemType.answer);
      expect(rig.saved, [('question', 'answer-updated')]);
    });

    testWidgets('should switch to hit history tab and show no data message', (t) async {
      final rig = await _render(t);
      expect(rig.fetched, isNotEmpty);
      await t.tap(find.text('appAnnotation.viewModal.hitHistory'));
      await settle(t);
      expect(find.text('appAnnotation.viewModal.noHitHistory'), findsOneWidget);
      expect(rig.formatCalls, contains(1700000000));
    });

    testWidgets('should render hit history entries with pagination badge when data exists', (t) async {
      final rig = _Rig()
        ..hits = (
          data: [
            _hit(question: 'user input'),
            _hit(id: 'hit-2', question: 'second'),
          ],
          total: 15,
        );
      await _render(t, rig: rig);
      await t.tap(find.text('appAnnotation.viewModal.hitHistory'));
      await settle(t);
      expect(find.text('user input'), findsOneWidget);
      // The badge upper-cases its text (Dify's `system-2xs-medium-uppercase` CSS transform).
      expect(find.text('15 appAnnotation.viewModal.hits'.toUpperCase()), findsOneWidget);
      expect(rig.formatCalls, contains(1700000000));
    });

    testWidgets('should confirm before removing the annotation and hide on success', (t) async {
      final rig = await _render(t);
      await t.tap(find.text('appAnnotation.editModal.removeThisCache'));
      await settle(t);
      expect(find.text('appDebug.feature.annotation.removeConfirm'), findsOneWidget);
      await tapInDialog(t, 'common.operation.confirm');
      expect(rig.removed, 1);
      expect(rig.hidden, 1);
    });

    testWidgets('should close the remove confirmation when cancelled', (t) async {
      await _render(t);
      await t.tap(find.text('appAnnotation.editModal.removeThisCache'));
      await settle(t);
      expect(find.text('appDebug.feature.annotation.removeConfirm'), findsOneWidget);
      await tapInDialog(t, 'common.operation.cancel');
      expect(find.text('appDebug.feature.annotation.removeConfirm'), findsNothing);
    });
  });
}
