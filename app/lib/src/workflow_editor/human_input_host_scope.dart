/// The editor's [HumanInputHost] (protocol 1.16): Dify's `useMembers()`, `userProfile`, `currentWorkspace` and the
/// human-input services, handed to the node panel and the run panel. The members come from the comments directory
/// (`/comments/mention-users`), which the editor already keeps; the calls exist only when the server announces human
/// input (`workflow_runtime.human_input`), so a server without it leaves the panel's email actions disabled.
library;

import 'package:flutter/material.dart';

import '../settings/workspace_members.dart' show workspaceNameOf;
import 'comments/comments_store.dart';
import 'node_panel/bodies/data/human_input/human_input_kit.dart';

class HumanInputHostScope extends StatelessWidget {
  const HumanInputHostScope({
    super.key,
    required this.store,
    required this.userId,
    required this.userName,
    this.sendTestEmail,
    this.fetchGeneratedForm,
    this.submitGeneratedForm,
    this.onUpgrade,
    required this.child,
  });

  /// The workspace's members, id → user (`CommentsStore.users`); it notifies when the directory loads.
  final CommentsStore store;

  /// The signed-in account: its email is the debug recipient and the forms' "who" line.
  final String? userId;
  final String userName;

  final SendTestEmail? sendTestEmail;
  final FetchGeneratedForm? fetchGeneratedForm;
  final SubmitGeneratedForm? submitGeneratedForm;
  final VoidCallback? onUpgrade;

  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final users = store.users.values.toList();
      final owner = users.where((u) => u.role == 'owner').firstOrNull;
      return HumanInputHost(
        members: [
          for (final u in users)
            HiMember(id: u.id, email: u.email, name: u.name, avatarUrl: u.avatarUrl, status: 'active'),
        ],
        userEmail: userId == null ? '' : (store.users[userId]?.email ?? ''),
        userName: userName,
        workspaceName: owner == null ? '' : workspaceNameOf(owner.name),
        // Self-hosted Dify always allows the email delivery (`FeatureService._resolve_human_input_email_delivery_enabled`).
        emailDeliveryEnabled: true,
        sendTestEmail: sendTestEmail,
        fetchGeneratedForm: fetchGeneratedForm,
        submitGeneratedForm: submitGeneratedForm,
        onUpgrade: onUpgrade,
        child: child,
      );
    },
  );
}
