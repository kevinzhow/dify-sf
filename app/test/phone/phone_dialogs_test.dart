// Dialogs as sheets on phones and row-based fields by touch (brief "dialogs"), at 411x914 and 360x780 with the
// system bars' insets: Start's Add / Edit Input Field (it bypassed the dialog route), Name this version, Select
// reference Knowledge, Email Configuration with a picker over it, Create from Blank; Start's input rows (tap edits,
// "…" and a long press: Edit, Delete with Dify's confirmation, Move up / down), and the other touch rows.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show CheckedState, SemanticsAction;

import 'package:collab_client/collab_client.dart' show Document, Edge, Node;
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart' show HistoryEvent;
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart' show nodeFromDify;
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/header/publisher/version_info_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/delivery_method.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/email_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_kit.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/user_action.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/data_common.dart' show DataPanelHost;
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_tables.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_v2_roster.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_datasets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/pe_params.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/next_step.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/workflow_steps_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import '../support/platform_semantics.dart';
import 'phone_harness.dart';

String _tc(String key) => DifyI18n.tr('common', key);

final _settings = find.byKey(const Key('node-settings-sheet'));
final _dialogHeader = find.byWidgetPredicate((w) => w is DifySheetHeader && w.title != 'Start');

/// The editor on a Start (query, request, attachment) → Answer (an LLM) → End (outputs query) flow.
Future<(EditorController, DemoBackend)> _editor(WidgetTester t, Size size) async {
  phoneWindow(t, size: size);
  final demo = DemoBackend(withBo: false);
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      home: EditorPage(backend: demo, docId: 'demo', clientId: 'phone-dialogs', journaled: false),
    ),
  );
  await settle(t, 2000);
  final c = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
  final nodes = <Node>[];
  void add(String id, String type, String title, Map<String, Object?> data) => nodes.add(
    nodeFromDify(
      {
        'id': id,
        'position': {'x': nodes.length * 300, 'y': 0},
        'data': {'type': type, 'title': title, ...data},
      },
      Document(nodes: nodes),
      id: id,
    ),
  );
  add('n-start', 'start', 'Start', {
    'variables': [
      {'variable': 'query', 'label': 'Query', 'type': 'text-input', 'required': true},
      {'variable': 'request', 'label': 'Request', 'type': 'paragraph', 'required': false},
      {'variable': 'attachment', 'label': 'Attachment', 'type': 'file', 'required': false},
    ],
  });
  add('n-llm', 'llm', 'Answer', {
    'model': {'provider': 'openai', 'name': 'gpt-4o', 'mode': 'chat', 'completion_params': <String, Object?>{}},
    'prompt_template': [
      {'role': 'system', 'text': 'Summarize {{#n-start.query#}} in one sentence.'},
    ],
    'context': {'enabled': false, 'variable_selector': <Object?>[]},
    'vision': {'enabled': false},
  });
  add('n-end', 'end', 'End', {
    'outputs': [
      {
        'variable': 'answer',
        'value_selector': ['n-start', 'query'],
      },
    ],
  });
  c.applyGraphChange(
    event: HistoryEvent.nodeAdd,
    removeNodes: [...c.doc.nodes.keys],
    addNodes: nodes,
    addEdges: [
      Edge(id: 'e-0', source: 'n-start', target: 'n-llm'),
      Edge(id: 'e-1', source: 'n-llm', target: 'n-end'),
    ],
  );
  c.selectNode(null);
  await settle(t, 800);
  return (c, demo);
}

Future<void> _close(WidgetTester t, DemoBackend demo) async {
  await unmount(t);
  await demo.dispose();
  await t.pump(const Duration(seconds: 20));
}

Future<void> _openStart(WidgetTester t) async {
  await t.tap(find.descendant(of: find.byType(WorkflowStepsView), matching: find.text('Start')).first);
  await settle(t, 800);
  expect(_settings, findsOneWidget);
}

/// The Start row of [variable] (its touch row).
Finder _row(String variable) =>
    find.descendant(of: find.byKey(ValueKey('start-var-$variable')), matching: find.byType(DifyActionRow)).first;

/// [button] (a DifyButton found by its label) is a 44 px button at the dialog sheet's bottom: above the gesture bar
/// (or [above], the keyboard's top), and within a button's height of it.
void _pinned(WidgetTester t, String label, Size size, {double? above}) {
  final r = t.getRect(find.widgetWithText(DifyButton, label).last);
  final floor = above ?? size.height - gestureInsets.bottom;
  expect(r.height, greaterThanOrEqualTo(44), reason: '$label: $r');
  expect(r.bottom, lessThanOrEqualTo(floor + 0.5), reason: '$label: $r over $floor');
  expect(r.bottom, greaterThan(floor - 24), reason: '$label at the bottom: $r over $floor');
}

/// Scrolls [f] to the middle of its scroll view (clear of the settings sheet's pinned header).
Future<void> _show(WidgetTester t, Finder f) async {
  await Scrollable.ensureVisible(t.element(f), alignment: 0.5);
  await settle(t, 300);
}

/// The touch row showing [text].
Finder _touchRow(String text) => find.ancestor(of: find.text(text), matching: find.byType(DifyActionRow)).first;

/// The dialog sheet's header shows [title] with a 44 px close.
void _header(WidgetTester t, String title) {
  expect(
    find.descendant(of: _dialogHeader, matching: find.text(title)),
    findsOneWidget,
    reason: title,
  );
  final close = find.descendant(of: _dialogHeader, matching: find.byType(DifyTouchIconButton));
  expect(t.getSize(close).height, greaterThanOrEqualTo(44));
}

/// A phone app showing [home] (a page with the hosts a dialog needs), real fonts and strings.
Future<GlobalKey<NavigatorState>> _app(WidgetTester t, Widget home, {Size size = const Size(411, 914)}) async {
  phoneWindow(t, size: size);
  final nav = GlobalKey<NavigatorState>();
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      navigatorKey: nav,
      home: DifyPage(edgeToEdge: true, body: home),
    ),
  );
  await settle(t, 300);
  return nav;
}

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in phoneSizes) {
    final name = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$name: Start "+" opens Add Input Field as a sheet over the settings (header, 44 px Cancel / Save at '
        'the bottom, above the keyboard); Save adds the field; Back closes the dialog first, then the settings', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      final (_, demo) = await _editor(t, size);
      await _openStart(t);
      await t.tap(find.bySemanticsLabel('Add Input Field').first);
      await settle(t, 800);
      _header(t, 'Add Input Field');
      _pinned(t, _tc('operation.save'), size);
      _pinned(t, _tc('operation.cancel'), size);

      // Only the dialog is read: not the settings sheet or the editor under it.
      final labels = platformLabels(t).join(' | ');
      expect(labels, contains('Add Input Field'));
      expect(labels, isNot(contains('Last Run')), reason: labels);
      expect(labels, isNot(contains('NEXT STEP')), reason: labels);

      // The keyboard: the variable name field takes it, the actions ride on it.
      final nameField = find
          .descendant(of: find.byKey(const Key('config-var-modal')), matching: find.byType(EditableText))
          .first;
      await t.tap(nameField);
      openKeyboard(t);
      await settle(t, 600);
      _pinned(t, _tc('operation.save'), size, above: size.height - 300);
      await t.enterText(nameField, 'city');
      // The label (Dify fills it from the name when the name field loses focus).
      final labelField = find
          .descendant(of: find.byKey(const Key('config-var-modal')), matching: find.byType(EditableText))
          .at(1);
      await t.enterText(labelField, 'City');
      closeKeyboard(t);
      await settle(t, 600);
      await t.tap(find.widgetWithText(DifyButton, _tc('operation.save')).last);
      await settle(t, 800);
      expect(find.byKey(const Key('config-var-modal')), findsNothing);
      expect(find.byKey(const ValueKey('start-var-city')), findsOneWidget, reason: 'the field was added');
      expect(_settings, findsOneWidget);

      await t.tap(find.bySemanticsLabel('Add Input Field').first);
      await settle(t, 800);
      expect(await systemBack(t), isTrue);
      await settle(t, 800);
      expect(find.byKey(const Key('config-var-modal')), findsNothing, reason: 'Back closed the dialog');
      expect(_settings, findsOneWidget, reason: 'the settings stay');
      expect(await systemBack(t), isTrue);
      await settle(t, 800);
      expect(_settings, findsNothing, reason: 'then Back closes the settings');
      expect(t.takeException(), isNull);
      semantics.dispose();
      await _close(t, demo);
    });

    testWidgets('$name: Start\'s input rows by touch: 48 px, one node each with a name; tap opens Edit Input Field '
        'as a sheet; "…" moves a row; a long press deletes one, with Dify\'s confirmation for a used variable', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      final (_, demo) = await _editor(t, size);
      await _openStart(t);
      for (final v in ['query', 'request', 'attachment']) {
        await _show(t, _row(v));
        expect(t.getSize(_row(v)).height, greaterThanOrEqualTo(48), reason: v);
      }
      expect(find.bySemanticsLabel('query, Query, Short Text, required'), findsOneWidget);
      expect(find.bySemanticsLabel('attachment, Attachment, Single File'), findsOneWidget);
      expect(platformLabels(t).where((l) => l.startsWith('Reorder')), isEmpty, reason: 'no hover handles');

      await _show(t, _row('request'));
      await t.tap(_row('request'));
      await settle(t, 800);
      _header(t, 'Edit Input Field');
      _pinned(t, _tc('operation.save'), size);
      await t.tap(find.widgetWithText(DifyButton, _tc('operation.cancel')).last);
      await settle(t, 800);
      expect(find.byKey(const Key('config-var-modal')), findsNothing);

      double top(String v) => t.getRect(find.byKey(ValueKey('start-var-$v'))).top;
      await _show(t, _row('request'));
      expect(top('request'), lessThan(top('attachment')));
      final more = find.byKey(const ValueKey('dify-action-row-more-attachment, Attachment, Single File'));
      await _show(t, more);
      expect(t.getSize(more), const Size(44, 44));
      await t.tap(more);
      await settle(t, 600);
      expect(find.text(_tc('operation.edit')), findsOneWidget);
      expect(find.text(_tc('operation.delete')), findsOneWidget);
      await t.tap(find.text('Move up'));
      await settle(t, 600);
      expect(top('attachment'), lessThan(top('request')), reason: 'moved up');

      await _show(t, _row('query'));
      await t.longPress(_row('query'));
      await settle(t, 600);
      await t.tap(find.text(_tc('operation.delete')));
      await settle(t, 800);
      // query is End's output: Dify confirms first, a centred confirmation (not a sheet).
      final confirm = find.byType(DifyAlertDialogContent);
      expect(confirm, findsOneWidget);
      final ok = find.descendant(of: confirm, matching: find.byType(DifyButton)).last;
      expect(t.getSize(ok).height, greaterThanOrEqualTo(44));
      await t.tap(ok);
      await settle(t, 800);
      expect(find.byKey(const ValueKey('start-var-query')), findsNothing, reason: 'deleted');
      expect(t.takeException(), isNull);
      semantics.dispose();
      await _close(t, demo);
    });
  }

  testWidgets('a sheet opened over a focused field takes the focus: the prompt\'s insert-variable button while '
      'typing closes the keyboard, the prompt behind gets no text, the list keeps its own nodes; a pick goes in at the '
      'caret and the prompt has the focus back', (t) async {
    final semantics = t.ensureSemantics();
    final (_, demo) = await _editor(t, const Size(411, 914));
    await t.tap(find.descendant(of: find.byType(WorkflowStepsView), matching: find.text('Answer')).first);
    await settle(t, 800);
    final editor = find.descendant(of: _settings, matching: find.byType(DifyPromptEditor)).first;
    await _show(t, editor);
    final state = t.state<DifyPromptEditorState>(editor);
    final field = find.descendant(of: editor, matching: find.byType(EditableText)).first;
    await t.tap(field);
    await settle(t, 300);
    state.controller.selection = const TextSelection.collapsed(offset: 10); // after "Summarize "
    await settle(t, 100);
    expect(t.testTextInput.isVisible, isTrue, reason: 'typing in the prompt');
    final before = state.controller.prompt;

    await t.tap(find.byKey(const Key('prompt-editor-insert')).first);
    await settle(t, 800);
    final sheet = find.byKey(const Key('prompt-editor-picker-sheet'));
    expect(sheet, findsOneWidget);
    expect(t.testTextInput.isVisible, isFalse, reason: 'the keyboard went down');
    expect(t.testTextInput.hasAnyClients, isFalse, reason: 'typing no longer reaches the prompt');
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'DifyPortalSheetFrame',
      reason: "the focus is in the sheet's scope",
    );
    await t.sendKeyEvent(LogicalKeyboardKey.keyX);
    expect(state.controller.prompt, before);
    final labels = platformLabels(t);
    expect(labels.where((l) => l.contains('request')), isNotEmpty, reason: '$labels');
    // Read in order: the title, the close, the search, then the rows.
    final title = labels.indexOf('Insert variable');
    expect(title, greaterThanOrEqualTo(0), reason: '$labels');
    final search = labels.indexWhere((l) => l.contains('Search variable'));
    expect(search, greaterThan(title), reason: '$labels');
    expect(labels.indexWhere((l) => l.contains('request')), greaterThan(search), reason: '$labels');
    expect(
      labels.where((l) => l.contains('Search variable') && l.contains('request')),
      isEmpty,
      reason: 'the list keeps its own nodes: $labels',
    );

    await t.tap(find.descendant(of: sheet, matching: find.text('request')).first);
    await settle(t, 800);
    expect(sheet, findsNothing);
    expect(state.controller.prompt, 'Summarize {{#n-start.request#}}{{#n-start.query#}} in one sentence.');
    expect(state.focusNode.hasFocus, isTrue, reason: 'the prompt has the focus back');
    expect(state.controller.selection, const TextSelection.collapsed(offset: 11), reason: 'after the new block');
    expect(t.takeException(), isNull);
    semantics.dispose();
    await _close(t, demo);
  });

  testWidgets('Name this version is a sheet: its title in the header, the fields, Cancel / Save pinned and 44 px; '
      'above the keyboard; Save hands the name over', (t) async {
    VersionInfoUpdate? saved;
    final nav = await _app(t, const SizedBox.expand());
    unawaited(showVersionInfoModal(nav.currentContext!, onPublish: (v) => saved = v));
    await settle(t, 600);
    _header(t, 'Name this version');
    _pinned(t, _tc('operation.save'), const Size(411, 914));
    final title = find.byType(EditableText).first;
    await t.tap(title);
    openKeyboard(t);
    await settle(t, 600);
    _pinned(t, _tc('operation.save'), const Size(411, 914), above: 914 - 300);
    await t.enterText(title, 'v1');
    await t.tap(find.widgetWithText(DifyButton, _tc('operation.save')));
    await settle(t, 600);
    expect(saved?.title, 'v1');
    expect(_dialogHeader, findsNothing);
  });

  testWidgets(
    'Select reference Knowledge is a sheet: the list scrolls between the header and the pinned Cancel / Add',
    (t) async {
      List<Map<String, Object?>>? picked;
      await _app(
        t,
        LlmGroupScope(
          services: LlmGroupServices(
            fetchDatasetPage: (page) async => (
              data: [
                for (var i = 0; i < 20; i++)
                  {
                    'id': 'd$i',
                    'name': 'Knowledge $i',
                    'indexing_technique': 'high_quality',
                    'embedding_available': true,
                    'data_source_type': 'upload_file',
                    'doc_form': 'text_model',
                    'retrieval_model_dict': {'search_method': 'semantic_search'},
                  },
              ],
              hasMore: false,
            ),
          ),
          child: Builder(
            builder: (context) => DifyButton(
              key: const ValueKey('open'),
              onPressed: () async => picked = await showSelectDataset(context, selectedIds: const []),
              child: const DifyTextLine('open'),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('open')));
      await settle(t, 800);
      _header(t, 'Select reference Knowledge');
      _pinned(t, _tc('operation.add'), const Size(411, 914));
      await t.tap(find.text('Knowledge 1'));
      await settle(t, 300);
      await t.tap(find.widgetWithText(DifyButton, _tc('operation.add')));
      await settle(t, 600);
      expect([for (final d in picked!) d['id']], ['d1']);
    },
  );

  testWidgets('Email Configuration is a sheet; the member picker over it hides the form from assistive technology; '
      'Back closes the picker, then the dialog', (t) async {
    final semantics = t.ensureSemantics();
    await _app(
      t,
      DataPanelHost(
        child: HumanInputHost(
          members: const [HiMember(id: 'm1', email: 'kim@example.com', name: 'Kim')],
          userEmail: 'owner@example.com',
          userName: 'Owner',
          workspaceName: 'Lab',
          child: Builder(
            builder: (context) => DifyButton(
              key: const ValueKey('open'),
              onPressed: () => showEmailConfigureModal(context, email: const EmailContext(nodeId: 'n')),
              child: const DifyTextLine('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('open')));
    await settle(t, 800);
    _header(t, 'Email Configuration');
    _pinned(t, _tc('operation.save'), const Size(411, 914));
    expect(platformLabels(t).join(' | '), contains('Subject'));

    await t.ensureVisible(find.text('Select').last);
    await t.tap(find.text('Select').last);
    await settle(t, 800);
    final labels = platformLabels(t).join(' | ');
    expect(labels, contains('Kim'), reason: labels);
    expect(labels, isNot(contains('Subject')), reason: 'the form behind the picker: $labels');
    expect(await systemBack(t), isTrue);
    await settle(t, 600);
    expect(platformLabels(t).join(' | '), contains('Subject'), reason: 'the picker closed first');
    expect(await systemBack(t), isTrue);
    await settle(t, 600);
    expect(find.text('Email Configuration'), findsNothing);
    semantics.dispose();
  });

  testWidgets('Create from Blank (Studio) at 360 dp is a sheet: its title in the header, Cancel / Create pinned and '
      '44 px', (t) async {
    phoneWindow(t, size: const Size(360, 780));
    final ws = await workspace();
    ws.api.seed(name: 'Support triage');
    await pumpApp(t, ws);
    await t.tap(find.byKey(const ValueKey('studio-create-fab')));
    await settle(t);
    await t.tap(find.text('Create from Blank'));
    await settle(t);
    _header(t, 'Create from Blank');
    final create = t.getRect(find.byKey(const ValueKey('create-app-submit')));
    expect(create.height, greaterThanOrEqualTo(44));
    expect(create.bottom, lessThanOrEqualTo(780 - gestureInsets.bottom + 0.5));
    expect(create.bottom, greaterThan(780 - gestureInsets.bottom - 24));
    expect(find.byKey(const ValueKey('create-app-shell-close')), findsNothing, reason: "the sheet's close instead");
    expect(await systemBack(t), isTrue);
    await settle(t);
    expect(find.byKey(const ValueKey('create-app-name')), findsNothing);
    expect(t.takeException(), isNull);
    await unmount(t);
  });

  testWidgets('the other touch rows: an extract parameter, a delivery method, a next step (48 px, a name, tap '
      'acts, "…" offers the hover actions)', (t) async {
    final log = <String>[];
    await _app(
      t,
      DataPanelHost(
        child: HumanInputHost(
          members: const [],
          userEmail: 'owner@example.com',
          userName: 'Owner',
          workspaceName: 'Lab',
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 80, 16, 0),
            child: Column(
              children: [
                ExtractParamItem(
                  payload: const {'name': 'city', 'type': 'string', 'required': true, 'description': 'The city'},
                  onEdit: () => log.add('edit param'),
                  onDelete: () => log.add('delete param'),
                ),
                const SizedBox(height: 8),
                MethodItem(
                  method: const {'id': 'm', 'type': 'webapp', 'enabled': true},
                  onChange: (_) => log.add('change method'),
                  onDelete: (type) => log.add('delete $type'),
                  email: const EmailContext(nodeId: 'n'),
                ),
                const SizedBox(height: 8),
                NextStepItem(
                  node: const NextStepNode(id: 'n2', type: 'llm', title: 'Summarize'),
                  actions: NextStepActions(
                    onSelectNode: (id) => log.add('jump $id'),
                    onDisconnect: (id) => log.add('disconnect $id'),
                    onDelete: (id) => log.add('delete $id'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    for (final f in [find.byType(ExtractParamItem), find.byType(MethodItem), find.byType(NextStepItem)]) {
      final row = find.descendant(of: f, matching: find.byType(DifyActionRow));
      expect(t.getSize(row).height, greaterThanOrEqualTo(48));
    }
    await t.tap(_touchRow('city'));
    await settle(t, 300);
    expect(log, ['edit param']);
    await t.tap(find.byKey(const ValueKey('dify-action-row-more-city, String, Required, The city')));
    await settle(t, 600);
    await t.tap(find.text(_tc('operation.delete')));
    await settle(t, 600);
    expect(log.last, 'delete param');

    await t.tap(find.byKey(const ValueKey('dify-action-row-more-Webapp')));
    await settle(t, 600);
    await t.tap(find.text(_tc('operation.remove')));
    await settle(t, 600);
    expect(log.last, 'delete webapp');

    await t.tap(_touchRow('Summarize'));
    await settle(t, 300);
    expect(log.last, 'jump n2');
    await t.longPress(_touchRow('Summarize'));
    await settle(t, 600);
    expect(find.text('Disconnect'), findsOneWidget);
    await t.tap(find.text('Disconnect'));
    await settle(t, 600);
    expect(log.last, 'disconnect n2');
  });

  testWidgets('recheck leftovers in a phone sheet: the email row\'s "Not configured" is a 44 dp button; the user '
      'action\'s style control is a 44 dp tertiary icon button like Delete', (t) async {
    final nav = await _app(t, const SizedBox.expand());
    unawaited(
      showDifyBottomSheet<void>(
        nav.currentContext!,
        (context) => DataPanelHost(
          child: HumanInputHost(
            userEmail: 'owner@example.com',
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MethodItem(
                    method: const {'id': 'm', 'type': 'email', 'enabled': false},
                    onChange: (_) {},
                    onDelete: (_) {},
                    email: const EmailContext(nodeId: 'n'),
                  ),
                  Row(
                    children: [
                      ButtonStyleDropdown(text: 'Approve', value: 'primary', onChange: (_) {}),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await settle(t, 800);
    final notConfigured = find.widgetWithText(DifyButton, 'Not configured');
    expect(t.getSize(notConfigured).height, greaterThanOrEqualTo(44));
    final style = find.descendant(of: find.byType(ButtonStyleDropdown), matching: find.byType(DifyIconButton));
    expect(style, findsOneWidget);
    expect(t.getSize(style), const Size(44, 44), reason: "Delete's 44 dp box");
    expect(find.descendant(of: find.byType(ButtonStyleDropdown), matching: find.byType(DifyButton)), findsNothing);
  });

  // ---- Emulator recheck fixes (2): at 411x914, what TalkBack gets (the platform's semantics tree). -------------------

  group('emulator recheck 2', () {
    bool tappable(PlatformNode n) =>
        n.data.hasAction(SemanticsAction.tap) || n.data.hasAction(SemanticsAction.longPress);
    bool textField(PlatformNode n) => n.data.flagsCollection.isTextField;

    testWidgets('item 1: a webhook table row on a phone is one named item ("city, String, Required") with its own '
        'Delete; the name field, the type and Required are 48 dp nodes; the "…" is inside the row, the columns line '
        'up', (t) async {
      final semantics = t.ensureSemantics();
      await _app(
        t,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 80, 16, 0),
          child: Column(
            spacing: 16,
            children: [
              ParameterTable(
                title: 'Query Parameters',
                parameters: const [
                  {'name': 'city', 'type': 'string', 'required': true},
                  {'name': 'days', 'type': 'number', 'required': false},
                ],
                onChange: (_) {},
              ),
              HeaderTable(
                headers: const [
                  {'name': 'X-Token', 'required': true},
                ],
                onChange: (_) {},
              ),
            ],
          ),
        ),
      );
      final nodes = platformNodes(t);
      final dump = describeStops(platformStops(t));
      PlatformNode node(String label) =>
          nodes.where((n) => n.data.label == label).singleOrNull ?? (throw TestFailure('no "$label" in:\n$dump'));
      for (final (name, cells) in [
        ('city, String, Required', ['Variable name', 'Type, String', 'Required', 'More actions for city']),
        ('days, Number', ['Variable name', 'Type, Number', 'Required', 'More actions for days']),
        ('X-Token, Required', ['Variable name', 'Required', 'More actions for X-Token']),
      ]) {
        final row = node(name);
        expect(row.rect.height, greaterThanOrEqualTo(48), reason: name);
        expect(row.data.hasAction(SemanticsAction.longPress), isTrue, reason: '$name: its actions');
        expect(row.data.customSemanticsActionIds, isNotEmpty, reason: '$name: Delete as an action of the row');
        final inRow = [
          for (final n in nodes)
            if (n.node != row.node && row.rect.inflate(0.5).contains(n.rect.center) && spokenText(n).isNotEmpty) n,
        ];
        expect(inRow.where(textField), hasLength(1), reason: '$name: one field node, no name node beside it\n$dump');
        final field = inRow.firstWhere(textField);
        expect(field.data.label, contains(cells.first), reason: dump);
        expect(field.rect.height, greaterThanOrEqualTo(48), reason: '$name field: ${field.rect}');
        for (final cell in cells.skip(1)) {
          final n = inRow.where((n) => n.data.label == cell).singleOrNull;
          expect(n, isNotNull, reason: '$name: "$cell" in\n$dump');
          expect(n!.rect.height, greaterThanOrEqualTo(44), reason: '$name: $cell ${n.rect}');
          expect(tappable(n), isTrue, reason: '$name: $cell acts');
          expect(row.rect.inflate(0.5).contains(n.rect.bottomRight), isTrue, reason: '$name: $cell inside the row');
        }
        final required = inRow.firstWhere((n) => n.data.label == 'Required');
        expect(required.data.flagsCollection.isChecked, isNot(CheckedState.none), reason: 'a checkbox');
        expect(required.rect.width, greaterThanOrEqualTo(48));
        expect(inRow.where((n) => spokenText(n).isEmpty && tappable(n)), isEmpty, reason: 'no unlabelled stop');
      }
      expect(nodes.where((n) => spokenText(n).isEmpty && tappable(n)), isEmpty, reason: 'no unlabelled stop:\n$dump');
      // The "…" stands inside the row's borders, which run under it to the table's edge; the header's columns line up
      // with the rows' (the header keeps the "…" column empty).
      final table = t.getRect(find.byType(ParameterTable));
      final more = node('More actions for city').rect;
      final rowBox = t.getRect(find.ancestor(of: find.text('city'), matching: find.byType(DifyActionRow)).first);
      expect(rowBox.right, closeTo(table.right - 1, 1), reason: 'the row (and its dividers) spans the table');
      expect(more.right, lessThanOrEqualTo(rowBox.right + 0.5));
      final requiredHeader = t.getRect(find.text('REQUIRED').first);
      final requiredCell = t.getRect(
        find.descendant(of: find.byType(ParameterTable), matching: find.byType(DifyCheckbox)).first,
      );
      expect(requiredCell.left, closeTo(requiredHeader.left, 1), reason: 'the Required column lines up');
      expect(t.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('item 2: Add Input Field\'s checkboxes are named 44 dp rows, without unlabelled stops beside them', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      final (_, demo) = await _editor(t, const Size(411, 914));
      await _openStart(t);
      await t.tap(find.bySemanticsLabel('Add Input Field').first);
      await settle(t, 800);
      final dump = describeStops(platformStops(t));
      final unlabelled = [
        for (final n in platformNodes(t))
          if (spokenText(n).isEmpty && tappable(n)) n,
      ];
      expect(unlabelled, isEmpty, reason: 'unlabelled stops ("Button", "Unlabelled"):\n$dump');
      for (final label in ['Required', 'Hidden & Pre-Filled']) {
        final box = platformNodes(t)
            .where((n) => n.data.label == label && n.data.flagsCollection.isChecked != CheckedState.none);
        expect(box, hasLength(1), reason: '$label: one checkbox node\n$dump');
        expect(box.single.rect.height, greaterThanOrEqualTo(44), reason: '$label: ${box.single.rect}');
      }
      final required = platformNodes(t).firstWhere((n) => n.data.label == 'Required');
      expect(required.data.hasAction(SemanticsAction.tap), isTrue, reason: 'the checkbox node toggles');
      expect(t.takeException(), isNull);
      semantics.dispose();
      await _close(t, demo);
    });

    testWidgets('item 2: Name this version\'s Title field node is the 44 dp box; the roster\'s search field is one '
        '44 dp node', (t) async {
      final semantics = t.ensureSemantics();
      final nav = await _app(t, const SizedBox.expand());
      unawaited(showVersionInfoModal(nav.currentContext!, onPublish: (_) {}));
      await settle(t, 600);
      var fields = platformNodes(t).where(textField).toList();
      expect(fields, hasLength(2), reason: describeStops(platformStops(t)));
      expect(fields.first.rect.height, greaterThanOrEqualTo(44), reason: 'Title: ${fields.first.rect}');
      Navigator.of(nav.currentContext!).pop();
      await settle(t, 600);

      await _app(
        t,
        Padding(
          padding: const EdgeInsets.only(top: 80),
          child: BlockSelectorScope(
            data: BlockSelectorData(searchAgents: (_) async => const []),
            child: DifyPopupSheetScope(
              child: AgentSelectorContent(onSelect: (_) {}, onClose: () {}, onStartFromScratch: () {}),
            ),
          ),
        ),
      );
      fields = platformNodes(t).where(textField).toList();
      expect(fields, hasLength(1), reason: 'one node, no name node beside it:\n${describeStops(platformStops(t))}');
      expect(fields.single.data.label, contains('Search agents'));
      expect(fields.single.rect.height, greaterThanOrEqualTo(44), reason: '${fields.single.rect}');
      semantics.dispose();
    });

    testWidgets('item 2: Select reference Knowledge\'s Cancel / Add are end-aligned like the other sheets', (t) async {
      await _app(
        t,
        LlmGroupScope(
          services: LlmGroupServices(
            fetchDatasetPage: (page) async => (
              data: [
                for (var i = 0; i < 3; i++)
                  {
                    'id': 'd$i',
                    'name': 'Knowledge $i',
                    'indexing_technique': 'high_quality',
                    'embedding_available': true,
                  },
              ],
              hasMore: false,
            ),
          ),
          child: Builder(
            builder: (context) => DifyButton(
              key: const ValueKey('open'),
              onPressed: () => showSelectDataset(context, selectedIds: const []),
              child: const DifyTextLine('open'),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('open')));
      await settle(t, 800);
      final add = t.getRect(find.widgetWithText(DifyButton, _tc('operation.add')));
      final cancel = t.getRect(find.widgetWithText(DifyButton, _tc('operation.cancel')));
      expect(add.right, closeTo(411 - 16, 1), reason: 'Add at the end: $add');
      expect(add.left - cancel.right, closeTo(8, 1), reason: 'Cancel just before it: $cancel');
    });

    testWidgets('item 3: the prompt\'s variable picker reads its search as the field (no container stop before it); '
        'Back gives TalkBack\'s focus back to {x}', (t) async {
      final semantics = t.ensureSemantics();
      final sent = <Map<Object?, Object?>>[];
      t.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, (m) async {
        if (m is Map) sent.add(m);
        return null;
      });
      addTearDown(
        () =>
            t.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, null),
      );
      final (_, demo) = await _editor(t, const Size(411, 914));
      await t.tap(find.descendant(of: find.byType(WorkflowStepsView), matching: find.text('Answer')).first);
      await settle(t, 800);
      final insert = find.byKey(const Key('prompt-editor-insert')).first;
      await _show(t, insert);
      final trigger = t.getSemantics(insert).id;
      // TalkBack is on {x} (the engine reports it) when it is double-tapped.
      ServicesBinding.instance.accessibilityFocus.value = trigger;
      await t.tap(insert);
      await settle(t, 800);
      final nodes = platformNodes(t);
      final search = nodes.where((n) => n.data.label.contains('Search variable') || n.data.hint == 'Search variable');
      expect(search, hasLength(1), reason: 'one stop: ${describeStops(platformStops(t))}');
      expect(textField(search.single), isTrue, reason: 'the stop is the field');
      expect(search.single.rect.height, greaterThanOrEqualTo(44));

      sent.clear();
      expect(await systemBack(t), isTrue);
      await t.pump(const Duration(milliseconds: 400));
      await settle(t, 300);
      expect(find.byKey(const Key('prompt-editor-picker-sheet')), findsNothing);
      expect(t.getSemantics(insert).id, trigger, reason: '{x} keeps its node');
      expect(sent.where((m) => m['type'] == 'focus').map((m) => m['nodeId']), [trigger], reason: '$sent');
      ServicesBinding.instance.accessibilityFocus.value = null;
      semantics.dispose();
      await _close(t, demo);
    });

    testWidgets('item 3: the member picker over Email Configuration has a title and 48 dp rows; Back gives TalkBack\'s '
        'focus back to Select; the email row reads "Email" once', (t) async {
      final semantics = t.ensureSemantics();
      final sent = <Map<Object?, Object?>>[];
      t.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, (m) async {
        if (m is Map) sent.add(m);
        return null;
      });
      addTearDown(
        () =>
            t.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, null),
      );
      await _app(
        t,
        DataPanelHost(
          child: HumanInputHost(
            members: const [HiMember(id: 'm1', email: 'kim@example.com', name: 'Kim')],
            userEmail: 'owner@example.com',
            userName: 'Owner',
            workspaceName: 'Lab',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 80, 16, 0),
              child: Column(
                children: [
                  Builder(
                    builder: (context) => DifyButton(
                      key: const ValueKey('open'),
                      onPressed: () => showEmailConfigureModal(context, email: const EmailContext(nodeId: 'n')),
                      child: const DifyTextLine('open'),
                    ),
                  ),
                  MethodItem(
                    method: const {'id': 'm', 'type': 'email', 'enabled': false},
                    onChange: (_) {},
                    onDelete: (_) {},
                    email: const EmailContext(nodeId: 'n'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final rowLabels = [
        for (final n in platformNodes(t))
          if (RegExp(r'\bEmail\b').hasMatch(n.data.label) && !n.data.label.startsWith('More actions')) n.data.label,
      ];
      expect(rowLabels, ['Email, Not configured'], reason: 'the row says "Email" once');

      await t.tap(find.byKey(const ValueKey('open')));
      await settle(t, 800);
      final select = find.widgetWithText(DifyButton, 'Select').last;
      await t.ensureVisible(select);
      await settle(t, 300);
      final trigger = t.getSemantics(select).id;
      ServicesBinding.instance.accessibilityFocus.value = trigger;
      await t.tap(select);
      await settle(t, 800);
      final title = DifyI18n.tr('workflow', 'nodes.humanInput.deliveryMethod.emailConfigure.memberSelector.title');
      expect(find.widgetWithText(DifySheetHeader, title), findsOneWidget, reason: 'the picker is titled');
      final row = find.ancestor(of: find.text('kim@example.com'), matching: find.byType(DifyPressable)).first;
      expect(t.getSize(row).height, greaterThanOrEqualTo(48));

      sent.clear();
      expect(await systemBack(t), isTrue);
      await t.pump(const Duration(milliseconds: 400));
      await settle(t, 300);
      expect(find.widgetWithText(DifySheetHeader, title), findsNothing);
      expect(t.getSemantics(select).id, trigger, reason: 'Select keeps its node');
      expect(sent.where((m) => m['type'] == 'focus').map((m) => m['nodeId']), [trigger], reason: '$sent');
      ServicesBinding.instance.accessibilityFocus.value = null;
      semantics.dispose();
    });

    testWidgets('item 4: Add Extract Parameter is a sheet with its header close and Cancel / Add pinned; Add with no '
        'description shows Dify\'s toast over the sheet; an edit keeps Dify\'s title', (t) async {
      phoneWindow(t);
      final nav = GlobalKey<NavigatorState>();
      await t.pumpWidget(
        DifyApplication(
          theme: difyTheme(),
          edgeToEdge: true,
          navigatorKey: nav,
          builder: (context, child) => Stack(children: [child!, const DifyToastHost()]),
          home: const DifyPage(edgeToEdge: true, body: SizedBox.expand()),
        ),
      );
      await settle(t, 300);
      Map<String, Object?>? saved;
      unawaited(showExtractParameterDialog(nav.currentContext!, isAdd: true, onSave: (p, _) => saved = p));
      await settle(t, 800);
      _header(t, 'Add Extract Parameter');
      _pinned(t, _tc('operation.add'), const Size(411, 914));
      _pinned(t, _tc('operation.cancel'), const Size(411, 914));
      final name = find.descendant(of: find.byType(ExtractParameterForm), matching: find.byType(EditableText)).first;
      await t.enterText(name, 'city');
      await t.tap(find.widgetWithText(DifyButton, _tc('operation.add')));
      await settle(t, 400);
      final message = DifyI18n.tr('workflow', 'errorMsg.fieldRequired', {
        'field': DifyI18n.tr('workflow', 'nodes.parameterExtractor.addExtractParameterContent.description'),
      });
      final toastText = find.text(message);
      expect(toastText, findsOneWidget, reason: 'the validation message');
      expect(t.getRect(toastText).top, greaterThanOrEqualTo(gestureInsets.top), reason: 'below the status bar');
      expect(t.getRect(toastText).bottom, lessThan(t.getRect(_dialogHeader).top), reason: 'clear of the sheet');
      expect(saved, isNull);
      expect(find.byType(ExtractParameterForm), findsOneWidget, reason: 'the sheet stays');
      Navigator.of(nav.currentContext!).pop();
      await settle(t, 6000);

      unawaited(
        showExtractParameterDialog(
          nav.currentContext!,
          isAdd: false,
          payload: const {'name': 'city', 'type': 'string', 'required': false, 'description': 'The city'},
          onSave: (p, _) => saved = p,
        ),
      );
      await settle(t, 800);
      _header(t, 'Add Extract Parameter');
      _pinned(t, _tc('operation.save'), const Size(411, 914));
      await t.tap(find.widgetWithText(DifyButton, _tc('operation.save')));
      await settle(t, 600);
      expect(saved?['name'], 'city');
      expect(t.takeException(), isNull);
    });
  });

  group('emulator recheck 3', () {
    for (final size in phoneSizes) {
      testWidgets('leftover 1: at ${size.width.toInt()} dp the webhook columns read whole: "VARIABLE NAME", the type '
          'values (String, Number, Boolean) and the start of the name placeholder', (t) async {
        // The select's values are in the platform's font (Android's Roboto), not the test's square fallback.
        await t.runAsync(() async {
          final roboto = File(
            '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
          ).readAsBytes();
          await (FontLoader('Roboto')..addFont(roboto.then(ByteData.sublistView))).load();
        });
        await _app(
          t,
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 80, 16, 0),
            child: ParameterTable(
              title: 'Query Parameters',
              parameters: const [
                {'name': 'city', 'type': 'string', 'required': true},
                {'name': 'days', 'type': 'number', 'required': false},
                {'name': 'flag', 'type': 'boolean', 'required': false},
              ],
              onChange: (_) {},
            ),
          ),
          size: size,
        );
        RenderParagraph paragraph(Finder text) => t.renderObject<RenderParagraph>(
          find.descendant(of: text, matching: find.byType(RichText), matchRoot: true).first,
        );
        expect(paragraph(find.text('VARIABLE NAME')).didExceedMaxLines, isFalse, reason: 'not "VARIABL…"');
        for (final type in ['String', 'Number', 'Boolean']) {
          final label = find.descendant(of: find.byType(ParameterTable), matching: find.text(type));
          expect(paragraph(label).didExceedMaxLines, isFalse, reason: '$type is not cut ("Num…")');
        }
        final placeholder = find.text('Enter variable name...');
        final field = t.getSize(find.ancestor(of: placeholder, matching: find.byType(DifyTextField)).first);
        expect(field.width, greaterThanOrEqualTo(100), reason: 'room for "Enter variable": $field');
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('leftover 2: Name this version\'s Title field is named "Title", its placeholder the hint', (t) async {
      final semantics = t.ensureSemantics();
      final nav = await _app(t, const SizedBox.expand());
      unawaited(showVersionInfoModal(nav.currentContext!, onPublish: (_) {}));
      await settle(t, 600);
      final fields = [
        for (final n in platformNodes(t))
          if (n.data.flagsCollection.isTextField) n,
      ];
      expect([for (final n in fields) n.data.label], ['Title', 'Release Notes'], reason: describeStops(fields));
      expect(fields.first.data.hint, 'Name this version(optional)');
      semantics.dispose();
    });

    testWidgets('leftover 3 and 4: the member picker\'s title wraps rather than being cut at 411 dp; its search reads '
        '"Search" once', (t) async {
      final semantics = t.ensureSemantics();
      await _app(
        t,
        DataPanelHost(
          child: HumanInputHost(
            members: const [HiMember(id: 'm1', email: 'kim@example.com', name: 'Kim')],
            userEmail: 'owner@example.com',
            userName: 'Owner',
            workspaceName: 'Lab',
            child: Builder(
              builder: (context) => DifyButton(
                key: const ValueKey('open'),
                onPressed: () => showEmailConfigureModal(context, email: const EmailContext(nodeId: 'n')),
                child: const DifyTextLine('open'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('open')));
      await settle(t, 800);
      await t.ensureVisible(find.text('Select').last);
      await t.tap(find.text('Select').last);
      await settle(t, 800);
      final title = DifyI18n.tr('workflow', 'nodes.humanInput.deliveryMethod.emailConfigure.memberSelector.title');
      final text = t.renderObject<RenderParagraph>(
        find
            .descendant(
              of: find.descendant(of: find.byType(DifySheetHeader), matching: find.text(title)),
              matching: find.byType(RichText),
              matchRoot: true,
            )
            .first,
      );
      expect(text.didExceedMaxLines, isFalse, reason: 'the whole title shows');
      final search = [
        for (final n in platformNodes(t))
          if (n.data.flagsCollection.isTextField) n,
      ];
      expect(search, hasLength(1));
      expect(spokenText(search.single), 'Search', reason: 'not "Search / Search"');
      semantics.dispose();
    });
  });
}
