// dify-spec: web/app/components/app/annotation/header-opts/__tests__/index.spec.tsx
import 'dart:convert';

import 'package:dify_sf_app/src/app_detail/annotations/annotation_types.dart';
import 'package:dify_sf_app/src/app_detail/annotations/header_opts.dart';
import 'package:dify_sf_app/src/design/widgets/menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

class _Rig {
  final services = MockAnnotationServices();
  final added = <AnnotationItemBasic>[];
  var onAdded = 0;
  final saved = <({String name, String content, String mime})>[];
}

Widget _header(_Rig rig, {int controlUpdateList = 0}) => Align(
  alignment: Alignment.topRight,
  child: AnnotationHeaderOptions(
    services: rig.services,
    controlUpdateList: controlUpdateList,
    onAdd: (p) async => rig.added.add(p),
    onAdded: () => rig.onAdded++,
    saveFile: (name, content, mime) async => rig.saved.add((name: name, content: content, mime: mime)),
  ),
);

Future<_Rig> _render(WidgetTester t, {_Rig? rig, String locale = 'en-US'}) async {
  final r = rig ?? _Rig();
  await renderAnnotation(t, _header(r), locale: locale);
  return r;
}

Future<void> _openOperations(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('annotation-more')));
  await settle(t);
}

Future<void> _expandExport(WidgetTester t) async {
  await _openOperations(t);
  await t.tap(find.text('appAnnotation.table.header.bulkExport'));
  await settle(t);
}

DifyMenuItem _item(WidgetTester t, String text) =>
    t.widget<DifyMenuItem>(find.ancestor(of: find.text(text), matching: find.byType(DifyMenuItem)));

Future<void> _click(WidgetTester t, String text) async {
  await t.tap(find.text(text));
  await settle(t);
}

final _annotations = [annotation(question: 'Question 1', answer: 'Answer 1')];

void main() {
  group('HeaderOptions', () {
    testWidgets('should fetch annotations on mount and render enabled export actions when data exist', (t) async {
      final rig = _Rig()..services.exportResult = () async => _annotations;
      await _render(t, rig: rig);
      expect(rig.services.count_('exportList'), 1);
      await _expandExport(t);
      expect(_item(t, 'CSV').disabled, isFalse);
      expect(_item(t, 'JSONL').disabled, isFalse);
      await _click(t, 'CSV');
      expect(rig.saved.single.content, '﻿Question,Answer\r\nQuestion 1,Answer 1');
    });

    testWidgets('should trigger CSV download with locale-specific filename', (t) async {
      final rig = _Rig()..services.exportResult = () async => _annotations;
      await _render(t, rig: rig, locale: 'zh-Hans');
      await _expandExport(t);
      await _click(t, 'CSV');
      final file = rig.saved.single;
      expect(file.name, 'annotations-zh-Hans.csv');
      expect(file.mime, 'text/csv;charset=utf-8;');
      expect(file.content, '﻿问题,答案\r\nQuestion 1,Answer 1');
    });

    testWidgets('should disable export actions when there are no annotations', (t) async {
      final rig = await _render(t);
      await _expandExport(t);
      expect(_item(t, 'CSV').disabled, isTrue);
      expect(_item(t, 'JSONL').disabled, isTrue);
      expect(rig.saved, isEmpty);
    });

    testWidgets('should open the add annotation modal and forward the onAdd callback', (t) async {
      final rig = _Rig()..services.exportResult = () async => _annotations;
      await _render(t, rig: rig);
      await tapButton(t, 'appAnnotation.table.header.addAnnotation');
      expect(find.text('appAnnotation.addModal.title'), findsOneWidget);
      await typeInto(t, 'appAnnotation.addModal.queryPlaceholder', 'Integration question');
      await typeInto(t, 'appAnnotation.addModal.answerPlaceholder', 'Integration answer');
      await tapButton(t, 'common.operation.add');
      expect(rig.added, [(question: 'Integration question', answer: 'Integration answer')]);
    });

    testWidgets('should allow bulk import through the batch modal', (t) async {
      final rig = await _render(t);
      await _openOperations(t);
      await _click(t, 'appAnnotation.table.header.bulkImport');
      expect(find.text('appAnnotation.batchModal.title'), findsWidgets);
      await tapButton(t, 'appAnnotation.batchModal.cancel');
      expect(rig.onAdded, 0);
    });

    testWidgets('should trigger JSONL download with locale-specific filename', (t) async {
      final rig = _Rig()..services.exportResult = () async => _annotations;
      await _render(t, rig: rig, locale: 'zh-Hans');
      await _expandExport(t);
      await _click(t, 'JSONL');
      final file = rig.saved.single;
      expect(file.name, 'annotations-zh-Hans.jsonl');
      expect(file.mime, 'application/jsonl');
      final lines = file.content.trim().split('\n');
      expect(lines, hasLength(1));
      expect(jsonDecode(lines.single), {
        'messages': [
          {'role': 'system', 'content': ''},
          {'role': 'user', 'content': 'Question 1'},
          {'role': 'assistant', 'content': 'Answer 1'},
        ],
      });
    });

    testWidgets('should clear all annotations when confirmation succeeds', (t) async {
      final rig = await _render(t);
      await _openOperations(t);
      await _click(t, 'appAnnotation.table.header.clearAll');
      expect(find.text('appAnnotation.table.header.clearAllConfirm'), findsOneWidget);
      await tapInDialog(t, 'common.operation.confirm');
      expect(rig.services.count_('clearAll'), 1);
      expect(rig.onAdded, 1);
    });

    testWidgets('should handle clear all failures gracefully', (t) async {
      final logged = <String>[];
      final print = debugPrint;
      debugPrint = (m, {wrapWidth}) => logged.add('$m');
      final rig = _Rig()..services.clearAllResult = () async => throw Exception('network');
      await _render(t, rig: rig);
      await _openOperations(t);
      await _click(t, 'appAnnotation.table.header.clearAll');
      await tapInDialog(t, 'common.operation.confirm');
      expect(rig.services.count_('clearAll'), 1);
      debugPrint = print;
      expect(rig.onAdded, 0);
      expect(logged.any((m) => m.contains('failed to clear all annotations')), isTrue);
    });

    testWidgets('should refetch annotations when controlUpdateList changes', (t) async {
      final rig = await _render(t);
      expect(rig.services.count_('exportList'), 1);
      await rerenderAnnotation(t, _header(rig, controlUpdateList: 1));
      expect(rig.services.count_('exportList'), 2);
    });
  });
}
