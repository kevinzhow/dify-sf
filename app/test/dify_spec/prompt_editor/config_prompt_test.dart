// dify-spec: web/app/components/workflow/nodes/llm/components/__tests__/config-prompt.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/config_prompt.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _initial = [
  PromptItem(id: 'system', role: PromptRole.system, text: 'System instruction'),
  PromptItem(id: 'user', role: PromptRole.user, text: 'User question'),
  PromptItem(id: 'assistant', role: PromptRole.assistant, text: 'Assistant answer'),
];

/// The Fixture: ConfigPrompt over a list kept in state, reporting each change.
class _Fixture extends StatefulWidget {
  const _Fixture({required this.onChange, this.initial = _initial});
  final void Function(Object items) onChange;
  final List<PromptItem> initial;

  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  late List<PromptItem> prompts = widget.initial;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 32),
    child: ConfigPrompt(
      nodeId: 'llm',
      isChatModel: true,
      payload: prompts,
      onChange: (items) {
        widget.onChange(items);
        setState(() => prompts = items as List<PromptItem>);
      },
    ),
  );
}

Finder _handles() => find.byWidgetPredicate((w) => w is DifyIconButton && '${w.key}'.contains('sort-handle'));

FocusNode _handle(WidgetTester t, int i) => t.widget<DifyIconButton>(_handles().at(i)).focusNode!;

List<String> _texts(WidgetTester t) => [
  for (final e in find.byType(DifyPromptEditor).evaluate())
    (e as StatefulElement).state is DifyPromptEditorState ? (e.state as DifyPromptEditorState).controller.prompt : '',
];

Future<void> _key(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyEvent(k);
  await t.pump();
}

void main() {
  testWidgets('reorders messages without moving past the leading system prompt', (t) async {
    final calls = <Object>[];
    await render(t, _Fixture(onChange: calls.add));
    await t.pump();
    expect(calls, isEmpty);
    expect(_handles(), findsNWidgets(2));
    _handle(t, 0).requestFocus();
    await t.pump();
    expect(_handle(t, 0).hasFocus, isTrue);
    await _key(t, LogicalKeyboardKey.enter);
    await _key(t, LogicalKeyboardKey.arrowUp);
    expect(_texts(t), _initial.map((p) => p.text));
    await _key(t, LogicalKeyboardKey.arrowDown);
    expect(_texts(t), ['System instruction', 'Assistant answer', 'User question']);
    expect(calls, isEmpty);
    await _key(t, LogicalKeyboardKey.enter);
    expect(calls, [
      [_initial[0], _initial[2], _initial[1]],
    ]);
    await t.pump();
    expect(_handle(t, 1).hasFocus, isTrue);
  });

  testWidgets('persists unique IDs for default prompts once and retains them when sorting', (t) async {
    final calls = <Object>[];
    final initial = [for (final p in _initial) PromptItem(role: p.role, text: p.text)];
    await render(t, _Fixture(onChange: calls.add, initial: initial));
    await t.pump();
    expect(calls, hasLength(1));
    final initialized = calls[0] as List<PromptItem>;
    for (final (i, p) in initialized.indexed) {
      expect(p.id, isNotNull);
      expect(p.copyWith(id: 'x'), initial[i].copyWith(id: 'x'));
    }
    expect(initialized.map((p) => p.id).toSet(), hasLength(initial.length));

    _handle(t, 0).requestFocus();
    await t.pump();
    await _key(t, LogicalKeyboardKey.enter);
    await _key(t, LogicalKeyboardKey.arrowDown);
    await _key(t, LogicalKeyboardKey.escape);
    expect(calls, hasLength(1));
    await _key(t, LogicalKeyboardKey.enter);
    await _key(t, LogicalKeyboardKey.arrowDown);
    await _key(t, LogicalKeyboardKey.enter);
    expect(calls, hasLength(2));
    expect(calls.last, [initialized[0], initialized[2], initialized[1]]);
  });
}
