import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';

import 'dart:async';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:flutter/material.dart';

import '../editor/editor_controller.dart';
import '../session_factory.dart';

/// An in-memory server with a collaborator named Bo, for trying the editor without a server and for widget
/// tests. "Go offline" cuts the user's network; Bo's edits then conflict with the user's.
///
/// With [auth] (and a server with accounts, protocol 1.8) the user's requests carry that session's token and Bo signs
/// in as [boAuth]: names, comment authors and roles are the accounts'. Without, the server checks nothing (as before
/// 1.8).
class DemoBackend implements DemoRunBackend {
  DemoBackend({FakeServer? server, bool withBo = true, this.auth, this.boAuth})
    : server = server ?? FakeServer(),
      net = FakeNetwork(random: Random(3)) {
    net
      ..minLatency = const Duration(milliseconds: 10)
      ..maxLatency = const Duration(milliseconds: 60);
    if (withBo) unawaited(_startBo());
  }

  final FakeServer server;

  /// The user's and Bo's sessions on a server with accounts (protocol 1.8); null without accounts.
  final TokenProvider? auth, boAuth;

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
  Future<String> exportDifyDsl(String docId, {bool includeSecret = false}) =>
      throw UnsupportedError('the demo cannot export Dify workflow files');

  @override
  Future<ReplaceResult> replaceDifyDsl(String docId, String yaml, CollabSession session, {bool confirm = false}) =>
      throw UnsupportedError('the demo cannot replace Dify workflow files');

  /// The demo document is a workflow without variables.
  @override
  Future<DocMeta> docMeta(String docId) async => const DocMeta();

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
        transport: FakeTransport(server, network: net, auth: auth),
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
      transport: FakeTransport(
        server,
        network: FakeNetwork(random: Random(9)),
        auth: boAuth,
      ),
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
      DifyActionMenu<String>(
        key: const Key('demo-menu'),
        tooltip: 'Demo controls',
        icon: const RemixIcon('flask-line'),
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
          DifyMenuOption(value: 'offline', child: DifyTextLine(offline ? 'Go back online' : 'Go offline')),
          const DifyMenuOption(value: 'bo-prompt', child: DifyTextLine('Bo rewrites the selected node\'s prompt')),
          const DifyMenuOption(value: 'bo-title', child: DifyTextLine('Bo renames the selected node')),
          const DifyMenuOption(value: 'bo-delete', child: DifyTextLine('Bo deletes the selected node')),
          const DifyMenuOption(value: 'bo-random', child: DifyTextLine('Toggle Bo\'s random edits')),
          const DifyMenuOption(value: 'crash', child: DifyTextLine('Crash the app and restart')),
        ],
      ),
    ];
  }
}
