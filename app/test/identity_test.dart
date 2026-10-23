/// Protocol 1.8 identities in the editor: names, comment authors, mention candidates and online users are accounts.
library;

import 'package:dify_sf_app/src/design/widgets/text_line.dart';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comments_store.dart';
import 'package:dify_sf_app/src/workflow_editor/header/workflow_header.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

Future<void> _settle(WidgetTester t, [Duration d = const Duration(seconds: 2)]) async {
  final step = d.inSeconds >= 5 ? 500 : 100;
  for (var i = 0; i < d.inMilliseconds ~/ step; i++) {
    await t.pump(Duration(milliseconds: step));
  }
}

/// A workspace with Kim (owner) and Bo Chen (editor), each signed in through the fake accounts server.
Future<({FakeAccounts accounts, FakeServer server, AuthSession kim, AuthSession bo})> _workspace() async {
  final accounts = FakeAccounts();
  accounts
    ..addMember(email: 'kim@example.com', name: 'Kim')
    ..addMember(email: 'bo@example.com', name: 'Bo Chen', role: AccountRole.editor);
  Future<AuthSession> signIn(String email) async {
    final s = AuthSession(api: FakeAuthApi(accounts), server: 'fake');
    await s.login(email: email, password: 'password-1');
    return s;
  }

  return (
    accounts: accounts,
    server: FakeServer(accounts: accounts),
    kim: await signIn('kim@example.com'),
    bo: await signIn('bo@example.com'),
  );
}

void main() {
  testWidgets("a conflict notice names the other writer's account; the online user is the signed-in account", (
    t,
  ) async {
    await useAppFonts();
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final w = await t.runAsync(_workspace);
    final demo = DemoBackend(server: w!.server, auth: w.kim, boAuth: w.bo);
    final kim = w.kim.currentAccount!;
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Noto Sans'),
        home: EditorPage(backend: demo, docId: 'demo', journaled: false, account: kim, displayName: kim.name),
      ),
    );
    await _settle(t);
    final header = t.widget<WorkflowHeader>(find.byType(WorkflowHeader));
    expect(header.data.currentUserId, kim.id);
    expect(header.data.onlineUsers!.value.single.userId, kim.id);
    expect(header.data.onlineUsers!.value.single.username, 'Kim');

    // Kim edits offline while Bo changes the same field: Kim's edit is refused, the notice names Bo's account.
    await t.tap(find.byKey(const ValueKey('node-code')), warnIfMissed: false);
    await _settle(t, const Duration(seconds: 1));
    demo.setOffline(true);
    await _settle(t, const Duration(seconds: 1));
    final editor = find.descendant(of: find.byType(DifyCodeEditor), matching: find.byType(EditableText)).first;
    await t.enterText(editor, 'my code');
    await _settle(t);
    demo.boSets('code', ['code'], 'bo code');
    await _settle(t, const Duration(seconds: 35));
    demo.setOffline(false);
    await t.tap(find.byKey(const Key('reconnect-now')));
    await _settle(t, const Duration(seconds: 5));
    final notice = t.widget<DifyTextLine>(find.byKey(const Key('notice-message'))).data!;
    expect(notice, startsWith('Bo Chen changed code'));
    expect(w.server.clientAccounts.values.toSet(), {
      kim.id,
      w.bo.currentAccount!.id,
    }, reason: 'client ids bound to accounts');

    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });

  test('comments are by account: any client of the author edits, others are refused; members are the mention '
      'candidates', () async {
    final w = await _workspace();
    final kim = w.kim.currentAccount!, bo = w.bo.currentAccount!;
    CommentsStore store(AuthSession s, String clientId) => CommentsStore(
      api: FakeTransport(w.server, auth: s).comments,
      events: const Stream.empty(),
      clientId: () => clientId,
      userId: () => s.currentAccount!.id,
    );
    final tab1 = store(w.kim, 'kim-tab-1'), tab2 = store(w.kim, 'kim-tab-2'), boTab = store(w.bo, 'bo-tab');
    addTearDown(() {
      tab1.dispose();
      tab2.dispose();
      boTab.dispose();
    });
    final c = await tab1.create(x: 1, y: 2, content: 'mine', mentions: [bo.id]);
    expect((c.createdBy, c.createdByName), (kim.id, 'Kim'));
    expect(c.mentions.single.name, 'Bo Chen');

    await tab2.refresh();
    expect(tab2.isAuthor(tab2.byId(c.id)!), isTrue, reason: 'another client of the same account');
    final edited = await tab2.update(c.id, content: 'mine, edited in another tab');
    expect(edited.content, 'mine, edited in another tab');

    await boTab.refresh();
    expect(boTab.isAuthor(boTab.byId(c.id)!), isFalse);
    await expectLater(boTab.update(c.id, content: 'not yours'), throwsA(isA<TransportException>()));
    expect(boTab.lastError?.notAuthor, isTrue);

    await boTab.refreshNames();
    expect(boTab.names, {kim.id: 'Kim', bo.id: 'Bo Chen'});
  });
}
