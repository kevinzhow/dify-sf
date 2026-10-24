// The Annotations page (app_detail/annotations) on the in-memory protocol 1.11 server (FakeAnnotationsApi): what a
// chatflow's annotations look like end to end, through the real list, drawers, menus and dialogs.
import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/annotations/annotation_types.dart';
import 'package:dify_sf_app/src/app_detail/annotations/annotations_page.dart';
import 'package:dify_sf_app/src/app_detail/annotations/batch_add_modal.dart';
import 'package:dify_sf_app/src/app_detail/annotations/header_opts.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart' show ModelTypeEnum;
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/annotation/harness.dart';
import 'support/model_fakes.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

const _openai = 'langgenius/openai/openai';

class _World {
  _World._(this.apps, this.api, this.appId);

  final FakeAppsApi apps;
  final FakeAnnotationsApi api;
  final String appId;
  final toast = ToastLog();
  final saved = <({String name, String content})>[];
  AnnotationCsvFile? picked;

  static Future<_World> create({String mode = AppModes.advancedChat}) async {
    final apps = FakeAppsApi(clock: () => DateTime.utc(2026, 10, 19, 8, 30));
    final app = await apps.create(name: 'Support bot', mode: mode);
    return _World._(apps, FakeAnnotationsApi(apps), app.id);
  }

  AnnotationServices get services => AnnotationsApiServices(api, appId);
}

class _FailedIndexApi extends FakeAnnotationsApi {
  _FailedIndexApi(super.apps);
  bool needsRebuild = false;
  int rebuilds = 0;
  @override
  Future<AnnotationSetting> setting(String appId) async {
    final current = await super.setting(appId);
    return needsRebuild
        ? AnnotationSetting(
            enabled: false,
            id: current.id,
            scoreThreshold: current.scoreThreshold,
            embeddingProviderName: current.embeddingProviderName,
            embeddingModelName: current.embeddingModelName,
          )
        : current;
  }

  @override
  Future<AnnotationJob> enableReply(
    String appId, {
    required double scoreThreshold,
    required String embeddingProviderName,
    required String embeddingModelName,
  }) async {
    rebuilds++;
    needsRebuild = false;
    return super.enableReply(
      appId,
      scoreThreshold: scoreThreshold,
      embeddingProviderName: embeddingProviderName,
      embeddingModelName: embeddingModelName,
    );
  }
}

WorkspaceModels _models() => WorkspaceModels(
  RecordingModelsApi()
    ..modelsByType[ModelTypeEnum.textEmbedding] = [
      providerWithModels(_openai, ['text-embedding-3-small'], modelType: ModelTypeEnum.textEmbedding),
    ]
    ..defaults[ModelTypeEnum.textEmbedding] = defaultModelJson(
      _openai,
      'text-embedding-3-small',
      modelType: ModelTypeEnum.textEmbedding,
    ),
  fixedLanguage: 'en_US',
);

Future<void> _render(WidgetTester t, _World w, {WorkspaceModels? models}) => renderAnnotation(
  t,
  AnnotationsPage(
    services: w.services,
    models: models,
    toast: w.toast.call,
    debounce: Duration.zero,
    jobPollInterval: Duration.zero,
    saveFile: (name, content, _) async => w.saved.add((name: name, content: content)),
    pickCsv: () async => w.picked,
  ),
);

Future<void> _add(WidgetTester t, String q, String a) async {
  await tapButton(t, 'appAnnotation.table.header.addAnnotation');
  await typeInto(t, 'appAnnotation.addModal.queryPlaceholder', q);
  await typeInto(t, 'appAnnotation.addModal.answerPlaceholder', a);
  await tapButton(t, 'common.operation.add');
}

Future<void> _more(WidgetTester t, String item) async {
  await t.tap(find.byKey(const ValueKey('annotation-more')));
  await settle(t);
  await t.tap(find.text(item));
  await settle(t);
}

void main() {
  testWidgets('without an API the page shows the title and Dify\'s empty state', (t) async {
    await renderAnnotation(t, const AnnotationsPage(services: null));
    expect(find.text('appAnnotation.title'), findsOneWidget);
    expect(find.byType(AnnotationEmptyElement), findsOneWidget);
    expect(find.text('appAnnotation.name'), findsNothing);
  });

  testWidgets('add, search, view and edit, remove, batch delete and clear all on the server', (t) async {
    final w = await _World.create();
    await _render(t, w);
    expect(find.byType(AnnotationEmptyElement), findsOneWidget);

    await _add(t, 'What is dify-sf?', 'A collaborative editor.');
    expect(w.toast.has(DifyToastType.success, 'common.api.actionSuccess'), isTrue);
    await _add(t, 'Who hosts it?', 'You do.');
    expect((await w.api.list(w.appId)).total, 2);
    expect(find.text('What is dify-sf?'), findsOneWidget);
    expect(find.text('Who hosts it?'), findsOneWidget);

    // Search goes to the server (question or answer, case-insensitive).
    await t.enterText(find.descendant(of: find.byType(AnnotationFilter), matching: find.byType(EditableText)), 'HOSTS');
    await settle(t);
    expect(find.text('Who hosts it?'), findsOneWidget);
    expect(find.text('What is dify-sf?'), findsNothing);
    await tapButton(t, 'common.operation.clear');
    expect(find.text('What is dify-sf?'), findsOneWidget);

    // View drawer: edit the answer.
    await t.tap(find.text('Who hosts it?'));
    await settle(t);
    expect(find.text('appAnnotation.viewModal.annotatedResponse'), findsWidgets);
    await t.tap(find.text('common.operation.edit').last);
    await settle(t);
    await t.enterText(find.byType(TextField).last, 'Anyone, on their own server.');
    await tapButton(t, 'common.operation.save');
    expect((await w.api.export(w.appId)).map((a) => a.answer), contains('Anyone, on their own server.'));
    // Hit history is empty until a runtime matches annotations.
    await t.tap(find.text('appAnnotation.viewModal.hitHistory'));
    await settle(t);
    expect(find.text('appAnnotation.viewModal.noHitHistory'), findsOneWidget);
    await tapButton(t, 'common.operation.close');

    // Batch delete the checked row.
    await tapCheckbox(t, 'Who hosts it?');
    expect(find.text('appAnnotation.batchAction.selected'), findsOneWidget);
    await tapButton(t, 'common.operation.delete');
    await tapInDialog(t, 'common.operation.delete');
    expect((await w.api.list(w.appId)).total, 1);
    expect(find.text('Who hosts it?'), findsNothing);

    // Clear all.
    await _more(t, 'appAnnotation.table.header.clearAll');
    await tapInDialog(t, 'common.operation.confirm');
    expect((await w.api.list(w.appId)).total, 0);
    expect(find.byType(AnnotationEmptyElement), findsOneWidget);
  });

  testWidgets('bulk import a CSV, then export it as CSV and JSONL', (t) async {
    final w = await _World.create();
    w.picked = (
      name: 'faq.csv',
      bytes: utf8.encode('question,answer\nq1,a1\n"q, 2","a ""2"""\n'),
    );
    await _render(t, w);
    await _more(t, 'appAnnotation.table.header.bulkImport');
    await tapButton(t, 'appAnnotation.batchModal.browse');
    expect(find.text('faq'), findsOneWidget);
    await tapButton(t, 'appAnnotation.batchModal.run');
    expect(w.toast.has(DifyToastType.success, 'appAnnotation.batchModal.completed'), isTrue);
    expect(find.text('appAnnotation.batchModal.title'), findsNothing);
    expect(find.text('q1'), findsOneWidget);
    expect(find.text('q, 2'), findsOneWidget);
    // As in Dify, the export list is refetched when an annotation is added or removed from the page, not after an
    // import: add one.
    await _add(t, 'q3', 'a3');

    await t.tap(find.byKey(const ValueKey('annotation-more')));
    await settle(t);
    await t.tap(find.text('appAnnotation.table.header.bulkExport'));
    await settle(t);
    await t.tap(find.text('CSV'));
    await settle(t);
    expect(w.saved.last.name, 'annotations-en-US.csv');
    expect(w.saved.last.content, AnnotationFiles.csv(await w.api.export(w.appId)));
    expect(w.saved.last.content, contains('"q, 2","a ""2"""'));

    await t.tap(find.byKey(const ValueKey('annotation-more')));
    await settle(t);
    await t.tap(find.text('appAnnotation.table.header.bulkExport'));
    await settle(t);
    await t.tap(find.text('JSONL'));
    await settle(t);
    expect(w.saved.last.name, 'annotations-en-US.jsonl');
    expect(w.saved.last.content.split('\n'), hasLength(3));
  });

  testWidgets('a refused import shows Dify\'s run error with the server\'s message', (t) async {
    final w = await _World.create();
    w.picked = (name: 'empty.csv', bytes: utf8.encode('question,answer\n'));
    await _render(t, w);
    await _more(t, 'appAnnotation.table.header.bulkImport');
    await tapButton(t, 'appAnnotation.batchModal.browse');
    await tapButton(t, 'appAnnotation.batchModal.run');
    expect(
      w.toast.calls.where((c) => c.type == DifyToastType.error).single.message,
      startsWith('appAnnotation.batchModal.runError: '),
    );
  });

  testWidgets('Annotation Reply: set up with an embedding model and a score, change the score, disable', (t) async {
    final w = await _World.create();
    final models = _models();
    addTearDown(models.dispose);
    await _render(t, w, models: models);
    await settle(t);

    await t.tap(find.byType(DifySwitch));
    await settle(t);
    expect(find.text('appAnnotation.initSetup.title'), findsOneWidget);
    await tapButton(t, 'appAnnotation.initSetup.confirmBtn');
    var setting = await w.api.setting(w.appId);
    expect(setting.enabled, isTrue);
    expect(setting.embeddingProviderName, _openai);
    expect(setting.embeddingModelName, 'text-embedding-3-small');
    expect(setting.scoreThreshold, annotationDefaultScoreThreshold);

    // Setup again: a new score only (the same model: no re-embedding job).
    await tapButton(t, 'appAnnotation.initSetup.configTitle');
    expect(find.text('appAnnotation.initSetup.configTitle'), findsWidgets);
    t.widget<DifySlider>(find.byType(DifySlider)).onChanged!(95);
    await settle(t);
    await tapButton(t, 'appAnnotation.initSetup.configConfirmBtn');
    setting = await w.api.setting(w.appId);
    expect(setting.enabled, isTrue);
    expect(setting.scoreThreshold, 0.95);

    // Disable.
    await t.tap(find.byType(DifySwitch));
    await settle(t);
    expect((await w.api.setting(w.appId)).enabled, isFalse);
  });

  testWidgets('a failed or legacy index explicitly rebuilds even with the same model and score', (t) async {
    final apps = FakeAppsApi();
    final app = await apps.create(name: 'Needs rebuild', mode: AppModes.advancedChat);
    final api = _FailedIndexApi(apps);
    await api.enableReply(
      app.id,
      scoreThreshold: annotationDefaultScoreThreshold,
      embeddingProviderName: _openai,
      embeddingModelName: 'text-embedding-3-small',
    );
    api.needsRebuild = true;
    api.rebuilds = 0;
    final w = _World._(apps, api, app.id);
    final models = _models();
    addTearDown(models.dispose);
    await _render(t, w, models: models);
    await settle(t);
    await t.tap(find.byType(DifySwitch));
    await settle(t);
    await tapButton(t, 'appAnnotation.initSetup.confirmBtn');
    expect(api.rebuilds, 1);
    expect((await api.setting(app.id)).enabled, isTrue);
  });

  testWidgets('workflow apps have no annotations: the server answers Dify\'s wrong-mode error', (t) async {
    final w = await _World.create(mode: AppModes.workflow);
    expect(
      () => w.services.list(page: 1, limit: 10),
      throwsA(isA<TransportException>().having((e) => e.code, 'code', 'app_not_found')),
    );
  });
}
