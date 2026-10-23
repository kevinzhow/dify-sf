// dify-spec: web/app/components/app/annotation/__tests__/list.spec.tsx
// dify-spec: web/app/components/app/annotation/__tests__/batch-action.spec.tsx
import 'package:collab_client/collab_client.dart' show Annotation;
import 'package:dify_sf_app/src/app_detail/annotations/annotation_list.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Annotation _item({String id = 'annotation-id', String question = 'question 1'}) =>
    annotation(id: id, question: question, answer: 'answer 1', hitCount: 2);

/// `useTimestamp` mocked: every time is "formatted-time"; the calls are kept.
final _formatCalls = <(int, String)>[];
String _formatTime(int seconds, String format) {
  _formatCalls.add((seconds, format));
  return 'formatted-time';
}

Widget _list({
  required List<Annotation> list,
  ValueChanged<Annotation>? onView,
  ValueChanged<String>? onRemove,
  List<String> selectedIds = const [],
  ValueChanged<List<String>>? onSelectedIdsChange,
}) => SizedBox(
  height: 600,
  child: AnnotationList(
    list: list,
    onView: onView ?? (_) {},
    onRemove: onRemove ?? (_) {},
    selectedIds: selectedIds,
    onSelectedIdsChange: onSelectedIdsChange ?? (_) {},
    onBatchDelete: () async {},
    formatTime: _formatTime,
  ),
);

void main() {
  setUp(_formatCalls.clear);

  group('List', () {
    testWidgets('should render annotation rows and call onView when clicking a row', (t) async {
      final item = _item();
      final viewed = <Annotation>[];
      await renderAnnotation(t, _list(list: [item], onView: viewed.add));
      await t.tap(find.text(item.question));
      await settle(t);
      expect(viewed, [item]);
      expect(_formatCalls, contains((item.createdAt, 'appLog.dateTimeFormat')));
    });

    testWidgets('should toggle single and bulk selection states', (t) async {
      final list = [_item(id: 'a', question: 'A'), _item(id: 'b', question: 'B')];
      final changes = <List<String>>[];
      await renderAnnotation(t, _list(list: list, onSelectedIdsChange: changes.add));
      await tapCheckbox(t, 'A');
      expect(changes.last, ['a']);

      await rerenderAnnotation(t, _list(list: list, selectedIds: ['a'], onSelectedIdsChange: changes.add));
      await tapCheckbox(t, 'A');
      expect(changes.last, isEmpty);

      await tapCheckbox(t, 'common.operation.selectAll');
      expect(changes.last, ['a', 'b']);
    });

    testWidgets('should confirm before removing an annotation and expose batch actions', (t) async {
      final item = _item(id: 'to-delete', question: 'Delete me');
      final removed = <String>[];
      await renderAnnotation(t, _list(list: [item], selectedIds: [item.id], onRemove: removed.add));
      // The row's second action button: remove.
      await tapButton(t, 'appDebug.feature.annotation.remove');
      expect(find.text('appDebug.feature.annotation.removeConfirm'), findsOneWidget);
      await tapInDialog(t, 'common.operation.confirm');
      expect(removed, [item.id]);
      expect(find.text('appAnnotation.batchAction.selected'), findsOneWidget);
    });
  });

  group('BatchAction', () {
    Widget batch({Future<void> Function()? onBatchDelete, ValueChanged<List<String>>? onSelectedIdsChange}) =>
        AnnotationBatchAction(
          selectedIds: const ['1', '2', '3'],
          onBatchDelete: onBatchDelete ?? () async {},
          onSelectedIdsChange: onSelectedIdsChange ?? (_) {},
        );

    testWidgets('should show the selected count and clear selection through selection change', (t) async {
      final changes = <List<String>>[];
      await renderAnnotation(t, batch(onSelectedIdsChange: changes.add));
      expect(find.text('3'), findsOneWidget);
      expect(find.text('appAnnotation.batchAction.selected'), findsOneWidget);
      await tapButton(t, 'common.operation.cancel');
      expect(changes, [<String>[]]);
    });

    testWidgets('should confirm before running batch delete', (t) async {
      var deletes = 0;
      await renderAnnotation(t, batch(onBatchDelete: () async => deletes++));
      await tapButton(t, 'common.operation.delete');
      expect(find.text('appAnnotation.list.delete.title'), findsOneWidget);
      await tapInDialog(t, 'common.operation.delete');
      expect(deletes, 1);
    });

    testWidgets('should hide delete confirmation when cancel is clicked', (t) async {
      var deletes = 0;
      await renderAnnotation(t, batch(onBatchDelete: () async => deletes++));
      await tapButton(t, 'common.operation.delete');
      await tapInDialog(t, 'common.operation.cancel');
      expect(find.text('appAnnotation.list.delete.title'), findsNothing);
      expect(deletes, 0);
    });
  });
}
