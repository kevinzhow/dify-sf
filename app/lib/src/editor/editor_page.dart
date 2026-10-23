import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';

import 'dart:async';

import 'package:collab_client/collab_client.dart'
    show AppEvent, AppInfoAccess, DocMeta, LinkState, ReplaceResult, TransportException, VersionsApi;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_detail/detail_page_slot.dart';
import '../auth/auth_api.dart';
import '../settings/model_provider/model_provider_env.dart';
import '../auth/auth_controller.dart';
import '../i18n/dify_i18n.dart';
import '../online_events.dart';
import '../open_url.dart';
import '../session_factory.dart';
import '../workflow/workspace_models.dart';
import '../workflow_editor/dify_editor.dart';
import '../workflow_editor/dsl/update_dsl_modal.dart' show WorkflowImport;
import '../workflow_editor/run/server_run_service.dart' show ServerWorkflowRuntime;
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
    this.models,
    this.openModelProviderSettings,
    this.isAppDeleted,
    this.versions,
    this.serverRuntime,
    this.appName,
    this.onImportAvailable,
    this.onAppChanged,
  });

  /// The app changed on the server (protocol 1.11 `event: app`, Dify's `app_meta_update`: renamed, new icon, site or
  /// switches), or the stream reconnected and may have missed such a notice: the host refetches the app.
  final VoidCallback? onAppChanged;

  /// The app's name as the app detail page shows it (it follows renames there); null: the document's.
  final String? appName;

  /// Hands the host the editor's "replace the workflow with a DSL file" once the session is up, and null when the
  /// editor closes (the app detail sidebar's Import DSL runs through it).
  final ValueChanged<WorkflowImport?>? onImportAvailable;

  /// Publishing and versions (protocol 1.11); null: the app detail page's `VersionsApi` service when the editor is one
  /// of its pages, else none (the publisher publishes nothing, the version history shows the draft alone).
  final VersionsApi? versions;

  /// The server's workflow runtime (protocol 1.13): single runs of the node types it runs go to the server; null: the
  /// app detail page's `ServerWorkflowRuntime` service when the editor is one of its pages (present when the server has a
  /// runtime), else none (remote execution is unavailable; only the local demo simulates it).
  final ServerWorkflowRuntime? serverRuntime;

  /// Protocol 1.10: whether the app (= this document) was deleted (`GET /v1/apps/{id}` answers 404). Asked when the
  /// document cannot be opened or its connection keeps failing (at most every 5 s); a deleted app closes the editor
  /// with a toast (back to the Studio) instead of retrying. Null: never asked.
  final Future<bool> Function()? isAppDeleted;

  /// The workspace's model providers and models (protocol 1.9), loaded when the editor opens; null: none (the demo).
  final WorkspaceModels? models;

  /// Opens the model provider settings (Dify's settings destination `provider`).
  final Future<void> Function(BuildContext context)? openModelProviderSettings;

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
    // The editor's model services: providers, model lists and default models, fresh for this document.
    if (widget.models case final models?) unawaited(models.load());
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
      await _appEvents?.cancel();
      _appEvents = session.appEvents.listen((_) => widget.onAppChanged?.call());
      if (widget.backend.supportsDifyDsl) widget.onImportAvailable?.call(_importDifyDsl);
      unawaited(_loadMeta(gen));
    } on Object catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e);
      if (e is TransportException && e.statusCode == 404) unawaited(_checkDeleted());
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
    // A failing connection may mean the app is gone (its document answers 404 `app_deleted`): ask the apps API.
    final status = _controller?.status;
    if (status != null && status.lastError != null && status.link != LinkState.live) unawaited(_checkDeleted());
  }

  bool _checkingDeleted = false, _deleted = false;
  DateTime? _deletedCheckedAt;

  /// Leaves the editor when the app was deleted (at most one check every 5 s while the stream keeps failing).
  Future<void> _checkDeleted() async {
    final check = widget.isAppDeleted;
    final now = DateTime.now();
    if (check == null || _checkingDeleted || _deleted) return;
    if (_deletedCheckedAt != null && now.difference(_deletedCheckedAt!) < const Duration(seconds: 5)) return;
    _checkingDeleted = true;
    _deletedCheckedAt = now;
    try {
      if (!await check() || !mounted) return;
      _deleted = true;
      toast.warning(DifyI18n.tr('app', 'appDeleted'));
      Navigator.of(context).maybePop();
    } on Object {
      // Unreachable server: the session keeps reconnecting; the next failure asks again.
    } finally {
      _checkingDeleted = false;
    }
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

  /// The session's app notices ([EditorPage.onAppChanged]).
  StreamSubscription<AppEvent>? _appEvents;

  @override
  void dispose() {
    unawaited(_appEvents?.cancel());
    widget.onImportAvailable?.call(null);
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
    return DifyPage(body: _body(context, c));
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
    await showDifyDialog<void>(
      context,
      barrierColor: materialDialogBarrierColor,
      transition: DifyDialogTransition.fade,
      builder: (ctx) => DifyContentDialog(
        title: const DifyTextLine('Dify workflow file'),
        content: SizedBox(
          width: 640,
          height: 420,
          child: SingleChildScrollView(
            child: DifySelectableText(
              yaml,
              key: const Key('export-dsl-text'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          DifyButton(
            variant: DifyButtonVariant.ghost,
            key: const Key('export-dsl-copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: yaml));
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                toast.success('Copied the workflow file');
              }
            },
            child: const DifyTextLine('Copy'),
          ),
          DifyButton(
            variant: DifyButtonVariant.ghost,
            onPressed: () => Navigator.pop(ctx),
            child: const DifyTextLine('Close'),
          ),
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
        DifyActionMenu<String>(
          key: const Key('add-node-menu'),
          tooltip: 'Add node',
          icon: const RemixIcon('add-box-line'),
          onSelected: (type) =>
              c.addNode(type, x: 120 + (c.doc.nodes.length % 5) * 40, y: 280 + (c.doc.nodes.length % 4) * 40),
          itemBuilder: (_) => [
            for (final t in const ['start', 'llm', 'code', 'answer'])
              DifyMenuOption(value: t, child: DifyTextLine('Add $t node')),
          ],
        ),
      if (widget.backend.supportsDifyDsl && access.canImportExportDsl)
        DifyIconButton(
          size: DifyIconButtonSize.lg,
          key: const Key('export-dsl'),
          label: 'Export as a Dify workflow file',
          icon: const RemixIcon('download-line'),
          onPressed: () => unawaited(_exportDifyDsl(context)),
        ),
      if (widget.extraActions != null) ...widget.extraActions!(context, c, () => unawaited(_crashAndRestart())),
      const SizedBox(width: 8),
    ];
  }

  Future<ReplaceResult> _importDifyDsl(String yaml, {bool confirm = false}) async {
    final c = _controller!;
    final selectedNode = c.selectedNodeId, selectedEdge = c.selectedEdgeId;
    final result = await widget.backend.replaceDifyDsl(widget.docId, yaml, c.session, confirm: confirm);
    DocMeta? meta;
    try {
      meta = await widget.backend.docMeta(widget.docId);
    } on Object {
      toast.warning('Workflow imported. Could not refresh application details.');
    }
    if (!mounted || c != _controller) return result;
    c.undo.clear();
    final node = result.renamedNodes[selectedNode] ?? selectedNode;
    final edge = result.renamedEdges[selectedEdge] ?? selectedEdge;
    if (node != null && c.doc.nodes.containsKey(node)) {
      c.selectNode(node);
    } else if (edge != null && c.doc.edges.containsKey(edge)) {
      c.selectEdge(edge);
    } else {
      c.selectNode(null);
      c.selectEdge(null);
    }
    if (meta != null) setState(() => _meta = meta!);
    return result;
  }

  Widget _body(BuildContext context, EditorController? c) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const RemixIcon('cloud-off-line', size: 48, color: Colors.black38),
            const SizedBox(height: 12),
            DifyTextLine('Could not open "${widget.docId}"', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            SizedBox(
              width: 420,
              child: DifyTextLine(
                '$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54),
              ),
            ),
            const SizedBox(height: 16),
            DifyButton(variant: DifyButtonVariant.primary, onPressed: _open, child: const DifyTextLine('Retry')),
          ],
        ),
      );
    }
    if (c == null) return const Center(child: DifyLoading());
    if (!c.ready) {
      // Until the document arrives: the session controls (offline, reconnect) and its notices stay reachable.
      return Stack(
        children: [
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [DifyLoading(), SizedBox(height: 12), DifyTextLine('Loading the document…')],
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
      allowMockRuns: widget.backend is DemoRunBackend,
      actions: _actions(context, c),
      meta: switch (widget.appName) {
        final name? when name != _meta.appName => DocMeta(
          appMode: _meta.appMode,
          appName: name,
          environmentVariables: _meta.environmentVariables,
          conversationVariables: _meta.conversationVariables,
          raw: _meta.raw,
        ),
        _ => _meta,
      },
      access: _access,
      locateNodeId: widget.locateNodeId,
      onExportDsl: (includeSecret) => _exportDifyDsl(context, includeSecret: includeSecret),
      onImportDsl: widget.backend.supportsDifyDsl ? _importDifyDsl : null,
      models: widget.models,
      modelProviderEnv: widget.models == null ? null : ModelProviderEnv.forRole(widget.models!, _account?.role),
      openModelProviderSettings: switch (widget.openModelProviderSettings) {
        final open? => () => unawaited(open(context)),
        null => null,
      },
      user: switch (_account) {
        final a? => EditorUser(id: a.id, name: a.name, avatarUrl: a.avatarUrl),
        null => null,
      },
      versions: widget.versions ?? AppDetailContext.maybeOf(context)?.service<VersionsApi>(),
      // Unsupported remote execution reports an error; only the explicit demo uses simulated runs.
      serverRuntime: widget.serverRuntime ?? AppDetailContext.maybeOf(context)?.service<ServerWorkflowRuntime>(),
      publisher: _publisherHost(context),
    );
  }

  /// The publisher's view of the app detail page around the editor (none: no web app address, no Access Point).
  EditorPublisherHost _publisherHost(BuildContext context) {
    final detail = AppDetailContext.maybeOf(context);
    if (detail == null) return const EditorPublisherHost(onOpenLink: _openExternalOnly);
    final app = detail.app.value, site = app.site;
    return EditorPublisherHost(
      appBaseUrl: site?.appBaseUrl ?? '',
      accessToken: site?.accessToken ?? '',
      canViewAccessPoint: detail.capabilities.canViewAccessPoint,
      onOpenLink: (link, {required external}) {
        if (external) {
          unawaited(openExternalUrl(link));
        } else if (AppDetailPageId.fromPath(link) case final page?) {
          detail.navigate(page);
        }
      },
      // Dify reloads the app detail after publishing (the Access Point's availability follows the published version).
      onPublished: () => unawaited(detail.refreshApp()),
    );
  }

  static void _openExternalOnly(String link, {required bool external}) {
    if (external) unawaited(openExternalUrl(link));
  }
}
