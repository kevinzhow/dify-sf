import 'dart:async';

import 'package:collab_client/collab_client.dart' show DocMeta;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_api.dart';
import '../auth/auth_controller.dart';
import '../design/widgets/toast.dart';
import '../online_events.dart';
import '../session_factory.dart';
import '../workflow_editor/dify_editor.dart';
import 'notice_overlay.dart';
import 'editor_controller.dart';

/// Opens a document and shows the editor. Owns the session lifecycle.
class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.backend,
    required this.docId,
    this.clientId,
    this.displayName,
    required this.journaled,
    this.create = true,
    this.extraActions,
    this.account,
    this.refreshAccount,
    this.locateNodeId,
  });

  final Backend backend;
  final String docId;

  /// The signed-in account (protocol 1.8): its role decides whether the editor is read-only (Dify's `canEdit`), its
  /// name and avatar are the user's in the editor. Null: no accounts (the demo, tests), full access.
  final Account? account;

  /// `GET /v1/account` (protocol 1.8), for when the server refuses this session's edits with `403 forbidden` (the
  /// account's role was changed to a read-only one mid-session): the editor turns read-only, re-reads the account, and
  /// becomes editable again once the role allows it. Null: the [AuthScope]'s session, if any.
  final Future<Account> Function()? refreshAccount;

  /// A node to select and bring into view once the document is loaded (the launch's `node_id`).
  final String? locateNodeId;

  /// Explicit client id (tests, demo); null = issued by the server and kept in the journal.
  final String? clientId;

  /// Shown to others in conflict notices (protocol 1.3); null = unnamed.
  final String? displayName;
  final bool journaled;
  final bool create;

  /// Demo/debug actions for the app bar, built with the live controller.
  final List<Widget> Function(BuildContext context, EditorController controller, VoidCallback crashAndRestart)?
  extraActions;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> with WidgetsBindingObserver {
  EditorController? _controller;
  OpenedSession? _opened;
  Object? _error;

  /// The document's Dify app metadata; the defaults (a workflow, no variables) until it arrives or if it cannot be read.
  DocMeta _meta = const DocMeta();
  var _generation = 0;
  void Function()? _stopOnlineListener;

  /// The account as last read: [EditorPage.account], then whatever re-reading it after a refusal answered.
  Account? _account;
  bool _checkingRole = false;

  /// Re-reads the account while the server refuses this session's edits, until its role allows editing again.
  Timer? _rolePoll;
  static const _roleRecheckEvery = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _account = widget.account;
    WidgetsBinding.instance.addObserver(this);
    _stopOnlineListener = listenForOnline(() => _controller?.reconnectNow());
    unawaited(_open());
  }

  /// Coming back to the window is the best "the network may be back" hint a pure-Flutter app gets.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _controller?.reconnectNow();
    if (_controller?.editingForbidden ?? false) unawaited(_recheckRole());
  }

  @override
  void didUpdateWidget(EditorPage old) {
    super.didUpdateWidget(old);
    if (widget.account != old.account) _account = widget.account;
  }

  /// After a `403 forbidden` on this session's edits: re-reads the account (`GET /v1/account`). An edit role (promoted
  /// back, or the refusal was not about the role) resumes editing; otherwise the editor stays read-only and the account
  /// is read again every [_roleRecheckEvery] and when the window comes back.
  Future<void> _recheckRole() async {
    final c = _controller;
    final refresh = widget.refreshAccount ?? AuthScope.read(context)?.session.account;
    if (c == null || refresh == null || _checkingRole || !c.editingForbidden) return;
    _checkingRole = true;
    try {
      final a = await refresh();
      if (!mounted || c != _controller) return;
      setState(() => _account = a);
      if (a.canEdit) {
        _rolePoll?.cancel();
        _rolePoll = null;
        c.allowEdits();
      } else {
        _pollRole();
      }
    } on Object {
      if (mounted && c == _controller) _pollRole(); // unreachable: try again later
    } finally {
      _checkingRole = false;
    }
  }

  void _pollRole() {
    _rolePoll ??= Timer.periodic(_roleRecheckEvery, (_) {
      if (_controller?.editingForbidden ?? false) {
        unawaited(_recheckRole());
      } else {
        _rolePoll?.cancel();
        _rolePoll = null;
      }
    });
  }

  Future<void> _open() async {
    final gen = ++_generation;
    setState(() => _error = null);
    try {
      await widget.backend.prepare(widget.docId, create: widget.create);
      final opened = await widget.backend.openSession(
        widget.docId,
        clientId: widget.clientId,
        journaled: widget.journaled,
        displayName: widget.displayName,
      );
      final session = opened.session;
      try {
        await session.start();
      } on Object {
        await opened.close();
        rethrow;
      }
      if (!mounted || gen != _generation) {
        await opened.close();
        return;
      }
      final controller = EditorController(
        session: session,
        docId: widget.docId,
        journaled: widget.journaled,
        onEditingForbidden: () => unawaited(_recheckRole()),
      )..addListener(_rebuild);
      setState(() {
        _opened = opened;
        _controller = controller;
      });
      unawaited(_loadMeta(gen));
    } on Object catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e);
    }
  }

  /// Never keeps the document from opening: a failure (an older server, no network) leaves the defaults.
  Future<void> _loadMeta(int gen) async {
    final DocMeta meta;
    try {
      meta = await widget.backend.docMeta(widget.docId);
    } on Object {
      return;
    }
    if (mounted && gen == _generation) setState(() => _meta = meta);
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// Closes the session without any goodbye (like a killed process) and boots a new one from whatever the
  /// journal holds. Only used by the demo's "crash" button.
  Future<void> _crashAndRestart() async {
    final old = _controller;
    final oldOpened = _opened;
    _generation++;
    _rolePoll?.cancel();
    _rolePoll = null;
    setState(() {
      _controller = null;
      _opened = null;
    });
    old?.removeListener(_rebuild);
    old?.dispose();
    await oldOpened?.close();
    await _open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopOnlineListener?.call();
    _rolePoll?.cancel();
    _generation++;
    _controller?.removeListener(_rebuild);
    _controller?.dispose();
    unawaited(_opened?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(body: _body(context, c));
  }

  /// Shows the current state as a Dify workflow file, ready to copy into Dify's "Import DSL".
  Future<void> _exportDifyDsl(BuildContext context, {bool includeSecret = false}) async {
    String yaml;
    try {
      yaml = await widget.backend.exportDifyDsl(widget.docId, includeSecret: includeSecret);
    } on Object catch (e) {
      if (context.mounted) toast.error('Export failed: $e');
      return;
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dify workflow file'),
        content: SizedBox(
          width: 640,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              yaml,
              key: const Key('export-dsl-text'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('export-dsl-copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: yaml));
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                toast.success('Copied the workflow file');
              }
            },
            child: const Text('Copy'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  /// The role's access (Dify's `canEdit`), read-only while the server refuses this session's edits.
  WorkflowAccessControl get _access {
    final a = _account;
    if (_controller?.editingForbidden ?? false) return WorkflowAccessControl.viewOnly;
    return a == null || a.canEdit ? WorkflowAccessControl.full : WorkflowAccessControl.viewOnly;
  }

  List<Widget> _actions(BuildContext context, EditorController c) {
    final access = _access;
    return [
      if (access.canEdit)
        PopupMenuButton<String>(
          key: const Key('add-node-menu'),
          tooltip: 'Add node',
          icon: const Icon(Icons.add_box_outlined),
          onSelected: (type) =>
              c.addNode(type, x: 120 + (c.doc.nodes.length % 5) * 40, y: 280 + (c.doc.nodes.length % 4) * 40),
          itemBuilder: (_) => [
            for (final t in const ['start', 'llm', 'code', 'answer'])
              PopupMenuItem(value: t, child: Text('Add $t node')),
          ],
        ),
      if (widget.backend.supportsDifyDsl && access.canImportExportDsl)
        IconButton(
          key: const Key('export-dsl'),
          tooltip: 'Export as a Dify workflow file',
          icon: const Icon(Icons.file_download_outlined),
          onPressed: () => unawaited(_exportDifyDsl(context)),
        ),
      if (widget.extraActions != null) ...widget.extraActions!(context, c, () => unawaited(_crashAndRestart())),
      const SizedBox(width: 8),
    ];
  }

  Widget _body(BuildContext context, EditorController? c) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.black38),
            const SizedBox(height: 12),
            Text('Could not open "${widget.docId}"', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            SizedBox(
              width: 420,
              child: Text(
                '$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _open, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (c == null) return const Center(child: CircularProgressIndicator());
    if (!c.ready) {
      // Until the document arrives: the session controls (offline, reconnect) and its notices stay reachable.
      return Stack(
        children: [
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Loading the document…')],
            ),
          ),
          Positioned(
            top: 16,
            right: 12,
            child: SessionBadge(controller: c, serverLabel: widget.backend.label, actions: _actions(context, c)),
          ),
          NoticeOverlay(controller: c),
        ],
      );
    }
    return DifyWorkflowEditor(
      controller: c,
      serverLabel: widget.backend.label,
      actions: _actions(context, c),
      meta: _meta,
      access: _access,
      locateNodeId: widget.locateNodeId,
      onExportDsl: (includeSecret) => _exportDifyDsl(context, includeSecret: includeSecret),
      user: switch (_account) {
        final a? => EditorUser(id: a.id, name: a.name, avatarUrl: a.avatarUrl),
        null => null,
      },
    );
  }
}
