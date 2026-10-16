import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../session_factory.dart';
import 'canvas_view.dart';
import 'editor_controller.dart';
import 'node_panel.dart';
import 'notice_overlay.dart';
import 'status_bar.dart';

/// Opens a document and shows the editor. Owns the session lifecycle.
class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.backend,
    required this.docId,
    required this.clientId,
    required this.journaled,
    this.create = true,
    this.extraActions,
  });

  final Backend backend;
  final String docId;
  final String clientId;
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
  CollabSession? _session;
  Object? _error;
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_open());
  }

  /// Coming back to the window is the best "the network may be back" hint a pure-Flutter app gets.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _controller?.reconnectNow();
  }

  Future<void> _open() async {
    final gen = ++_generation;
    setState(() => _error = null);
    try {
      await widget.backend.prepare(widget.docId, create: widget.create);
      final session = await widget.backend.openSession(
        widget.docId,
        clientId: widget.clientId,
        journaled: widget.journaled,
      );
      await session.start();
      if (!mounted || gen != _generation) {
        await session.stop();
        return;
      }
      final controller = EditorController(
        session: session,
        docId: widget.docId,
        journaled: widget.journaled,
      )..addListener(_rebuild);
      setState(() {
        _session = session;
        _controller = controller;
      });
    } on Object catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e);
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  /// Closes the session without any goodbye (like a killed process) and boots a new one from whatever the
  /// journal holds. Only used by the demo's "crash" button.
  Future<void> _crashAndRestart() async {
    final old = _controller;
    final oldSession = _session;
    _generation++;
    setState(() {
      _controller = null;
      _session = null;
    });
    old?.removeListener(_rebuild);
    old?.dispose();
    await oldSession?.stop();
    await _open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _controller?.removeListener(_rebuild);
    _controller?.dispose();
    unawaited(_session?.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      appBar: AppBar(
        title: Text('Workflow · ${widget.docId}'),
        actions: [
          if (c != null) ..._actions(context, c),
        ],
      ),
      body: _body(context, c),
    );
  }

  List<Widget> _actions(BuildContext context, EditorController c) {
    return [
      PopupMenuButton<String>(
        key: const Key('add-node-menu'),
        tooltip: 'Add node',
        icon: const Icon(Icons.add_box_outlined),
        onSelected: (type) => c.addNode(type, x: 120 + (c.doc.nodes.length % 5) * 40, y: 280 + (c.doc.nodes.length % 4) * 40),
        itemBuilder: (_) => [
          for (final t in const ['start', 'llm', 'code', 'answer']) PopupMenuItem(value: t, child: Text('Add $t node')),
        ],
      ),
      if (widget.extraActions != null) ...widget.extraActions!(context, c, () => unawaited(_crashAndRestart())),
      const SizedBox(width: 8),
    ];
  }

  Widget _body(BuildContext context, EditorController? c) {
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.cloud_off, size: 48, color: Colors.black38),
          const SizedBox(height: 12),
          Text('Could not open "${widget.docId}"', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          SizedBox(width: 420, child: Text('$_error', textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54))),
          const SizedBox(height: 16),
          FilledButton(onPressed: _open, child: const Text('Retry')),
        ]),
      );
    }
    if (c == null) return const Center(child: CircularProgressIndicator());
    return Column(children: [
      Expanded(
        child: Row(children: [
          Expanded(
            child: Stack(children: [
              if (c.ready)
                CanvasView(controller: c)
              else
                const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Loading the document…'),
                ])),
              if (c.selectedEdgeId != null && c.ready)
                Positioned(
                  top: 12,
                  left: 12,
                  child: Chip(
                    avatar: const Icon(Icons.timeline, size: 16),
                    label: const Text('Connection selected — details on the right'),
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                  ),
                ),
              NoticeOverlay(controller: c),
            ]),
          ),
          NodePanel(controller: c),
        ]),
      ),
      StatusBar(controller: c, clientId: widget.clientId, serverLabel: widget.backend.label),
    ]);
  }
}
