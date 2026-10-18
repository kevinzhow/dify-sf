import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/controls.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/store/app_registers_sync.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/workflow/panel/harness.dart' show RecordingController, difyNode;
import 'support/app_fonts.dart';

/// The features panel (protocol 1.7): the app's features live in the document under `$app` (config `features`,
/// Dify's `workflow.features`); a change is the fewest nested `setConfig` ops there, so several people's changes to
/// different features all stay, and none of them is workflow history (as in Dify).

const _app = Document.appNode;

/// Dify's `workflow.features` of a chatflow with nothing on.
const _features = {
  'opening_statement': '',
  'suggested_questions': <Object?>[],
  'suggested_questions_after_answer': {'enabled': false},
  'text_to_speech': {'enabled': false},
  'speech_to_text': {'enabled': false},
  'retriever_resource': {'enabled': false},
  'sensitive_word_avoidance': {'enabled': false},
  'file_upload': {
    'enabled': false,
    'image': {
      'enabled': false,
      'number_limits': 3,
      'transfer_methods': ['local_file', 'remote_url'],
    },
  },
};

/// One person on the document: a session, a recording controller and the editor's store following the document.
class _Client {
  _Client._(this.session, this.controller);
  final CollabSession session;
  final RecordingController controller;
  final store = WorkflowStore();
  late final sync = AppRegistersSync(controller: controller, store: store);

  static Future<_Client> join(WidgetTester t, FakeServer server, String id) async {
    final session = CollabSession(clientId: id, transport: FakeTransport(server), store: MemoryStore());
    await session.start();
    final c = _Client._(session, RecordingController(session: session, docId: 'demo'));
    for (var i = 0; i < 50 && !c.controller.ready; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    c.sync.sync();
    return c;
  }

  /// The features as this client's document has them.
  Map<String, Object?> get features => AppRegisters.featuresOf(controller.doc);

  Future<void> dispose() async {
    sync.dispose();
    controller.dispose();
    store.dispose();
    await session.stop();
  }
}

FakeServer _server({Map<String, Object?> features = _features}) => FakeServer(
  initial: Document(
    nodes: [
      difyNode('start', 'start', {'variables': <Object?>[]}),
    ],
    app: {AppRegisters.features: Value.of(features)},
  ),
);

Future<void> _settle(WidgetTester t, [Duration d = const Duration(seconds: 1)]) async {
  for (var i = 0; i < d.inMilliseconds ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Shows [c]'s features panel (a chatflow's unless [isChatMode] is false) on a 1600 x 1000 page.
Future<void> _showPanel(WidgetTester t, _Client c, {bool isChatMode = true}) async {
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  c.store.setShowFeaturesPanel(true);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: c.store,
          child: WorkflowFeatures(controller: c.controller, isChatMode: isChatMode),
        ),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 300));
}

Finder _card(String titleKey) =>
    find.ancestor(of: find.text(DifyI18n.tr('app-debug', titleKey)), matching: find.byType(FeatureCard));

Finder _switchOf(String titleKey) => find.descendant(of: _card(titleKey), matching: find.byType(DifySwitch));

bool _on(WidgetTester t, String titleKey) => t.widget<DifySwitch>(_switchOf(titleKey)).checked;

Future<void> _close(WidgetTester t, List<_Client> clients) async {
  await t.pumpWidget(const SizedBox());
  for (final c in clients) {
    await c.dispose();
  }
  await t.pump(const Duration(seconds: 20));
}

void main() {
  testWidgets('switching a feature is one nested setConfig on \$app, based on the version on screen, not undoable', (
    t,
  ) async {
    final me = await _Client.join(t, _server(), 'me-1');
    await _showPanel(t, me);
    final seen = me.controller.seenVersion;

    await t.tap(_switchOf('feature.citation.title'));
    await t.pump();
    expect(me.controller.ops, hasLength(1));
    final op = me.controller.ops.single;
    expect((op.kind, op.node, op.value, op.base), ('set', _app, true, seen));
    expect(op.path, ['features', 'retriever_resource', 'enabled']);
    expect(_on(t, 'feature.citation.title'), isTrue);
    expect(me.controller.undo.canUndo, isFalse, reason: 'Dify keeps feature edits out of the workflow history');

    await _settle(t);
    expect(featureMap(me.features, 'retriever_resource')['enabled'], true);
    expect(me.controller.ops, hasLength(1), reason: 'the write coming back changes nothing');
    await _close(t, [me]);
  });

  testWidgets('two people switching different features at once both keep their change', (t) async {
    final server = _server();
    final alice = await _Client.join(t, server, 'alice-1');
    final bob = await _Client.join(t, server, 'bob-1');

    // Each changes a feature in their own panel's store, neither having seen the other's change.
    void toggle(_Client c, String feature) {
      final store = FeaturesStore(features: buildInitialFeatures(c.store.features.value));
      final sync = FeaturesDocSync(controller: c.controller, store: c.store, features: store);
      store.setFeatures(withFeature(store.features.value, feature, {'enabled': true}));
      sync.save();
      sync.dispose();
      store.dispose();
    }

    toggle(alice, FeatureEnum.citation);
    toggle(bob, FeatureEnum.speech2text);
    expect(alice.controller.appOps.single.path, ['features', 'retriever_resource', 'enabled']);
    expect(bob.controller.appOps.single.path, ['features', 'speech_to_text', 'enabled']);
    await _settle(t, const Duration(seconds: 2));

    for (final c in [alice, bob]) {
      expect(featureMap(c.features, 'retriever_resource')['enabled'], true);
      expect(featureMap(c.features, 'speech_to_text')['enabled'], true);
      expect(c.features['file_upload'], _features['file_upload'], reason: 'nothing else was rewritten');
    }
    await _close(t, [alice, bob]);
  });

  testWidgets('a change someone else makes shows in the open panel', (t) async {
    final server = _server();
    final me = await _Client.join(t, server, 'me-1');
    final other = await _Client.join(t, server, 'other-1');
    await _showPanel(t, me);
    expect(_on(t, 'feature.moderation.title'), isFalse);

    other.controller.setConfig(
      _app,
      ['features', 'sensitive_word_avoidance'],
      Value.of({
        'enabled': true,
        'type': 'keywords',
        'config': {
          'keywords': 'bad',
          'inputs_config': {'enabled': true, 'preset_response': 'no'},
        },
      }),
    );
    await _settle(t, const Duration(seconds: 2));
    expect(_on(t, 'feature.moderation.title'), isTrue);
    expect(find.text(DifyI18n.tr('app-debug', 'feature.moderation.modal.provider.keywords')), findsOneWidget);
    await _close(t, [me, other]);
  });

  testWidgets('the opening statement is written once when the opener is saved, based on the version then on screen', (
    t,
  ) async {
    final me = await _Client.join(t, _server(), 'me-1');
    await _showPanel(t, me);

    // Switching the opener on writes nothing yet (an empty statement is what the document has) and it stays on.
    await t.tap(_switchOf('feature.conversationOpener.title'));
    await _settle(t);
    expect(me.controller.ops, isEmpty);
    expect(_on(t, 'feature.conversationOpener.title'), isTrue);

    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(t.getCenter(_card('feature.conversationOpener.title')));
    await t.pump();
    await t.tap(find.text(DifyI18n.tr('app-debug', 'openingStatement.writeOpener')));
    await _settle(t, const Duration(milliseconds: 400));
    final seen = me.controller.seenVersion;

    final editor = find.byWidgetPredicate((w) => w is TextField && w.controller is PromptEditorController);
    for (final text in ['H', 'Hi', 'Hi there']) {
      await t.enterText(editor, text);
      await t.pump(const Duration(milliseconds: 600));
    }
    expect(me.controller.ops, isEmpty, reason: 'typing in the opener modal is a draft until Save');
    await t.tap(find.text(DifyI18n.tr('common', 'operation.save')));
    await _settle(t);

    final op = me.controller.ops.single;
    expect((op.node, op.value, op.base), (_app, 'Hi there', seen));
    expect(op.path, ['features', 'opening_statement']);
    expect(me.features['opening_statement'], 'Hi there');
    await mouse.moveTo(const Offset(1, 999));
    await t.pump();
    expect(find.text('Hi there'), findsOneWidget, reason: 'the card shows the statement');
    await _close(t, [me]);
  });

  testWidgets('a workflow offers only the legacy image upload; a chatflow the chat features', (t) async {
    final me = await _Client.join(t, _server(), 'me-1');
    String title(String key) => DifyI18n.tr('app-debug', key);

    await _showPanel(t, me, isChatMode: false);
    expect(find.byType(FeatureCard), findsOneWidget);
    expect(find.text(title('feature.imageUpload.title')), findsOneWidget);

    await _showPanel(t, me);
    expect(
      [for (final c in t.widgetList<FeatureCard>(find.byType(FeatureCard))) c.title is String ? c.title : 'w'],
      [
        title('feature.conversationOpener.title'),
        title('feature.suggestedQuestionsAfterAnswer.title'),
        title('feature.fileUpload.title'),
        title('feature.citation.title'),
        title('feature.moderation.title'),
      ],
      reason: 'no text to speech / speech to text without default models; no annotation reply in a workflow app',
    );
    await _close(t, [me]);
  });

  testWidgets(
    'the header\'s Features button (chatflows only) opens the drawer over the editor; its backdrop closes it',
    (
      t,
    ) async {
      await useAppFonts();
      t.view.physicalSize = const Size(1600, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      for (final chat in [false, true]) {
        final backend = _MetaBackend(DocMeta(appMode: chat ? 'advanced-chat' : 'workflow'), server: _server());
        await t.pumpWidget(
          MaterialApp(
            theme: ThemeData(fontFamily: 'Noto Sans'),
            home: EditorPage(backend: backend, docId: 'demo', clientId: 'me-abc123', journaled: false),
          ),
        );
        await _settle(t, const Duration(seconds: 2));
        final button = find.text(DifyI18n.tr('workflow', 'common.features'));
        if (!chat) {
          expect(button, findsNothing);
        } else {
          await t.tap(button);
          await t.pump(const Duration(milliseconds: 300));
          expect(find.byType(NewFeaturePanel), findsOneWidget);
          expect(find.text(DifyI18n.tr('workflow', 'common.featuresDescription')), findsOneWidget);
          await t.tapAt(const Offset(200, 450)); // the backdrop, left of the drawer
          await t.pump(const Duration(milliseconds: 300));
          expect(find.byType(FeatureCard), findsNothing);
        }
        await t.pumpWidget(const SizedBox());
        await backend.dispose();
        await t.pump(const Duration(seconds: 20));
      }
    },
  );
}

class _MetaBackend extends DemoBackend {
  _MetaBackend(this._meta, {super.server}) : super(withBo: false);
  final DocMeta _meta;

  @override
  Future<DocMeta> docMeta(String docId) async => _meta;
}
