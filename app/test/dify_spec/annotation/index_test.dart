// dify-spec: web/app/components/app/annotation/__tests__/index.spec.tsx
import 'package:collab_client/collab_client.dart' show AnnotationSetting;
import 'package:dify_sf_app/src/app_detail/annotations/annotation_list.dart';
import 'package:dify_sf_app/src/app_detail/annotations/annotation_types.dart';
import 'package:dify_sf_app/src/app_detail/annotations/annotations_page.dart';
import 'package:dify_sf_app/src/app_detail/annotations/header_opts.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _success = 'common.api.actionSuccess';

AnnotationSetting _config({bool enabled = false}) => AnnotationSetting(
  enabled: enabled,
  id: 'config-id',
  scoreThreshold: 0.5,
  embeddingProviderName: 'provider',
  embeddingModelName: 'model',
);

class _Rig {
  final services = MockAnnotationServices()..config = _config();
  final toast = ToastLog();
}

/// The page with Dify's mocked view modal and config modal (buttons calling their callbacks).
Future<_Rig> _render(WidgetTester t, {_Rig? rig}) async {
  final r = rig ?? _Rig();
  await renderAnnotation(
    t,
    AnnotationsPage(
      services: r.services,
      toast: r.toast.call,
      debounce: Duration.zero,
      jobPollInterval: Duration.zero,
      saveFile: (_, _, _) async {},
      viewModal: (m) => SizedBox(
        height: 40,
        child: Row(
          key: const ValueKey('view-modal'),
          children: [
            Text(m.item.question),
            TextButton(key: const ValueKey('view-modal-remove'), onPressed: m.onRemove, child: const Text('remove')),
            TextButton(
              key: const ValueKey('view-modal-save'),
              onPressed: () => m.onSave('Edited question', 'Edited answer'),
              child: const Text('save'),
            ),
            TextButton(key: const ValueKey('view-modal-close'), onPressed: m.onHide, child: const Text('close')),
          ],
        ),
      ),
      configParamModal: (m) => Row(
        key: const ValueKey('config-modal'),
        children: [
          TextButton(
            key: const ValueKey('config-save'),
            onPressed: () => m.onSave((embeddingProviderName: 'next-provider', embeddingModelName: 'next-model'), 0.7),
            child: const Text('save-config'),
          ),
          TextButton(key: const ValueKey('config-hide'), onPressed: m.onHide, child: const Text('hide-config')),
        ],
      ),
    ),
  );
  return r;
}

AnnotationList _list(WidgetTester t) => t.widget<AnnotationList>(find.byType(AnnotationList));

Future<void> _tapKey(WidgetTester t, String key) async {
  await t.tap(find.byKey(ValueKey(key)));
  await settle(t);
}

void main() {
  group('Annotation', () {
    testWidgets('should render empty element when no annotations are returned', (t) async {
      final rig = await _render(t);
      expect(find.text('appAnnotation.title'), findsOneWidget);
      expect(find.text('appAnnotation.noData.description'), findsWidgets);
      final link = t.widget<Semantics>(
        find
            .ancestor(
              of: find.text('common.operation.learnMore'),
              matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.link == true),
            )
            .first,
      );
      expect(link.properties.linkUrl.toString(), 'https://docs.dify.ai/en/use-dify/monitor/annotation-reply');
      expect(find.byType(AnnotationEmptyElement), findsOneWidget);
      expect(rig.services.calls['list']!.first, (page: 1, limit: appPageLimit, keyword: ''));
    });

    testWidgets('should handle annotation creation and refresh list data', (t) async {
      final rig = _Rig();
      rig.services.listResult = (_, _, _) => (data: [annotation()], total: 1);
      await _render(t, rig: rig);
      expect(find.byType(AnnotationList), findsOneWidget);
      await t.widget<AnnotationHeaderOptions>(find.byType(AnnotationHeaderOptions)).onAdd((
        question: 'new question',
        answer: 'new answer',
      ));
      await settle(t);
      expect(rig.services.calls['add'], [(question: 'new question', answer: 'new answer')]);
      expect(rig.toast.has(DifyToastType.success, _success), isTrue);
      expect(rig.services.count_('list'), 2);
    });

    testWidgets('should support viewing items and running batch deletion success flow', (t) async {
      final rig = _Rig();
      final item = annotation();
      rig.services.listResult = (_, _, _) => (data: [item], total: 1);
      await _render(t, rig: rig);

      _list(t).onSelectedIdsChange([item.id]);
      await settle(t);
      expect(_list(t).selectedIds, [item.id]);

      await _list(t).onBatchDelete();
      await settle(t);
      expect(rig.services.calls['deleteMany'], [
        [item.id],
      ]);
      expect(rig.toast.has(DifyToastType.success, _success), isTrue);
      expect(_list(t).selectedIds, isEmpty);

      await t.tap(find.text(item.question));
      await settle(t);
      expect(find.byKey(const ValueKey('view-modal')), findsOneWidget);
      await _tapKey(t, 'view-modal-remove');
      expect(rig.services.calls['delete'], [item.id]);
    });

    testWidgets('should show an error notification when batch deletion fails', (t) async {
      final rig = _Rig();
      final item = annotation();
      rig.services
        ..listResult = ((_, _, _) => (data: [item], total: 1))
        ..deleteManyResult = (() async => throw Exception('failed'));
      await _render(t, rig: rig);
      _list(t).onSelectedIdsChange([item.id]);
      await settle(t);
      expect(_list(t).selectedIds, [item.id]);
      await _list(t).onBatchDelete();
      await settle(t);
      expect(rig.toast.calls, contains((type: DifyToastType.error, message: 'failed')));
      expect(_list(t).selectedIds, [item.id]);
    });

    testWidgets('should disable annotations and refetch config after the async job completes', (t) async {
      final rig = _Rig();
      rig.services.configResults.addAll([_config(enabled: true), _config()]);
      await _render(t, rig: rig);
      expect(find.byKey(const ValueKey('annotation-reply-switch-0')), findsOneWidget);
      expect(find.byTooltip('appAnnotation.initSetup.configTitle'), findsNothing);
      // Checked: the setup button shows next to the switch.
      expect(button('appAnnotation.initSetup.configTitle'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('annotation-reply-switch-0')));
      await settle(t);
      expect(rig.services.calls['updateStatus'], [
        (
          action: AnnotationEnableStatus.disable,
          model: (embeddingProviderName: 'provider', embeddingModelName: 'model'),
          score: 0.5,
        ),
      ]);
      expect(rig.services.calls['jobStatus'], [(action: AnnotationEnableStatus.disable, jobId: 'job-1')]);
      expect(rig.toast.has(DifyToastType.success, _success), isTrue);
    });

    testWidgets('should save annotation config changes and update the score when the modal confirms', (t) async {
      final rig = await _render(t);
      await t.tap(find.byKey(const ValueKey('annotation-reply-switch-0')));
      await settle(t);
      expect(find.byKey(const ValueKey('config-modal')), findsOneWidget);
      await _tapKey(t, 'config-save');
      expect(rig.services.calls['updateStatus'], [
        (
          action: AnnotationEnableStatus.enable,
          model: (embeddingProviderName: 'next-provider', embeddingModelName: 'next-model'),
          score: 0.7,
        ),
      ]);
      expect(rig.services.calls['updateScore'], [(id: 'config-id', score: 0.7)]);
      expect(rig.toast.has(DifyToastType.success, _success), isTrue);
    });

    testWidgets('should refresh the list from the header shortcut and allow saving or closing the view modal', (
      t,
    ) async {
      final rig = _Rig();
      final item = annotation();
      rig.services.listResult = (_, _, _) => (data: [item], total: 1);
      await _render(t, rig: rig);
      await t.tap(find.text(item.question));
      await settle(t);
      await _tapKey(t, 'view-modal-save');
      expect(rig.services.calls['edit'], [(id: item.id, question: 'Edited question', answer: 'Edited answer')]);

      await _tapKey(t, 'view-modal-close');
      expect(find.byKey(const ValueKey('view-modal')), findsNothing);

      final before = rig.services.count_('list');
      t.widget<AnnotationHeaderOptions>(find.byType(AnnotationHeaderOptions)).onAdded();
      await settle(t);
      expect(rig.services.count_('list'), greaterThan(before));
    });

    testWidgets('should clear selections on cancel and hide the config modal when requested', (t) async {
      final rig = _Rig();
      final item = annotation();
      rig.services
        ..config = _config(enabled: true)
        ..listResult = ((_, _, _) => (data: [item], total: 1));
      await _render(t, rig: rig);
      _list(t).onSelectedIdsChange([item.id]);
      await settle(t);
      _list(t).onSelectedIdsChange([]);
      await settle(t);
      expect(_list(t).selectedIds, isEmpty);

      await tapButton(t, 'appAnnotation.initSetup.configTitle');
      expect(find.byKey(const ValueKey('config-modal')), findsOneWidget);
      await _tapKey(t, 'config-hide');
      expect(find.byKey(const ValueKey('config-modal')), findsNothing);
    });
  });
}
