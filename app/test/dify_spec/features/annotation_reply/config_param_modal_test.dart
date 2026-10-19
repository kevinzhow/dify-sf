// dify-spec: web/app/components/base/features/new-feature-panel/annotation-reply/__tests__/config-param-modal.spec.tsx
// dify-spec: web/app/components/base/features/new-feature-panel/annotation-reply/score-slider/__tests__/index.spec.tsx
import 'dart:async';

import 'package:collab_client/collab_client.dart' show AnnotationSetting;
import 'package:dify_sf_app/src/app_detail/annotations/annotation_types.dart';
import 'package:dify_sf_app/src/app_detail/annotations/config_param_modal.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../annotation/harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

const _defaultConfig = AnnotationSetting(
  enabled: false,
  id: 'test-id',
  scoreThreshold: 0.9,
  embeddingProviderName: 'openai',
  embeddingModelName: 'text-embedding-ada-002',
);

const _noModel = AnnotationSetting(enabled: false, id: 'test-id', scoreThreshold: 0.9);

/// The hook's answer (`useModelListAndDefaultModelAndCurrentProviderAndModel`): the models, the default, `currentModel`.
typedef _Hooks = ({List<ProviderWithModels> modelList, DefaultModel? defaultModel, bool currentModel});

const _Hooks _hooks = (
  modelList: [
    ProviderWithModels(
      provider: 'openai',
      models: [ModelItem(model: 'text-embedding-ada-002')],
    ),
  ],
  defaultModel: (provider: 'openai', model: 'text-embedding-ada-002'),
  currentModel: true,
);

class _Rig {
  final saves = <(EmbeddingModelConfig, double)>[];
  var hidden = 0;
  final toast = ToastLog();
  Completer<void>? saving;
}

/// The modal with Dify's mocked model selector: its value as text and a button selecting cohere / embed-english.
Widget _modal(
  _Rig rig, {
  bool isShow = true,
  bool isInit = false,
  AnnotationSetting config = _defaultConfig,
  _Hooks hooks = _hooks,
}) => AnnotationConfigParamModal(
  isShow: isShow,
  isInit: isInit,
  onHide: () => rig.hidden++,
  onSave: (model, score) async {
    rig.saves.add((model, score));
    await rig.saving?.future;
  },
  annotationConfig: config,
  embeddingModels: hooks.modelList,
  defaultEmbeddingModel: hooks.defaultModel,
  isDefaultModelValid: hooks.currentModel,
  toast: rig.toast.call,
  modelSelector: (value, onChange) => Column(
    key: const ValueKey('model-selector'),
    children: [
      Text('${value?.provider}/${value?.model}', key: const ValueKey('model-selector-value')),
      TextButton(
        key: const ValueKey('select-model'),
        onPressed: () => onChange((provider: 'cohere', model: 'embed-english')),
        child: const Text('Select'),
      ),
    ],
  ),
);

DifySlider _slider(WidgetTester t) => t.widget<DifySlider>(find.byType(DifySlider));

String _selected(WidgetTester t) => t.widget<Text>(find.byKey(const ValueKey('model-selector-value'))).data!;

Future<void> _save(WidgetTester t) async {
  await t.tap(find.textContaining('appAnnotation.initSetup.c').last);
  await settle(t);
}

void main() {
  group('ConfigParamModal', () {
    testWidgets('should not render when isShow is false', (t) async {
      await renderAnnotation(t, _modal(_Rig(), isShow: false));
      expect(find.textContaining('initSetup'), findsNothing);
    });

    testWidgets('should render init title when isInit is true', (t) async {
      await renderAnnotation(t, _modal(_Rig(), isInit: true));
      expect(find.text('appAnnotation.initSetup.title'), findsOneWidget);
    });

    testWidgets('should render config title when isInit is false', (t) async {
      await renderAnnotation(t, _modal(_Rig()));
      expect(find.text('appAnnotation.initSetup.configTitle'), findsOneWidget);
    });

    testWidgets('should render score slider', (t) async {
      await renderAnnotation(t, _modal(_Rig()));
      expect(find.byType(DifySlider), findsOneWidget);
    });

    testWidgets('should render model selector', (t) async {
      await renderAnnotation(t, _modal(_Rig()));
      expect(find.byKey(const ValueKey('model-selector')), findsOneWidget);
    });

    testWidgets('should render cancel and confirm buttons', (t) async {
      await renderAnnotation(t, _modal(_Rig(), isInit: true));
      expect(find.text('common.operation.cancel'), findsOneWidget);
      expect(find.text('appAnnotation.initSetup.confirmBtn'), findsOneWidget);
    });

    testWidgets('should display score threshold value', (t) async {
      await renderAnnotation(t, _modal(_Rig()));
      expect(_slider(t).value, 90);
    });

    testWidgets('should render configConfirmBtn when isInit is false', (t) async {
      await renderAnnotation(t, _modal(_Rig()));
      expect(find.text('appAnnotation.initSetup.configConfirmBtn'), findsOneWidget);
    });

    testWidgets('should call onSave with embedding model and score when save is clicked', (t) async {
      final rig = _Rig();
      await renderAnnotation(t, _modal(rig));
      await _save(t);
      expect(rig.saves, [((embeddingProviderName: 'openai', embeddingModelName: 'text-embedding-ada-002'), 0.9)]);
    });

    testWidgets('should show error toast when embedding model is not set', (t) async {
      final rig = _Rig();
      await renderAnnotation(
        t,
        _modal(rig, config: _noModel, hooks: (modelList: const [], defaultModel: null, currentModel: false)),
      );
      await _save(t);
      expect(rig.toast.has(DifyToastType.error, 'common.modelProvider.embeddingModel.required'), isTrue);
      expect(rig.saves, isEmpty);
    });

    testWidgets('should call onHide when cancel is clicked and not loading', (t) async {
      final rig = _Rig();
      await renderAnnotation(t, _modal(rig));
      await t.tap(find.text('common.operation.cancel'));
      await settle(t);
      expect(rig.hidden, 1);
    });

    testWidgets('should render slider with expected bounds and current value', (t) async {
      await renderAnnotation(t, _modal(_Rig()));
      final s = _slider(t);
      expect(s.min, 0);
      expect(s.max, 100);
      expect(s.value, 90);
    });

    testWidgets('should update embedding model when model selector is used', (t) async {
      await renderAnnotation(t, _modal(_Rig()));
      await t.tap(find.byKey(const ValueKey('select-model')));
      await settle(t);
      expect(_selected(t), 'cohere/embed-english');
    });

    testWidgets('should call onSave with updated score from annotation config', (t) async {
      final rig = _Rig();
      await renderAnnotation(
        t,
        _modal(
          rig,
          config: const AnnotationSetting(
            enabled: false,
            id: 'test-id',
            scoreThreshold: 0.95,
            embeddingProviderName: 'openai',
            embeddingModelName: 'text-embedding-ada-002',
          ),
        ),
      );
      await _save(t);
      expect(rig.saves.single.$1.embeddingProviderName, 'openai');
      expect(rig.saves.single.$2, 0.95);
    });

    testWidgets('should call onSave with updated model after model selector change', (t) async {
      final rig = _Rig();
      await renderAnnotation(t, _modal(rig));
      await t.tap(find.byKey(const ValueKey('select-model')));
      await settle(t);
      await _save(t);
      expect(rig.saves, [((embeddingProviderName: 'cohere', embeddingModelName: 'embed-english'), 0.9)]);
    });

    testWidgets('should use default model when annotation config has no embedding model', (t) async {
      await renderAnnotation(t, _modal(_Rig(), config: _noModel));
      expect(_selected(t), 'openai/text-embedding-ada-002');
    });

    testWidgets('should use ANNOTATION_DEFAULT score_threshold when config has no score_threshold', (t) async {
      await renderAnnotation(
        t,
        _modal(
          _Rig(),
          config: const AnnotationSetting(
            enabled: false,
            id: 'test-id',
            embeddingProviderName: 'openai',
            embeddingModelName: 'text-embedding-ada-002',
          ),
        ),
      );
      expect(_slider(t).value, 90);
    });

    testWidgets('should preserve zero score threshold instead of falling back to default', (t) async {
      final rig = _Rig();
      await renderAnnotation(
        t,
        _modal(
          rig,
          config: const AnnotationSetting(
            enabled: false,
            id: 'test-id',
            scoreThreshold: 0,
            embeddingProviderName: 'openai',
            embeddingModelName: 'text-embedding-ada-002',
          ),
        ),
      );
      expect(_slider(t).value, 0);
      await _save(t);
      expect(rig.saves.single.$2, 0);
    });

    testWidgets('should set loading state while saving', (t) async {
      final rig = _Rig()..saving = Completer<void>();
      await renderAnnotation(t, _modal(rig));
      await _save(t);
      // While loading, Cancel does not hide.
      await t.tap(find.text('common.operation.cancel'));
      await settle(t);
      expect(rig.hidden, 0);
      rig.saving!.complete();
      await settle(t);
      expect(rig.saves, hasLength(1));
    });

    testWidgets('should save updated score after slider changes', (t) async {
      final rig = _Rig();
      await renderAnnotation(t, _modal(rig));
      _slider(t).onChanged!(96);
      await settle(t);
      await _save(t);
      expect(rig.saves.single.$1.embeddingProviderName, 'openai');
      expect(rig.saves.single.$2, 0.96);
    });
  });

  group('ScoreSlider', () {
    testWidgets('should expose the business score instead of the internal percentage', (t) async {
      final handle = t.ensureSemantics();
      await renderAnnotation(t, AnnotationScoreSlider(value: 90, onChange: (_) {}));
      final s = _slider(t);
      expect(s.semanticLabel, 'appDebug.feature.annotation.scoreThreshold.title');
      expect(s.value, 90);
      expect(t.getSemantics(find.byType(DifySlider)).value, '0.90');
      expect(find.text('0.90'), findsOneWidget);
      handle.dispose();
    });
  });
}
