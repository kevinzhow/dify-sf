import 'dart:async';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../session_factory.dart';

/// An in-memory server with a collaborator named Bo, for trying the editor without a server and for widget
/// tests. "Go offline" cuts the user's network; Bo's edits then conflict with the user's.
class DemoBackend implements Backend {
  DemoBackend({FakeServer? server, bool withBo = true})
    : server = server ?? FakeServer(),
      net = FakeNetwork(random: Random(3)) {
    net
      ..minLatency = const Duration(milliseconds: 10)
      ..maxLatency = const Duration(milliseconds: 60);
    if (withBo) unawaited(_startBo());
  }

  final FakeServer server;

  /// The user's network. Toggled by "Go offline".
  final FakeNetwork net;

  /// The user's journal; it outlives a simulated crash like a file would.
  final MemoryStore store = MemoryStore();

  CollabSession? bo;
  Timer? _boTimer;

  @override
  String get label => 'demo (in-memory server)';

  @override
  Future<String> prepare(String docId, {required bool create}) async => docId;

  @override
  Future<String> createDocument() async => 'demo';

  /// The in-memory server has no workflow-file converter (that lives in the Swift server).
  @override
  bool get supportsDifyDsl => false;

  @override
  Future<String> importDifyDsl(String yaml) => throw UnsupportedError('the demo cannot import Dify workflow files');

  @override
  Future<String> exportDifyDsl(String docId) => throw UnsupportedError('the demo cannot export Dify workflow files');

  @override
  Future<OpenedSession> openSession(
    String docId, {
    String? clientId,
    required bool journaled,
    String? displayName,
  }) async {
    return OpenedSession(
      CollabSession(
        clientId: clientId,
        transport: FakeTransport(server, network: net),
        store: store,
        journaled: journaled,
        displayName: displayName,
        tickInterval: const Duration(milliseconds: 100),
        postTimeout: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _startBo() async {
    final b = CollabSession(
      clientId: 'bo-${Random().nextInt(1 << 24).toRadixString(16).padLeft(6, '0')}',
      transport: FakeTransport(server, network: FakeNetwork(random: Random(9))),
      store: MemoryStore(),
    );
    bo = b;
    await b.start();
  }

  /// Bo overwrites a config field of [nodeId].
  void boSets(String nodeId, List<String> path, String text) {
    bo?.edit(SetField(nodeId, ConfigKey(path), VString(text)));
  }

  void boDeletes(String nodeId) => bo?.edit(RemoveNode(nodeId));

  /// Bo makes small random edits every [every] until [stopBoEdits].
  void startBoEdits({Duration every = const Duration(seconds: 2)}) {
    final editor = RandomEditor(Random(11), idPrefix: 'bo');
    _boTimer?.cancel();
    _boTimer = Timer.periodic(every, (_) {
      final b = bo;
      if (b == null || !b.hasState) return;
      final op = editor.next(b.view);
      if (op != null && op is! RemoveNode) b.edit(op);
    });
  }

  void stopBoEdits() => _boTimer?.cancel();

  bool get offline => net.partitioned;

  void setOffline(bool value) {
    net.partitioned = value;
    if (value) net.cutStreams();
  }

  Future<void> dispose() async {
    _boTimer?.cancel();
    await bo?.stop();
  }

  /// App-bar actions of the demo.
  List<Widget> actions(BuildContext context, EditorController c, VoidCallback crashAndRestart) {
    return [
      PopupMenuButton<String>(
        key: const Key('demo-menu'),
        tooltip: 'Demo controls',
        icon: const Icon(Icons.science_outlined),
        onSelected: (v) {
          final selected = c.selectedNodeId ?? 'llm';
          switch (v) {
            case 'offline':
              setOffline(!offline);
              if (!offline) c.reconnectNow(); // as an OS connectivity event would
            case 'bo-prompt':
              boSets(selected, ['prompt'], 'Bo rewrote this at ${DateTime.now().second}s');
            case 'bo-title':
              bo?.edit(SetField(selected, const TitleKey(), VString('Bo was here ${DateTime.now().second}')));
            case 'bo-delete':
              boDeletes(selected);
            case 'bo-random':
              _boTimer?.isActive ?? false ? stopBoEdits() : startBoEdits();
            case 'crash':
              crashAndRestart();
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'offline', child: Text(offline ? 'Go back online' : 'Go offline')),
          const PopupMenuItem(value: 'bo-prompt', child: Text('Bo rewrites the selected node\'s prompt')),
          const PopupMenuItem(value: 'bo-title', child: Text('Bo renames the selected node')),
          const PopupMenuItem(value: 'bo-delete', child: Text('Bo deletes the selected node')),
          const PopupMenuItem(value: 'bo-random', child: Text('Toggle Bo\'s random edits')),
          const PopupMenuItem(value: 'crash', child: Text('Crash the app and restart')),
        ],
      ),
    ];
  }
}
