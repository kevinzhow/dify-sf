// Dialogs as sheets on phones and row-based fields by touch (brief "dialogs"), at 411x914 and 360x780 with the
// system bars' insets: Start's Add / Edit Input Field (it bypassed the dialog route), Name this version, Select
// reference Knowledge, Email Configuration with a picker over it, Create from Blank; Start's input rows (tap edits,
// "…" and a long press: Edit, Delete with Dify's confirmation, Move up / down), and the other touch rows.
import 'dart:async';

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
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/kr_datasets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/pe_params.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/next_step.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
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
}
