// Emulator recheck of the phone polish (PR #89), small controls in node bodies, in a phone's settings sheet (411x914):
// the agent strategy trigger, the agent roster's "Change", the model selector's provider row; each a 44 dp node, all
// of it hittable. The model search's icon is no unlabelled button of its own.
import 'dart:async';

import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_provider_env.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_v2_roster.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/model_selector.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/dify_test_i18n.dart';
import '../dify_spec/workflow/nodes_panel/llm/model_fixtures.dart' show makeModel, named;
import '../support/model_fakes.dart';
import '../support/touch_targets.dart';
import 'phone_harness.dart' hide settle;

Future<void> _frames(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// [child] in a bottom sheet over a phone page (a node's settings are a sheet), with [services] in scope.
Future<void> _inSheet(WidgetTester t, Widget child, {LlmGroupServices services = LlmGroupServices.empty}) async {
  phoneWindow(t);
  final nav = GlobalKey<NavigatorState>();
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      navigatorKey: nav,
      home: const DifyPage(body: SizedBox.expand()),
    ),
  );
  unawaited(
    showDifyBottomSheet<void>(
      nav.currentContext!,
      (_) => LlmGroupScope(
        services: services,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [child]),
        ),
      ),
    ),
  );
  await _frames(t);
}

Map<String, Object?> _strategyProvider(String name, String strategy, String label) => {
  'provider': name,
  'plugin_unique_identifier': '$name:1.0.0',
  'plugin_id': name,
  'declaration': {
    'identity': {
      'author': 'provider',
      'name': name,
      'label': {'en_US': '$name label'},
    },
    'strategies': [
      {
        'identity': {
          'name': strategy,
          'author': 'provider',
          'label': {'en_US': label},
        },
        'description': {'en_US': '$label description'},
        'parameters': const <Object?>[],
        'output_schema': const <String, Object?>{},
        'features': const <String>[],
      },
    ],
  },
  'meta': {'version': '1.0.0'},
};

void main() {
  setUp(useDifyTestTranslator);

  testWidgets('the agent strategy trigger ("Select agentic strategy") is a 44 dp target', (t) async {
    final semantics = t.ensureSemantics();
    await _inSheet(
      t,
      AgentStrategySelector(onChange: (_) {}),
      services: LlmGroupServices(strategyProviders: [_strategyProvider('alpha', 'alpha-strategy', 'Alpha')]),
    );
    await expectTouchTarget(t, named('workflow.nodes.agent.strategy.selectTip').evaluate().single, 'strategy');
    expect(t.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('the agent roster\'s "Change" is a 44 dp target', (t) async {
    final semantics = t.ensureSemantics();
    await _inSheet(
      t,
      AgentRosterField(onChange: (_) {}),
      services: LlmGroupServices(
        agentInviteOptions: (_) async => const [
          {'id': 'agent-1', 'name': 'Roster Agent', 'role': 'Analyst', 'active_config_snapshot_id': 'snapshot-1'},
        ],
      ),
    );
    await expectTouchTarget(t, named('workflow.nodes.agent.roster.change').evaluate().single, 'roster');
    expect(t.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('the model selector sheet: the provider row is a 44 dp target; the search icon is no unlabelled button', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    final provider = <String, Object?>{
      'provider': 'openai',
      'label': {'en_US': 'OpenAI'},
      'supported_model_types': ['llm'],
      'configurate_methods': ['predefined-model'],
      'provider_credential_schema': {'credential_form_schemas': <Object?>[]},
      'custom_configuration': {'status': 'active'},
    };
    final api = RecordingModelsApi()
      ..summaryData = [provider]
      ..providersData = [provider];
    final models = WorkspaceModels(api, fixedLanguage: 'en_US');
    addTearDown(models.dispose);
    await models.refreshSummary();
    await _inSheet(
      t,
      ModelSelector(value: null, models: [makeModel()]),
      services: LlmGroupServices(
        models: ModelCatalog(providers: models.providers),
        modelProviderEnv: ModelProviderEnv(models: models, permissionKeys: const ['credential.use']),
      ),
    );
    await t.tap(named('plugin.detailPanel.configureModel'));
    await _frames(t);
    // The provider row's toggle (its name).
    await expectTouchTarget(t, named('OpenAI').evaluate().single, 'the provider row');
    // No tappable node without a name in the sheet (the search icon was one).
    final unnamed = <String>[];
    void walk(SemanticsNode n) {
      final d = n.getSemanticsData();
      if (!n.isMergedIntoParent &&
          d.hasAction(SemanticsAction.tap) &&
          d.label.isEmpty &&
          d.value.isEmpty &&
          !d.flagsCollection.isTextField) {
        unnamed.add('${n.rect}');
      }
      n.visitChildren((c) {
        walk(c);
        return true;
      });
    }

    walk(t.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
    expect(unnamed, isEmpty, reason: 'tappable nodes without a name');
    expect(t.takeException(), isNull);
    semantics.dispose();
  });
}
