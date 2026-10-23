import 'dart:typed_data';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/bodies/llm_bodies.dart';
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/cards/card_chrome.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:dify_sf_app/src/canvas/canvas_graph.dart';
import 'package:dify_sf_app/src/cards/model_chip.dart';
import 'package:dify_sf_app/src/cards/provider_icon_image.dart';
import 'package:dify_sf_app/src/cards/node_body.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart' show DifyStatusDot, DifyTooltip;
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1 x 1 transparent PNG, standing in for provider icons.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);
final _icons = CachedProviderIconSource((_) async => ModelProviderIcon(bytes: _png, contentType: 'image/png'));

const _gpt = ModelItem(
  model: 'gpt-4o',
  label: {'en_US': 'GPT-4o'},
  features: [ModelFeatureEnum.toolCall, ModelFeatureEnum.vision, ModelFeatureEnum.document],
  modelProperties: {'mode': 'chat', 'context_size': 128000},
);

ModelItem _with(ModelItem m, {String? status, bool? deprecated, String? model}) => ModelItem(
  model: model ?? m.model,
  label: m.label,
  features: m.features,
  status: status ?? m.status,
  modelProperties: m.modelProperties,
  deprecated: deprecated ?? m.deprecated,
);

const _openai = ModelProvider(
  provider: 'langgenius/openai/openai',
  label: {'en_US': 'OpenAI'},
  customConfiguration: CustomConfiguration(
    status: 'active',
    currentCredentialId: 'c1',
    currentCredentialName: 'Key',
    availableCredentials: [Credential(credentialId: 'c1', credentialName: 'Key')],
  ),
);

/// A workspace with OpenAI installed and [models] listed for it.
ModelCatalog _catalog(
  List<ModelItem> models, {
  ModelProvider provider = _openai,
  I18nText? icon,
  String edition = 'COMMUNITY',
  TrialCredits credits = const TrialCredits(),
}) => ModelCatalog(
  providers: [provider],
  modelLists: {
    ModelTypeEnum.textGeneration: [
      ProviderWithModels(provider: provider.provider, label: provider.label, iconSmall: icon, models: models),
    ],
  },
  deploymentEdition: edition,
  trialCredits: credits,
  trialModels: [provider.provider],
);

const _value = (provider: 'langgenius/openai/openai', model: 'gpt-4o');

const _box = Key('box');

Future<void> _pump(WidgetTester t, Widget w, {double width = 214}) => t.pumpWidget(
  MaterialApp(
    home: Material(
      child: Align(
        alignment: Alignment.topLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [SizedBox(key: _box, width: width, child: w)],
        ),
      ),
    ),
  ),
);

Color? _bg(WidgetTester t) {
  final c = t.widget<Container>(
    find.descendant(of: find.byType(ModelSelectorTrigger), matching: find.byType(Container)).first,
  );
  return (c.decoration! as BoxDecoration).color;
}

TextStyle _style(WidgetTester t, String text) => t.widget<Text>(find.text(text)).style!;

bool _lineThrough(WidgetTester t, String text) => _style(t, text).decoration == TextDecoration.lineThrough;

Finder _remix(String name) => find.byWidgetPredicate((w) => w is RemixIcon && w.name == name);
Finder _dify(String name) => find.byWidgetPredicate((w) => w is DifyIcon && w.name == name);

Node _node(String type, Map<String, Value> config) => Node(id: 'n', type: type, config: config);

VMap _modelCfg(String provider, String name, {String key = 'name'}) =>
    VMap({'provider': VString(provider), key: VString(name), 'mode': const VString('chat')});

void main() {
  testWidgets('actual canvas cards follow the workspace model catalog without a document edit', (t) async {
    final graph = CanvasGraph(layoutOf: const DifyCards().layoutOf)
      ..sync(
        Document(
          nodes: [
            _node('llm', {'model': _modelCfg(_value.provider, _value.model)}),
          ],
        ),
      );
    final catalog = ValueNotifier(ModelCatalog.empty);
    final card = DifyNodeCard(node: graph['n']!, graph: graph, live: true);
    await _pump(
      t,
      ValueListenableBuilder(
        valueListenable: catalog,
        builder: (context, models, child) => LlmGroupScope(
          services: LlmGroupServices(models: models),
          child: child!,
        ),
        child: card,
      ),
      width: DifyCards.width,
    );
    expect(find.text('Incompatible'), findsOneWidget);
    final original = graph['n']!.node.value;

    catalog.value = _catalog([_gpt]);
    await t.pump();
    expect(find.text('Incompatible'), findsNothing);
    expect(find.text('CHAT'), findsOneWidget);
    expect(graph['n']!.node.value, same(original));

    catalog.value = _catalog([_with(_gpt, status: ModelStatusEnum.disabled)]);
    await t.pump();
    expect(t.widget<ModelSelectorTrigger>(find.byType(ModelSelectorTrigger)).status, DerivedModelStatus.disabled);
    expect(find.text('CHAT'), findsNothing);
    expect(graph['n']!.node.value, same(original));
    await t.pumpWidget(const SizedBox());
    catalog.dispose();
    graph.restingOrigin.dispose();
  });

  group('states', () {
    testWidgets('empty workspace: deprecated path, fallback icon, line-through id, Incompatible badge', (t) async {
      await _pump(t, const ModelChip(value: _value, models: []));
      expect(t.getSize(find.byType(ModelChip)).height, 24);
      expect(find.text('gpt-4o'), findsOneWidget);
      expect(_lineThrough(t, 'gpt-4o'), isTrue);
      expect(_style(t, 'gpt-4o').color, DifyColors.componentsInputTextFilled);
      expect(_style(t, 'gpt-4o').fontSize, 13);
      expect(find.text('Incompatible'), findsOneWidget);
      expect(_style(t, 'Incompatible').color, DifyColors.textWarning);
      expect(_remix('alert-fill'), findsOneWidget);
      expect(_dify('vender/other/group'), findsOneWidget);
      expect(_bg(t), DifyColors.componentsInputBgDisabled);
      expect(find.text('CHAT'), findsNothing);
      expect(find.byType(DifyTooltip), findsNothing, reason: 'no trigger tooltip for this chip');
      // The badge: dimm background, warning border, 22 px.
      final badge = t.widget<Container>(
        find.descendant(of: find.byType(ModelStatusBadge), matching: find.byType(Container)).first,
      );
      final d = badge.decoration! as BoxDecoration;
      expect(d.color, DifyColors.componentsBadgeBgDimm);
      expect((d.border! as Border).top.color, DifyColors.textWarning);
      expect(t.getSize(find.byType(ModelStatusBadge)).height, 22);
    });

    testWidgets('active: label, mode and feature badges, normal background', (t) async {
      final c = _catalog([_gpt]);
      await _pump(t, ModelChip(value: _value, models: c.textGenerationModelList, catalog: c));
      expect(find.text('GPT-4o'), findsOneWidget);
      expect(_lineThrough(t, 'GPT-4o'), isFalse);
      expect(find.text('CHAT'), findsOneWidget);
      expect(_remix('image-circle-ai-line'), findsOneWidget);
      expect(_remix('file-text-line'), findsOneWidget);
      expect(find.byType(FeatureIcon), findsNWidgets(2)); // tool-call draws nothing
      expect(t.getSize(find.byType(FeatureIcon).first), const Size(18, 18));
      expect(find.byType(ModelStatusBadge), findsNothing);
      expect(_bg(t), DifyColors.componentsInputBgNormal);
      expect(_remix('arrow-down-s-line'), findsNothing); // disabled
      expect(t.getSize(find.byType(ModelChip)).height, 24);
    });

    testWidgets('active and enabled: the arrow', (t) async {
      final c = _catalog([_gpt]);
      await _pump(t, ModelChip(value: _value, models: c.textGenerationModelList, catalog: c, disabled: false));
      expect(_remix('arrow-down-s-line'), findsOneWidget);
    });

    testWidgets('deprecated model in the list: line-through label, meta kept', (t) async {
      final c = _catalog([_with(_gpt, deprecated: true)]);
      await _pump(t, ModelChip(value: _value, models: c.textGenerationModelList, catalog: c));
      expect(_lineThrough(t, 'GPT-4o'), isTrue);
      expect(find.text('CHAT'), findsOneWidget);
    });

    for (final (status, derived) in const [
      (ModelStatusEnum.noConfigure, 'Configure required'),
      (ModelStatusEnum.disabled, 'Disabled'),
      (ModelStatusEnum.noPermission, 'Incompatible'),
      (ModelStatusEnum.credentialRemoved, 'API Key unavailable'),
      (ModelStatusEnum.quotaExceeded, 'Credits exhausted'),
    ]) {
      testWidgets('$status: no meta, disabled background, badge only when enabled', (t) async {
        final c = _catalog([_with(_gpt, status: status)]);
        await _pump(t, ModelChip(value: _value, models: c.textGenerationModelList, catalog: c));
        expect(find.text('GPT-4o'), findsOneWidget);
        expect(find.text('CHAT'), findsNothing);
        expect(find.byType(FeatureIcon), findsNothing);
        expect(find.byType(ModelStatusBadge), findsNothing);
        expect(_bg(t), DifyColors.componentsInputBgDisabled);
        expect(t.getSize(find.byType(ModelChip)).height, 24);

        await _pump(t, ModelChip(value: _value, models: c.textGenerationModelList, catalog: c, disabled: false));
        expect(find.text(derived), findsOneWidget);
        expect(_remix('arrow-down-s-line'), findsNothing);
        expect(t.getSize(find.byType(ModelChip)).height, 24);
      });
    }

    testWidgets('credits exhausted on Cloud with credits priority', (t) async {
      const system = ModelProvider(
        provider: 'langgenius/openai/openai',
        preferredProviderType: PreferredProviderTypeEnum.system,
        systemConfigurationEnabled: true,
      );
      final c = _catalog([_gpt], provider: system, edition: 'CLOUD');
      final chip = ModelChip(value: _value, models: c.textGenerationModelList, catalog: c, disabled: false);
      expect(chip.trigger.status, DerivedModelStatus.creditsExhausted);
      await _pump(t, chip);
      expect(find.text('Credits exhausted'), findsOneWidget);
      final badge = t.widget<ModelStatusBadge>(find.byType(ModelStatusBadge));
      expect(badge.dimm && badge.minWidth, isTrue);
      expect(_bg(t), DifyColors.componentsInputBgDisabled);
    });

    test('api key unavailable from the credential state', () {
      const bad = ModelProvider(
        provider: 'langgenius/openai/openai',
        customConfiguration: CustomConfiguration(
          currentCredentialName: 'Bad',
          availableCredentials: [Credential(credentialId: 'c1', credentialName: 'Bad')],
        ),
      );
      final c = _catalog([_gpt], provider: bad);
      expect(
        ModelChip(value: _value, models: c.textGenerationModelList, catalog: c).trigger.status,
        DerivedModelStatus.apiKeyUnavailable,
      );
    });

    testWidgets('provider icon, and OpenaiYellow for o-models', (t) async {
      final c = _catalog([_gpt, _with(_gpt, model: 'o3')], icon: const {'en_US': 'https://x/icon.png'});
      await _pump(
        t,
        ProviderIconScope(
          source: _icons,
          child: ModelChip(value: _value, models: c.textGenerationModelList, catalog: c),
        ),
      );
      await t.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(t.getSize(find.byType(Image)), const Size(16, 16));
      expect(t.getSize(find.byType(ModelIcon)), const Size(20, 20));
      await _pump(
        t,
        ModelChip(
          value: (provider: 'langgenius/openai/openai', model: 'o3'),
          models: c.textGenerationModelList,
          catalog: c,
        ),
      );
      expect(_dify('public/llm/openai-yellow'), findsOneWidget);
    });

    testWidgets('incompatible by predicate', (t) async {
      final c = _catalog([_gpt]);
      await _pump(
        t,
        ModelChip(
          value: _value,
          models: c.textGenerationModelList,
          catalog: c,
          disabled: false,
          modelPredicate: (_, _) => false,
        ),
      );
      expect(find.text('Incompatible'), findsOneWidget);
      expect(find.text('CHAT'), findsNothing);
    });

    testWidgets('empty: brain icon and placeholder', (t) async {
      await _pump(t, const ModelChip(value: null, models: []));
      expect(_remix('brain-2-line'), findsOneWidget);
      expect(find.text('Configure model'), findsOneWidget);
      expect(_style(t, 'Configure model').color, DifyColors.componentsInputTextPlaceholder);
      expect(_bg(t), DifyColors.componentsInputBgNormal);
    });
  });

  group('ModelBar', () {
    testWidgets('not installed: workflow surface, half opacity, no badge, error dot', (t) async {
      await _pump(t, const ModelBar(value: _value));
      expect(_bg(t), DifyColors.workflowBlockParmaBg);
      expect(find.byType(ModelStatusBadge), findsNothing);
      expect(_lineThrough(t, 'gpt-4o'), isTrue);
      expect(t.widget<Opacity>(find.ancestor(of: find.text('gpt-4o'), matching: find.byType(Opacity))).opacity, 0.5);
      expect(find.byType(DifyStatusDot), findsOneWidget);
      expect(t.getSize(find.byType(ModelBar)).height, 24);
    });

    testWidgets('installed: no dot, no dimming', (t) async {
      final c = _catalog([_gpt]);
      await _pump(t, ModelBar(value: _value, catalog: c));
      expect(find.byType(DifyStatusDot), findsNothing);
      expect(find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.5), findsNothing);
      expect(find.text('CHAT'), findsOneWidget);
      expect(_bg(t), DifyColors.workflowBlockParmaBg);
    });

    testWidgets('not selected: empty selector with the dot', (t) async {
      await _pump(t, const ModelBar());
      expect(find.text('Configure model'), findsOneWidget);
      expect(find.byType(DifyStatusDot), findsOneWidget);
      expect(_bg(t), DifyColors.workflowBlockParmaBg);
    });
  });

  group('body heights match', () {
    final catalogs = {
      'empty': ModelCatalog.empty,
      'active': _catalog([_gpt]),
      'no-configure': _catalog([_with(_gpt, status: ModelStatusEnum.noConfigure)]),
    };
    final nodes = <String, (NodeBody, Node)>{
      'llm': (const LlmBody(), _node('llm', {'model': _modelCfg('langgenius/openai/openai', 'gpt-4o')})),
      'llm unset': (const LlmBody(), _node('llm', {'model': _modelCfg('', '')})),
      'parameter-extractor': (
        const ParameterExtractorBody(),
        _node('parameter-extractor', {'model': _modelCfg('langgenius/openai/openai', 'gpt-4o')}),
      ),
      'question-classifier': (
        const QuestionClassifierBody(),
        _node('question-classifier', {
          'model': _modelCfg('langgenius/openai/openai', 'gpt-4o'),
          'classes': const VList([
            VMap({'id': VString('c1'), 'name': VString('Billing'), 'label': VString('Billing')}),
          ]),
        }),
      ),
      'agent': (
        const AgentBody(),
        _node('agent', {
          'agent_strategy_name': const VString('fc'),
          'agent_strategy_label': const VString('FunctionCalling'),
          'agent_parameters': VMap({
            'model': VMap({'value': _modelCfg('langgenius/openai/openai', 'gpt-4o', key: 'model')}),
            'model2': VMap({'value': _modelCfg('langgenius/openai/openai', 'o3', key: 'model')}),
          }),
        }),
      ),
    };
    for (final MapEntry(key: cn, value: catalog) in catalogs.entries) {
      for (final MapEntry(key: name, value: (body, node)) in nodes.entries) {
        testWidgets('$name / $cn', (t) async {
          final ctx = BodyContext(node, (_) => null, models: catalog);
          await _pump(t, Builder(builder: (c) => body.build(c, ctx)), width: 238);
          expect(t.getSize(find.byKey(_box)).height, body.height(ctx));
          expect(t.takeException(), isNull);
        });
      }
    }
  });
}
