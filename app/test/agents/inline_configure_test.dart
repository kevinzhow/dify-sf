import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/agents/inline_configure.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'inline_composer_test.dart' show Fixture, composerReply, document, binding;

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
  });
  Future<void> mount(
    WidgetTester t,
    Fixture f, {
    bool readOnly = false,
    void Function(Map<String, Object?>)? onSaved,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        home: Material(
          child: SizedBox(
            width: 520,
            height: 700,
            child: InlineAgentConfigure(
              composer: f.client,
              readOnly: readOnly,
              args: (
                nodeId: 'node',
                agentId: 'private-agent',
                composerState: null,
                onClose: () {},
                onSaved: onSaved ?? (_) {},
                onSaveInlineToRoster: null,
              ),
            ),
          ),
        ),
      ),
    );
    // StreamSubscription.cancel may return Dart's cached root-zone future. Drain real microtasks as well as frames.
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('uncertain save preserves entered prompt and retries one exact request', (t) async {
    final f = Fixture();
    addTearDown(f.changes.close);
    final next = {...binding, 'current_snapshot_id': 's2'};
    var attempts = 0;
    f.api.write = (body) async {
      f.change((document: document(selected: next), seq: 6, ready: true));
      if (attempts++ == 0) throw const TransportException('lost reply', timeout: true);
      return {...composerReply(seq: 6, selected: next), 'agent_soul': body['agent_soul']};
    };
    var saved = 0;
    await mount(t, f, onSaved: (_) => saved++);
    final prompt = find.descendant(
      of: find.byKey(const ValueKey('inline-agent-prompt')),
      matching: find.byType(EditableText),
    );
    await t.enterText(prompt, 'Keep this private prompt');
    await t.tap(find.byKey(const ValueKey('inline-agent-save')));
    // StreamSubscription.cancel may return Dart's cached root-zone future. Drain real microtasks as well as frames.
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Retry the same save'), findsOneWidget);
    expect(t.widget<EditableText>(prompt).controller.text, 'Keep this private prompt');
    expect(t.widget<EditableText>(prompt).readOnly, true);
    expect(t.widget<DifyButton>(find.byKey(const ValueKey('inline-agent-save'))).loading, false);
    expect(saved, 0);
    await t.tap(find.byKey(const ValueKey('inline-agent-retry')));
    // StreamSubscription.cancel may return Dart's cached root-zone future. Drain real microtasks as well as frames.
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(f.api.requests, hasLength(2));
    expect(f.api.requests[0], f.api.requests[1]);
    expect(saved, 1);
    expect(t.widget<EditableText>(prompt).readOnly, false);
    expect(t.takeException(), isNull);
  });
  testWidgets('definite refusal releases the buttons while keeping editable input', (t) async {
    final f = Fixture();
    addTearDown(f.changes.close);
    f.api.write = (_) async => throw const TransportException('invalid', statusCode: 400);
    await mount(t, f);
    final prompt = find.descendant(
      of: find.byKey(const ValueKey('inline-agent-prompt')),
      matching: find.byType(EditableText),
    );
    await t.enterText(prompt, 'Still here');
    await t.tap(find.byKey(const ValueKey('inline-agent-save')));
    // StreamSubscription.cancel may return Dart's cached root-zone future. Drain real microtasks as well as frames.
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(t.widget<EditableText>(prompt).readOnly, false);
    expect(t.widget<EditableText>(prompt).controller.text, 'Still here');
    final button = t.widget<DifyButton>(find.byKey(const ValueKey('inline-agent-save')));
    expect(button.loading, false);
    expect(button.disabled, false);
  });
  testWidgets('view-only member can inspect but cannot save or change private prompt', (t) async {
    final f = Fixture();
    addTearDown(f.changes.close);
    await mount(t, f, readOnly: true);
    expect(t.widget<DifyButton>(find.byKey(const ValueKey('inline-agent-save'))).disabled, true);
    final prompt = find.descendant(
      of: find.byKey(const ValueKey('inline-agent-prompt')),
      matching: find.byType(EditableText),
    );
    expect(t.widget<EditableText>(prompt).readOnly, true);
    expect(f.api.requests, isEmpty);
  });
  testWidgets('omitted task attachment is visible and removing it preserves the edit in the save', (t) async {
    final f = Fixture();
    addTearDown(f.changes.close);
    f.api.response = {
      ...composerReply(),
      'node_job': {
        'metadata': {
          'file_refs': [
            {'name': 'Missing task.txt', 'is_missing': true},
          ],
        },
      },
    };
    f.api.write = (body) async {
      expect(((body['node_job'] as Map)['metadata'] as Map)['file_refs'], isEmpty);
      final next = {...binding, 'current_snapshot_id': 's2'};
      f.change((document: document(selected: next), seq: 6, ready: true));
      return composerReply(seq: 6, selected: next);
    };
    await mount(t, f);
    final label = find.text('Missing task.txt · File not found');
    await t.ensureVisible(label);
    final row = find.ancestor(of: label, matching: find.byType(Row)).first;
    await t.tap(find.descendant(of: row, matching: find.byType(DifyButton)).first);
    await t.pump();
    expect(label, findsNothing);
    await t.tap(find.byKey(const ValueKey('inline-agent-save')));
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(f.api.requests.length, 1);
  });

  testWidgets('reload after a private conflict preserves the local prompt draft', (t) async {
    final f = Fixture();
    addTearDown(f.changes.close);
    f.api.write = (_) async => throw const TransportException('conflict', statusCode: 409, code: 'agent_node_changed');
    await mount(t, f);
    final prompt = find.descendant(
      of: find.byKey(const ValueKey('inline-agent-prompt')),
      matching: find.byType(EditableText),
    );
    await t.enterText(prompt, 'My unsaved work');
    await t.tap(find.byKey(const ValueKey('inline-agent-save')));
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.tap(find.text('Reload baseline, keep my edits'));
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(Duration.zero));
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(t.widget<EditableText>(prompt).controller.text, 'My unsaved work');
    expect(t.takeException(), isNull);
  });
}
