// Polish item 7: the pickers built by node bodies (retrieval settings, the JSON schema generator, the agent roster,
// strategy and tool selectors, the human input's member, style and delivery method choices, metadata conditions, the
// tool's date) open as sheets on phones through DifyFloating's one compact switch (bfd1daaf), and Android back closes
// them; an input's typeahead (the recipient's member suggestions) stays anchored. A field in a picker sheet does not
// take the focus at once (the agent roster's search opened the keyboard over its list). At 411x914 with gesture insets.
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart' show DifyI18n;
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/delivery_method.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/email_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_kit.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/user_action.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_date_pickers.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_v2_roster.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_metadata.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_retrieval_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/llm_json_schema.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/dify_test_i18n.dart';
import '../dify_spec/workflow/nodes_panel/llm/kr_fixtures.dart' show createCondition, createDataset, createMetadata;
import '../dify_spec/workflow/nodes_panel/llm/model_fixtures.dart' show named;
import 'phone_harness.dart' hide settle;

final _scrims = find.byKey(const ValueKey('dify-sheet-scrim'));

/// The test translator with Dify's en-US words for [_words]: a row of buttons laid out for real labels (the
/// generator's Cancel / Generate) does not fit their i18n keys in the test font.
class _WordsTranslator extends DifyTestTranslator {
  static const _words = {
    'common.operation.cancel': 'Cancel',
    'workflow.nodes.llm.jsonSchema.generate': 'Generate',
  };

  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      _words['$ns.$key'] ?? super.t(ns, key, params);
}

const _members = [
  HiMember(id: 'member-1', email: 'member-1@example.com', name: 'Member One'),
  HiMember(id: 'member-2', email: 'member-2@example.com', name: 'Member Two'),
];

Future<void> _frames(WidgetTester t, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// [child] in a phone page, as a node panel's field would be.
Future<void> _pump(WidgetTester t, Widget child, {LlmGroupServices services = LlmGroupServices.empty}) async {
  phoneWindow(t);
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      home: DifyPage(
        body: LlmGroupScope(
          services: services,
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(padding: const EdgeInsets.all(16), child: child),
          ),
        ),
      ),
    ),
  );
  await _frames(t);
}

/// A bottom sheet across the window (the scrim, the grab handle 411 wide), no anchored popup and (unless
/// [noKeyboard] is false) no keyboard.
void _isSheet(WidgetTester t, String what, {int sheets = 1, bool noKeyboard = true}) {
  expect(_scrims, findsNWidgets(sheets), reason: '$what: the scrim');
  final handle = t.getRect(find.byType(DifySheetGrabHandle).last);
  expect(handle.width, 411, reason: '$what: a bottom sheet across the window');
  expect(find.byType(DifyFloatingLayout), findsNothing, reason: '$what: not an anchored popup');
  if (noKeyboard) expect(t.testTextInput.isVisible, isFalse, reason: '$what: no keyboard');
}

/// Taps [trigger], checks [what] opened as a sheet showing [content], and that Android back closes it.
Future<void> _opensAsSheet(
  WidgetTester t,
  Finder trigger,
  String what, {
  required Finder content,
  bool noKeyboard = true,
}) async {
  expect(content, findsNothing, reason: '$what: closed at first');
  await t.tap(trigger);
  await _frames(t);
  _isSheet(t, what, noKeyboard: noKeyboard);
  expect(content, findsWidgets, reason: '$what: its content in the sheet');
  expect(await t.binding.handlePopRoute(), isTrue, reason: '$what: back is handled');
  await _frames(t);
  expect(_scrims, findsNothing, reason: '$what: back closed it');
  expect(content, findsNothing, reason: '$what: back closed it');
  expect(t.takeException(), isNull);
}

MetadataShape _shape() => MetadataShape(
  metadataList: [
    createMetadata(),
    createMetadata({'id': 'meta-2', 'name': 'permission'}),
  ],
  selectedDatasetsLoaded: true,
  conditions: {
    'logical_operator': 'and',
    'conditions': [createCondition()],
  },
  onAddCondition: (_) {},
  onRemoveCondition: (_) {},
  onToggleLogicalOperator: () {},
  onUpdateCondition: (_, _) {},
);

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

  testWidgets('knowledge retrieval\'s Retrieval Settings open as a sheet; back closes them', (t) async {
    var open = false; // The node body holds the open state.
    await _pump(
      t,
      StatefulBuilder(
        builder: (context, setOpen) => RetrievalConfig(
          retrievalMode: 'multiple',
          multipleRetrievalConfig: const {'top_k': 3, 'score_threshold': null},
          onRetrievalModeChange: (_) {},
          onMultipleRetrievalConfigChange: (_) {},
          open: open,
          onOpenChange: (v) => setOpen(() => open = v),
          selectedDatasets: [createDataset()],
        ),
      ),
    );
    await _opensAsSheet(
      t,
      find.text('dataset.retrievalSettings'),
      'retrieval settings',
      content: find.byType(ConfigRetrievalContent),
    );
  });

  testWidgets('the LLM\'s JSON schema generator opens as a sheet; back closes it', (t) async {
    DifyI18n.current = _WordsTranslator();
    await _pump(t, JsonSchemaGenerator(onApply: (_) {}));
    await _opensAsSheet(
      t,
      named('workflow.nodes.llm.jsonSchema.generateJsonSchema'),
      'JSON schema generator',
      content: find.text('workflow.nodes.llm.jsonSchema.generationTip'),
    );
  });

  Future<void> pumpRoster(WidgetTester t) => _pump(
    t,
    SizedBox(width: 379, child: AgentRosterField(onChange: (_) {})),
    services: LlmGroupServices(
      agentInviteOptions: (_) async => const [
        {'id': 'agent-1', 'name': 'Roster Agent', 'role': 'Analyst', 'active_config_snapshot_id': 'snapshot-1'},
      ],
    ),
  );

  testWidgets('the agent roster\'s "Change" opens the agent selector as a sheet without the keyboard (its search '
      'asked for the focus at once); back closes it', (t) async {
    await pumpRoster(t);
    await _opensAsSheet(
      t,
      named('workflow.nodes.agent.roster.change'),
      'agent roster selector',
      content: find.byType(AgentSelectorContent),
    );
  });

  testWidgets('the agent strategy selector opens as a sheet; back closes it', (t) async {
    await _pump(
      t,
      SizedBox(width: 379, child: AgentStrategySelector(onChange: (_) {})),
      services: LlmGroupServices(
        strategyProviders: [
          _strategyProvider('alpha', 'alpha-strategy', 'Alpha Strategy'),
          _strategyProvider('beta', 'beta-strategy', 'Beta Strategy'),
        ],
      ),
    );
    await _opensAsSheet(
      t,
      named('workflow.nodes.agent.strategy.selectTip'),
      'agent strategy selector',
      content: find.text('Alpha Strategy'),
    );
  });

  testWidgets('the agent\'s tool selector ("Configure tool") opens as a sheet; back closes it', (t) async {
    await _pump(
      t,
      SizedBox(
        width: 379,
        child: AgentToolSelector(value: null, onSelect: (_) {}),
      ),
    );
    await _opensAsSheet(
      t,
      named('plugin.detailPanel.configureTool'),
      'agent tool selector',
      content: find.text('plugin.detailPanel.toolSelector.title'),
    );
  });

  testWidgets('the human input\'s member selector opens as a sheet; back closes it', (t) async {
    await _pump(
      t,
      MemberSelector(value: const [], email: 'owner@example.com', list: _members, onSelect: (_) {}),
    );
    await _opensAsSheet(
      t,
      named('workflow.nodes.humanInput.deliveryMethod.emailConfigure.memberSelector.trigger'),
      'member selector',
      content: find.byType(MemberList),
    );
  });

  testWidgets('the recipient input\'s member suggestions stay anchored to the input while typing', (t) async {
    await _pump(
      t,
      SizedBox(
        width: 379,
        child: EmailInput(
          email: 'owner@example.com',
          value: const [],
          list: _members,
          onDelete: (_) {},
          onSelect: (_) {},
          onAdd: (_) {},
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('email-input-box')));
    await _frames(t, 2);
    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey('email-input')), matching: find.byType(EditableText)),
      'member',
    );
    await _frames(t);
    expect(find.byType(MemberList), findsOneWidget, reason: 'the matching members show');
    expect(find.byType(DifyFloatingLayout), findsOneWidget, reason: 'an anchored popup');
    expect(_scrims, findsNothing, reason: 'not a sheet');
    expect(find.byType(DifySheetGrabHandle), findsNothing, reason: 'not a sheet');
    expect(t.testTextInput.isVisible, isTrue, reason: 'the keyboard stays up for the input');
    final input = t.getRect(find.byKey(const ValueKey('email-input')));
    final list = t.getRect(find.byType(MemberList));
    expect(list.top, greaterThanOrEqualTo(input.bottom), reason: 'below the input');
    expect(t.takeException(), isNull);
  });

  testWidgets('knowledge retrieval\'s metadata conditions open as a sheet, Add Condition as a second one over it; '
      'back closes them in order', (t) async {
    final added = <Map<String, Object?>>[];
    final shape = _shape();
    await _pump(
      t,
      MetadataTrigger(
        shape: MetadataShape(
          metadataList: shape.metadataList,
          selectedDatasetsLoaded: true,
          conditions: shape.conditions,
          onAddCondition: added.add,
          onRemoveCondition: (_) {},
          onToggleLogicalOperator: () {},
          onUpdateCondition: (_, _) {},
        ),
      ),
    );
    await t.tap(find.text('workflow.nodes.knowledgeRetrieval.metadata.panel.conditions'));
    await _frames(t);
    _isSheet(t, 'metadata conditions');
    expect(find.byType(MetadataPanel), findsOneWidget);
    await t.tap(find.text('workflow.nodes.knowledgeRetrieval.metadata.panel.add'));
    await _frames(t);
    _isSheet(t, 'add condition', sheets: 2);
    expect(find.text('permission'), findsOneWidget, reason: 'the metadata to add');
    expect(await t.binding.handlePopRoute(), isTrue);
    await _frames(t);
    expect(_scrims, findsOneWidget, reason: 'back closed Add Condition first');
    expect(find.text('permission'), findsNothing);
    expect(find.byType(MetadataPanel), findsOneWidget);
    // Opened again, a metadata row adds its condition and closes only Add Condition.
    await t.tap(find.text('workflow.nodes.knowledgeRetrieval.metadata.panel.add'));
    await _frames(t);
    _isSheet(t, 'add condition', sheets: 2);
    await t.tap(find.text('permission'));
    await _frames(t);
    expect(added.single, containsPair('id', 'meta-2'));
    expect(_scrims, findsOneWidget);
    expect(await t.binding.handlePopRoute(), isTrue);
    await _frames(t);
    expect(_scrims, findsNothing, reason: 'back closed the conditions');
    expect(find.byType(MetadataPanel), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('knowledge retrieval\'s Add Condition on its own opens as a sheet; back closes it', (t) async {
    await _pump(t, AddCondition(metadataList: _shape().metadataList, onAdd: (_) {}));
    await _opensAsSheet(
      t,
      find.text('workflow.nodes.knowledgeRetrieval.metadata.panel.add'),
      'add condition',
      content: find.text('permission'),
    );
  });

  testWidgets('the tool\'s date field opens its calendar as a sheet; back closes it', (t) async {
    await _pump(
      t,
      SizedBox(
        width: 379,
        child: ToolDatePicker(value: null, onChange: (_) {}),
      ),
    );
    await _opensAsSheet(t, named('time.operation.pickDate'), 'tool date', content: find.byType(DifyCalendar));
  });

  testWidgets('the human input\'s button style dropdown opens as a sheet; back closes it', (t) async {
    await _pump(t, ButtonStyleDropdown(text: 'Approve', value: 'primary', onChange: (_) {}));
    await _opensAsSheet(
      t,
      named('workflow.nodes.humanInput.userActions.chooseStyle'),
      'button style',
      content: find.text('workflow.nodes.humanInput.userActions.chooseStyle'),
    );
  });

  testWidgets('the human input\'s delivery method "+" opens the methods as a sheet; back closes it', (t) async {
    await _pump(
      t,
      MethodSelector(data: const [], onAdd: (_) {}, onShowUpgradeTip: () {}),
    );
    await _opensAsSheet(
      t,
      named('workflow.nodes.humanInput.deliveryMethod.title'),
      'delivery method',
      content: find.text('workflow.nodes.humanInput.deliveryMethod.types.webapp.title'),
    );
  });

  // ----- emulator recheck (item 5) -----

  /// The Containers around [f] that draw a card (a shadow).
  Iterable<Container> cardsAround(WidgetTester t, Finder f) => t
      .widgetList<Container>(find.ancestor(of: f, matching: find.byType(Container)))
      .where((c) => c.decoration is BoxDecoration && (c.decoration! as BoxDecoration).boxShadow != null);

  testWidgets('the delivery method sheet has no bordered card inside it (the sheet is the surface); a wide window '
      'keeps Dify\'s card', (t) async {
    final option = find.text('workflow.nodes.humanInput.deliveryMethod.types.webapp.title');
    await _pump(t, MethodSelector(data: const [], onAdd: (_) {}, onShowUpgradeTip: () {}));
    await t.tap(named('workflow.nodes.humanInput.deliveryMethod.title'));
    await _frames(t);
    _isSheet(t, 'delivery method');
    expect(cardsAround(t, option.first), isEmpty, reason: 'no card in the sheet');
    expect(t.takeException(), isNull);
    t.view.physicalSize = const Size(1280, 900);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: DifyPage(
          body: Align(
            alignment: Alignment.topCenter,
            child: MethodSelector(data: const [], onAdd: (_) {}, onShowUpgradeTip: () {}),
          ),
        ),
      ),
    );
    await _frames(t);
    await t.tap(named('workflow.nodes.humanInput.deliveryMethod.title'));
    await _frames(t);
    expect(cardsAround(t, option.first), isNotEmpty, reason: 'Dify\'s card in the popover');
  });

  testWidgets('the strategy sheet without an installed strategy says so: "No agent strategy available"', (t) async {
    await _pump(t, SizedBox(width: 379, child: AgentStrategySelector(onChange: (_) {})));
    await t.tap(named('workflow.nodes.agent.strategy.selectTip'));
    await _frames(t);
    _isSheet(t, 'agent strategy selector');
    expect(find.text('tools.addToolModal.agent.title'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
