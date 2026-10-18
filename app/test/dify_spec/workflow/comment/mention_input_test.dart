// dify-spec: web/app/components/workflow/comment/mention-input.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/comments/comment_input.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';
import 'comment_harness.dart';

const _users = [(id: 'user-2', name: 'Alice'), (id: 'user-3', name: 'Bob')];

class _Controlled extends StatefulWidget {
  const _Controlled({required this.onSubmit});
  final Future<void> Function(String, List<String>) onSubmit;

  @override
  State<_Controlled> createState() => _ControlledState();
}

class _ControlledState extends State<_Controlled> {
  String value = '';

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 360,
    child: MentionInput(
      value: value,
      onChange: (v) => setState(() => value = v),
      onSubmit: widget.onSubmit,
      users: _users,
    ),
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
    await pumpComments(
      t,
      Align(alignment: Alignment.topLeft, child: child),
      store: store,
      comments: h.store('u'),
    );
    await settle(t);
  }

  group('MentionInput', () {
    testWidgets('selects a mention and submits with mentioned user ids', (t) async {
      final submitted = <(String, List<String>)>[];
      await render(t, _Controlled(onSubmit: (c, ids) async => submitted.add((c, ids))));
      expect(find.text('workflow.comments.placeholder.add'), findsOneWidget);
      await t.enterText(find.byType(TextField), '@Ali');
      await t.pump();
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsNothing, reason: 'filtered by what follows @');

      await t.tap(find.text('Alice'));
      await t.pump();
      await t.enterText(find.byType(TextField), '@Alice hi');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(submitted.single.$1, '@Alice hi');
      expect(submitted.single.$2, ['user-2']);
    });

    testWidgets('supports editing mode cancel and save actions', (t) async {
      final submitted = <(String, List<String>)>[];
      var cancels = 0;
      await render(
        t,
        SizedBox(
          width: 360,
          child: MentionInput(
            value: '  updated reply  ',
            onChange: (_) {},
            onSubmit: (c, ids) async => submitted.add((c, ids)),
            onCancel: () => cancels++,
            users: _users,
            isEditing: true,
          ),
        ),
      );
      await t.tap(find.text('common.operation.cancel'));
      expect(cancels, 1);
      await t.tap(find.text('common.operation.save'));
      await t.pump();
      expect(submitted.single.$1, 'updated reply');
      expect(submitted.single.$2, isEmpty);
    });

    testWidgets('focuses the textarea at the end when autoFocus is enabled', (t) async {
      await render(
        t,
        SizedBox(
          width: 360,
          child: MentionInput(
            value: 'draft',
            onChange: (_) {},
            onSubmit: (_, _) async {},
            users: _users,
            autoFocus: true,
          ),
        ),
      );
      final field = t.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasPrimaryFocus, isTrue);
      expect(field.controller!.selection, const TextSelection.collapsed(offset: 5));
    });
  });
}
