import 'package:dify_sf_app/src/agents/session_retention.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/agent_session_retention.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/dify_test_i18n.dart';

void main() {
  setUp(useDifyTestTranslator);
  test('session configuration accepts only a boolean switch', () {
    for (final value in [
      null,
      <String, Object?>{},
      {'enabled': true},
      {'enabled': false},
    ]) {
      expect(validAgentSessionRetention(value), isTrue);
    }
    for (final value in [
      1,
      'yes',
      {'enabled': null},
      {'enabled': 1},
      {'path': '/other'},
      {'enabled': true, 'input': 'file'},
    ]) {
      expect(validAgentSessionRetention(value), isFalse);
    }
  });
  testWidgets('shared switch enables retention without a variable picker', (
    t,
  ) async {
    var value = false;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: StatefulBuilder(
              builder: (context, setState) => AgentSessionRetentionField(
                enabled: value,
                onChange: (v) => setState(() => value = v),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsLabel('agent-v-2.inline.sessionCarry').last);
    await t.pumpAndSettle();
    expect(value, isTrue);
    expect(find.byType(TextField), findsNothing);
  });
  testWidgets('read-only retention cannot change', (t) async {
    var changed = false;
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentSessionRetentionField(
            enabled: true,
            readOnly: true,
            onChange: (_) => changed = true,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(
      find.bySemanticsLabel('agent-v-2.inline.sessionCarry').last,
      warnIfMissed: false,
    );
    await t.pumpAndSettle();
    expect(changed, isFalse);
  });
}
