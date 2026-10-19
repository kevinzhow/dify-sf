import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show CheckedState, Tristate;

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/annotations/annotation_types.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/form_controls.dart' show DifyCheckbox;
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_test_i18n.dart';

/// Dify's render for the annotation specs: [child] with Dify's test translator (`<ns>.<key>`), the app's toast host
/// and the [locale] (`useLocale`), on a 1440 x 900 page.
Future<void> renderAnnotation(WidgetTester t, Widget child, {String locale = 'en-US'}) async {
  useDifyTestTranslator();
  t.view.physicalSize = const Size(1440, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(_app(child, locale));
  await settle(t);
}

/// The same app around another [child] (React's `rerender`).
Future<void> rerenderAnnotation(WidgetTester t, Widget child, {String locale = 'en-US'}) async {
  await t.pumpWidget(_app(child, locale));
  await settle(t);
}

final _locales = <String, AppLocale>{};

Widget _app(Widget child, String locale) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Material(child: child),
  builder: (context, c) => AppLocaleScope(
    locale: _locales.putIfAbsent(locale, () => AppLocale(locale, loader: (_) async {})),
    child: Stack(
      fit: StackFit.expand,
      children: [
        c!,
        const DifyToastHost(timeout: Duration.zero),
      ],
    ),
  ),
);

/// Lets futures, transitions and effects run.
Future<void> settle(WidgetTester t, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// The button whose semantics label is [label].
SemanticsFinder button(String label) => find.semantics.byPredicate(
  (n) => n.getSemanticsData().flagsCollection.isButton && n.label == label,
  describeMatch: (_) => 'button "$label"',
);

/// Taps the button labelled [label] through its semantics tap action (as a screen reader would); with several, the
/// last (an open dialog's, over the page).
Future<void> tapButton(WidgetTester t, String label, {int? index}) async {
  final nodes = button(label).evaluate().toList();
  if (nodes.isEmpty) {
    // A button whose name merges its icon: click its text.
    await t.tap(find.text(label).last);
    await settle(t);
    return;
  }
  final node = nodes[index ?? nodes.length - 1];
  node.owner!.performAction(node.id, SemanticsAction.tap);
  await settle(t);
}

/// Whether the button labelled [label] is enabled.
bool isEnabled(String label) =>
    button(label).evaluate().first.getSemanticsData().flagsCollection.isEnabled == Tristate.isTrue;

/// The checkbox whose semantics label is [label]: checked or not.
SemanticsFinder checkbox(String label) => find.semantics.byPredicate(
  (n) => n.getSemanticsData().flagsCollection.isChecked != CheckedState.none && n.label == label,
  describeMatch: (_) => 'checkbox "$label"',
);

/// Clicks the checkbox named [label].
Future<void> tapCheckbox(WidgetTester t, String label) async {
  await t.tap(find.byWidgetPredicate((w) => w is DifyCheckbox && w.label == label));
  await settle(t);
}

/// Types [text] into the text field shown with [placeholder] (its hint).
Future<void> typeInto(WidgetTester t, String placeholder, String text) async {
  final field = find.ancestor(of: find.text(placeholder), matching: find.byType(TextField));
  await t.enterText(field.first, text);
  await settle(t, 2);
}

/// The text of the field shown with [placeholder].
String fieldText(WidgetTester t, String placeholder) => t
    .widget<TextField>(find.ancestor(of: find.text(placeholder), matching: find.byType(TextField)).first)
    .controller!
    .text;

/// The toasts shown, as Dify's `toast.<type>(message)` calls.
class ToastLog {
  final calls = <({DifyToastType type, String message})>[];
  void call(DifyToastType type, String message) => calls.add((type: type, message: message));
  bool has(DifyToastType type, String message) => calls.any((c) => c.type == type && c.message == message);
}

/// An annotation (Dify's `createAnnotation`).
Annotation annotation({
  String id = 'annotation-1',
  String question = 'Question 1',
  String answer = 'Answer 1',
  int createdAt = 1700000000,
  int hitCount = 0,
}) => Annotation(id: id, question: question, answer: answer, createdAt: createdAt, hitCount: hitCount);

/// [AnnotationServices] as Dify's specs mock `@/service/annotation`: every call is recorded and answers what the
/// test set (a value, or a throwing callback).
class MockAnnotationServices implements AnnotationServices {
  final calls = <String, List<Object?>>{};

  void _rec(String name, Object? args) => (calls[name] ??= []).add(args);
  int count_(String name) => calls[name]?.length ?? 0;

  AnnotationListPage<Annotation> Function(int page, int limit, String keyword) listResult = (_, _, _) =>
      (data: const <Annotation>[], total: 0);
  Future<int> Function() countResult = () async => 0;
  Future<Annotation> Function(AnnotationItemBasic) addResult = (p) async =>
      Annotation(id: 'new', question: p.question, answer: p.answer);
  Future<void> Function() editResult = () async {};
  Future<void> Function() deleteResult = () async {};
  Future<void> Function() deleteManyResult = () async {};
  Future<void> Function() clearAllResult = () async {};
  Future<List<Annotation>> Function() exportResult = () async => const [];
  Future<AnnotationJob> Function() batchImportResult = () async =>
      const AnnotationJob(jobId: 'job-1', jobStatus: AnnotationJobStatus.processing);
  final batchStatusResults = <AnnotationJob>[];
  final configResults = <AnnotationSetting>[];
  AnnotationSetting config = const AnnotationSetting(
    enabled: false,
    id: 'config-id',
    scoreThreshold: 0.5,
    embeddingProviderName: 'provider',
    embeddingModelName: 'model',
  );
  AnnotationJob statusJob = const AnnotationJob(jobId: 'job-1', jobStatus: AnnotationJobStatus.waiting);
  AnnotationJob jobStatusResult = const AnnotationJob(jobId: 'job-1', jobStatus: AnnotationJobStatus.completed);
  Future<AnnotationListPage<AnnotationHitHistory>> Function() hitResult = () async =>
      (data: const <AnnotationHitHistory>[], total: 0);

  @override
  Future<AnnotationListPage<Annotation>> list({required int page, required int limit, String keyword = ''}) async {
    _rec('list', (page: page, limit: limit, keyword: keyword));
    return listResult(page, limit, keyword);
  }

  @override
  Future<int> count() {
    _rec('count', null);
    return countResult();
  }

  @override
  Future<Annotation> add(AnnotationItemBasic payload) {
    _rec('add', payload);
    return addResult(payload);
  }

  @override
  Future<void> edit(String annotationId, {required String question, required String answer}) {
    _rec('edit', (id: annotationId, question: question, answer: answer));
    return editResult();
  }

  @override
  Future<void> delete(String annotationId) {
    _rec('delete', annotationId);
    return deleteResult();
  }

  @override
  Future<void> deleteMany(List<String> ids) {
    _rec('deleteMany', ids);
    return deleteManyResult();
  }

  @override
  Future<void> clearAll() {
    _rec('clearAll', null);
    return clearAllResult();
  }

  @override
  Future<List<Annotation>> exportList() {
    _rec('exportList', null);
    return exportResult();
  }

  @override
  Future<AnnotationJob> batchImport(Uint8List csv, String fileName) {
    _rec('batchImport', (csv: csv, fileName: fileName));
    return batchImportResult();
  }

  @override
  Future<AnnotationJob> batchImportStatus(String jobId) async {
    _rec('batchImportStatus', jobId);
    return batchStatusResults.isEmpty ? statusJob : batchStatusResults.removeAt(0);
  }

  @override
  Future<AnnotationSetting> fetchConfig() async {
    _rec('fetchConfig', null);
    return configResults.isEmpty ? config : configResults.removeAt(0);
  }

  @override
  Future<AnnotationJob> updateStatus(
    AnnotationEnableStatus action,
    EmbeddingModelConfig? embeddingModel,
    double? score,
  ) async {
    _rec('updateStatus', (action: action, model: embeddingModel, score: score));
    return const AnnotationJob(jobId: 'job-1', jobStatus: AnnotationJobStatus.waiting);
  }

  @override
  Future<AnnotationJob> jobStatus(AnnotationEnableStatus action, String jobId) async {
    _rec('jobStatus', (action: action, jobId: jobId));
    return jobStatusResult;
  }

  @override
  Future<void> updateScore(String settingId, double score) async => _rec('updateScore', (id: settingId, score: score));

  @override
  Future<AnnotationListPage<AnnotationHitHistory>> hitHistories(
    String annotationId, {
    required int page,
    required int limit,
  }) {
    _rec('hitHistories', (id: annotationId, page: page, limit: limit));
    return hitResult();
  }
}

/// A future the test completes.
Completer<T> pending<T>() => Completer<T>();

/// Clicks the button with the text [label] in the open alert dialog.
Future<void> tapInDialog(WidgetTester t, String label) async {
  await t.tap(
    find.descendant(of: find.byKey(const ValueKey('annotation-alert-dialog')), matching: find.text(label)),
  );
  await settle(t);
}
