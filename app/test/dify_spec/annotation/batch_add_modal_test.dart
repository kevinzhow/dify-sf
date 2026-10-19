// dify-spec: web/app/components/app/annotation/batch-add-annotation-modal/__tests__/index.spec.tsx
// dify-spec: web/app/components/app/annotation/batch-add-annotation-modal/__tests__/csv-uploader.spec.tsx
// dify-spec: web/app/components/app/annotation/batch-add-annotation-modal/__tests__/csv-downloader.spec.tsx
import 'dart:convert';
import 'dart:typed_data';

import 'package:collab_client/collab_client.dart' show AnnotationJob, AnnotationJobStatus;
import 'package:dify_sf_app/src/app_detail/annotations/batch_add_modal.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

AnnotationCsvFile _csv(String name, [String content = 'question,answer']) =>
    (name: name, bytes: Uint8List.fromList(utf8.encode(content)));

class _BatchRig {
  final services = MockAnnotationServices();
  var cancels = 0, added = 0;
  final toast = ToastLog();
  AnnotationCsvFile? lastUploaded;
}

/// The modal with Dify's mocked uploader: a button that picks "batch.csv", and the selected file's name.
Widget _batch(_BatchRig rig, {bool isShow = true}) => AnnotationBatchModal(
  isShow: isShow,
  services: rig.services,
  onCancel: () => rig.cancels++,
  onAdded: () => rig.added++,
  toast: rig.toast.call,
  pollInterval: const Duration(milliseconds: 2500),
  saveFile: (_, _, _) async {},
  uploader: (file, update) => Column(
    children: [
      TextButton(
        key: const ValueKey('mock-uploader'),
        onPressed: () => update(rig.lastUploaded = _csv('batch.csv')),
        child: const Text('upload'),
      ),
      if (file != null) Text(file.name, key: const ValueKey('selected-file')),
    ],
  ),
);

void main() {
  group('BatchModal', () {
    testWidgets('should reset uploader state when modal closes and allow manual cancellation', (t) async {
      final rig = _BatchRig();
      await renderAnnotation(t, _batch(rig));
      await t.tap(find.byKey(const ValueKey('mock-uploader')));
      await settle(t);
      expect(find.text('batch.csv'), findsOneWidget);

      await rerenderAnnotation(t, _batch(rig, isShow: false));
      await rerenderAnnotation(t, _batch(rig));
      expect(find.byKey(const ValueKey('selected-file')), findsNothing);

      await tapButton(t, 'appAnnotation.batchModal.cancel');
      expect(rig.cancels, 1);
    });

    testWidgets('should call onCancel when close button is clicked', (t) async {
      final rig = _BatchRig();
      await renderAnnotation(t, _batch(rig));
      await tapButton(t, 'common.operation.close');
      expect(rig.cancels, 1);
    });

    testWidgets('should submit the csv file, poll status, and notify when import completes', (t) async {
      final rig = _BatchRig();
      rig.services.batchImportResult = () async =>
          const AnnotationJob(jobId: 'job-1', jobStatus: AnnotationJobStatus.processing);
      rig.services.batchStatusResults.addAll(const [
        AnnotationJob(jobId: 'job-1', jobStatus: AnnotationJobStatus.processing),
        AnnotationJob(jobId: 'job-1', jobStatus: AnnotationJobStatus.completed),
      ]);
      await renderAnnotation(t, _batch(rig));
      await t.tap(find.byKey(const ValueKey('mock-uploader')));
      await settle(t);
      expect(isEnabled('appAnnotation.batchModal.run'), isTrue);

      await tapButton(t, 'appAnnotation.batchModal.run');
      expect(rig.services.count_('batchImport'), 1);
      final sent = rig.services.calls['batchImport']!.single! as ({Uint8List csv, String fileName});
      expect(sent.fileName, rig.lastUploaded!.name);
      expect(sent.csv, rig.lastUploaded!.bytes);
      expect(rig.services.count_('batchImportStatus'), 1);

      await t.pump(const Duration(milliseconds: 2500));
      await settle(t);
      expect(rig.services.count_('batchImportStatus'), 2);
      expect(rig.toast.has(DifyToastType.success, 'appAnnotation.batchModal.completed'), isTrue);
      expect(rig.added, 1);
      expect(rig.cancels, 1);
    });
  });

  group('CSVUploader', () {
    Future<({List<AnnotationCsvFile?> updates, CsvDrop drop, ToastLog toast, List<int> picks})> render(
      WidgetTester t, {
      AnnotationCsvFile? file,
    }) async {
      final updates = <AnnotationCsvFile?>[], picks = <int>[];
      final drop = CsvDrop(), toast = ToastLog();
      addTearDown(drop.dispose);
      await renderAnnotation(
        t,
        AnnotationCsvUploader(
          file: file,
          updateFile: updates.add,
          drop: drop,
          toast: toast.call,
          pickCsv: () async {
            picks.add(1);
            return _csv('selected.csv', 'row');
          },
        ),
      );
      return (updates: updates, drop: drop, toast: toast, picks: picks);
    }

    testWidgets('should open the file picker when clicking browse', (t) async {
      final r = await render(t);
      await tapButton(t, 'appAnnotation.batchModal.browse');
      expect(r.picks, hasLength(1));
    });

    testWidgets('should upload the dropped file', (t) async {
      final r = await render(t);
      final file = _csv('input.csv', 'content');
      r.drop
        ..dragEnter()
        ..drop([file]);
      await settle(t);
      expect(r.updates, [file]);
    });

    testWidgets('should handle drag over and clear dragging state when leaving through the overlay', (t) async {
      final r = await render(t);
      r.drop.dragEnter();
      await settle(t);
      expect(r.drop.dragging, isTrue);
      r.drop.dragLeave();
      await settle(t);
      expect(r.drop.dragging, isFalse);
    });

    testWidgets('should ignore drop events without dataTransfer', (t) async {
      final r = await render(t);
      r.drop.drop(null);
      await settle(t);
      expect(r.updates, isEmpty);
    });

    testWidgets('should show an error when multiple files are dropped', (t) async {
      final r = await render(t);
      r.drop.drop([_csv('a.csv', 'a'), _csv('b.csv', 'b')]);
      await settle(t);
      expect(r.toast.has(DifyToastType.error, 'datasetCreation.stepOne.uploader.validation.count'), isTrue);
      expect(r.updates, isEmpty);
    });

    testWidgets('should propagate file selection changes through input change event', (t) async {
      final r = await render(t);
      await tapButton(t, 'appAnnotation.batchModal.browse');
      expect(r.updates.single!.name, 'selected.csv');
    });

    testWidgets('should render selected file details and allow change/removal', (t) async {
      final r = await render(t, file: _csv('report.csv', 'data'));
      expect(find.text('report'), findsOneWidget);
      expect(find.text('.csv'), findsOneWidget);
      await t.tap(find.text('datasetCreation.stepOne.uploader.change'));
      await settle(t);
      expect(r.picks, hasLength(1));
      await tapButton(t, 'common.operation.delete');
      expect(r.updates.last, isNull);
    });
  });

  group('CSVDownload', () {
    Future<List<({String name, String content})>> render(WidgetTester t, String locale) async {
      final saved = <({String name, String content})>[];
      await renderAnnotation(
        t,
        AnnotationCsvDownloader(saveFile: (name, content, _) async => saved.add((name: name, content: content))),
        locale: locale,
      );
      return saved;
    }

    testWidgets('should render the structure preview and pass English template data by default', (t) async {
      final saved = await render(t, 'en-US');
      expect(find.text('share.generation.csvStructureTitle'), findsOneWidget);
      expect(find.text('appAnnotation.batchModal.template'), findsOneWidget);
      await t.tap(find.text('appAnnotation.batchModal.template'));
      await settle(t);
      expect(saved.single.name, 'template-en-US.csv');
      expect(saved.single.content, '﻿question,answer\r\nquestion1,answer1\r\nquestion2,answer2');
    });

    testWidgets('should switch to the Chinese template when locale matches the secondary language', (t) async {
      final saved = await render(t, 'zh-Hans');
      await t.tap(find.text('appAnnotation.batchModal.template'));
      await settle(t);
      expect(saved.single.name, 'template-zh-Hans.csv');
      expect(saved.single.content, '﻿问题,答案\r\n问题 1,答案 1\r\n问题 2,答案 2');
    });
  });
}
