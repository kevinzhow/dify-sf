/// Protocol 1.8: the account's role is changed to a read-only one while the editor is open. The server refuses the
/// session's edits (`403 forbidden`): one notice, the editor turns read-only, nothing more is sent; when the role
/// allows editing again (re-read from `GET /v1/account`), the editor is editable again.
library;

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/editor/notices.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

Future<void> _settle(WidgetTester t, [Duration d = const Duration(seconds: 2)]) async {
  final step = d.inSeconds >= 5 ? 500 : 100;
  for (var i = 0; i < d.inMilliseconds ~/ step; i++) {
    await t.pump(Duration(milliseconds: step));
  }
}

/// Counts the edit-role checks of the in-memory server: one per `POST /ops` that reaches it (refused ones too).
class _CountingAccounts extends FakeAccounts {
  int editChecks = 0;
  @override
  FakeAccount principal(String? accessToken, {bool edit = false, bool privileged = false}) {
    if (edit) editChecks++;
    return super.principal(accessToken, edit: edit, privileged: privileged);
  }
}

void main() {
  testWidgets('role downgraded mid-session: one notice, read-only, no further POSTs; promoted back: editable', (
    t,
  ) async {
    await useAppFonts();
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final accounts = _CountingAccounts()
      ..addMember(email: 'olivia@example.com', name: 'Olivia')
      ..addMember(email: 'ed@example.com', name: 'Ed', role: AccountRole.editor);
    final ed = AuthSession(api: FakeAuthApi(accounts), server: 'fake');
    await t.runAsync(() => ed.login(email: 'ed@example.com', password: 'password-1'));
    final server = FakeServer(accounts: accounts);
    final demo = DemoBackend(server: server, auth: ed, withBo: false);
    var accountReads = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Noto Sans'),
        home: EditorPage(
          backend: demo,
          docId: 'demo',
          journaled: false,
          account: ed.currentAccount,
          refreshAccount: () {
            accountReads++;
            return ed.account();
          },
        ),
      ),
    );
    await _settle(t);
    final node = find.byKey(const ValueKey('node-llm'));
    final store = WorkflowStoreScope.of(t.element(node));
    expect(store.canvasReadOnly.value, isFalse);

    // Ed moves a node: saved.
    await t.drag(node, const Offset(100, 60));
    await _settle(t);
    final head = server.head;
    expect(head, greaterThan(0));

    // An admin makes Ed a normal member. Ed's next move is refused as a whole: one notice, the canvas turns read-only.
    accounts.byEmail('ed@example.com')!.role = AccountRole.normal;
    final xBefore = server.doc.nodes['llm']!.x;
    await t.drag(node, const Offset(-80, 40));
    await _settle(t, const Duration(seconds: 3));
    expect(find.text(forbiddenNoticeMessage), findsOneWidget);
    expect(store.canvasReadOnly.value, isTrue);
    expect(server.head, head, reason: 'not saved');
    expect(server.doc.nodes['llm']!.x, xBefore);
    expect(accountReads, 1, reason: 'the account is re-read once at the refusal');
    final checks = accounts.editChecks;

    // Read-only from now on: a drag does nothing, and nothing is sent, however long we wait (the role is re-read now
    // and then, still normal).
    await t.drag(node, const Offset(60, 60));
    await _settle(t, const Duration(seconds: 70));
    expect(accounts.editChecks, checks, reason: 'no further POST');
    expect(server.head, head);
    expect(find.text(forbiddenNoticeMessage), findsOneWidget, reason: 'still one notice');
    expect(store.canvasReadOnly.value, isTrue);
    expect(accountReads, greaterThan(1));

    // Promoted back to editor: the next re-read makes the editor editable, and edits are saved again.
    accounts.byEmail('ed@example.com')!.role = AccountRole.editor;
    await _settle(t, const Duration(seconds: 31));
    expect(store.canvasReadOnly.value, isFalse);
    final x = server.doc.nodes['llm']!.x;
    await t.drag(node, const Offset(100, 0));
    await _settle(t);
    expect(server.head, greaterThan(head));
    expect(server.doc.nodes['llm']!.x, greaterThan(x + 50));

    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}
