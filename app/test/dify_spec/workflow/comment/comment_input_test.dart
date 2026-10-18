// dify-spec: web/app/components/workflow/comment/comment-input.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/comments/comment_input.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import 'comment_harness.dart';

const _me = (id: 'user-1', name: 'Alice');
const _users = [(id: 'user-1', name: 'Alice'), (id: 'user-2', name: 'Bob')];

/// A draft whose position follows its position changes.
class _Draft extends StatefulWidget {
  const _Draft({required this.onPositionChange});
  final ValueChanged<MousePosition> onPositionChange;

  @override
  State<_Draft> createState() => _DraftState();
}

class _DraftState extends State<_Draft> {
  Offset position = const Offset(100, 100);

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned(
        left: position.dx,
        top: position.dy,
        child: CommentInput(
          position: position,
          onSubmit: (_, _) async {},
          onCancel: () {},
          users: _users,
          currentUser: _me,
          onPositionChange: (next) {
            widget.onPositionChange(next);
            setState(() => position = Offset(next.elementX, next.elementY));
          },
        ),
      ),
    ],
  );
}

void main() {
  late WorkflowStore store;
  late CommentsHarness h;

  setUp(() {
    useDifyTestTranslator();
    store = WorkflowStore();
    h = CommentsHarness();
  });
  tearDown(() {
    h.dispose();
    store.dispose();
  });

  Future<void> render(WidgetTester t, Widget child) async {
    await pumpComments(t, child, store: store, comments: h.store('user-1'));
    await settle(t);
  }

  Widget input({
    VoidCallback? onCancel,
    Future<void> Function(String, List<String>)? onSubmit,
    ValueChanged<MousePosition>? onPositionChange,
    bool disabled = false,
  }) => Stack(
    children: [
      CommentInput(
        position: Offset.zero,
        onSubmit: onSubmit ?? (_, _) async {},
        onCancel: onCancel ?? () {},
        users: _users,
        currentUser: _me,
        onPositionChange: onPositionChange,
        disabled: disabled,
      ),
    ],
  );

  Finder handle() => find.bySemanticsLabel('workflow.keyboard.moveDraftComment');

  group('CommentInput', () {
    testWidgets('moves the draft using a focused handle and finishes moving with Enter', (t) async {
      final semantics = t.ensureSemantics();
      final changes = <MousePosition>[];
      await render(t, _Draft(onPositionChange: changes.add));
      // The handle, focused (the text box has focus on open).
      t
          .widget<Focus>(find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'move draft comment'))
          .focusNode!
          .requestFocus();
      await t.pump();

      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      expect((changes.last.elementX, changes.last.elementY), (105, 120));
      expect(t.getSemantics(handle()), isSemantics(isToggled: true));

      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(t.getSemantics(handle()), isSemantics(isToggled: false));
      expect(changes, hasLength(2));

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      final field = t.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasPrimaryFocus, isTrue);
      semantics.dispose();
    });

    testWidgets('does not offer keyboard movement while disabled', (t) async {
      final semantics = t.ensureSemantics();
      await render(t, input(onPositionChange: (_) {}, disabled: true));
      expect(t.getSemantics(handle()), isSemantics(isEnabled: false));
      semantics.dispose();
    });

    testWidgets('passes translated placeholder to mention input', (t) async {
      await render(t, input());
      final m = t.widget<MentionInput>(find.byType(MentionInput));
      expect(m.placeholder, 'workflow.comments.placeholder.add');
      expect(m.autoFocus, isTrue);
      expect(m.disabled, isFalse);
    });

    testWidgets('calls onCancel when Escape is pressed', (t) async {
      var cancels = 0;
      await render(t, input(onCancel: () => cancels++));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(cancels, 1);
    });

    testWidgets('forwards mention submit to onSubmit', (t) async {
      final submitted = <(String, List<String>)>[];
      await render(t, input(onSubmit: (c, ids) async => submitted.add((c, ids))));
      await t.widget<MentionInput>(find.byType(MentionInput)).onSubmit('Hello', ['user-2']);
      expect(submitted.single.$1, 'Hello');
      expect(submitted.single.$2, ['user-2']);
    });
  });
}
