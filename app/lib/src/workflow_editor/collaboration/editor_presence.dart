import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../design/widgets/toast.dart';
import '../../editor/editor_controller.dart';
import '../context_menu/clipboard.dart';
import '../header/header_data.dart';

/// Presence in the editor (protocol 1.22; Dify 1.17.1's collaboration): who else has this workflow open, where their
/// pointer is and which node's panel they have open, from the session's [SessionPresence]; and what this editor reports
/// (its pointer over the canvas and its open panel). Read by the header's online users, the remote cursors
/// (`UserCursors`) and the avatars on nodes (`NodeViewers`).
class EditorPresence extends ChangeNotifier {
  EditorPresence(this.controller, {required this.self, this.selfName = '', this.selfAvatar, this.toasts = true}) {
    _sub = presence.changes.listen(_changed);
    controller.addListener(_selectionChanged);
    presence.enable();
    _selectionChanged();
    _publishUsers();
  }

  final EditorController controller;

  /// The signed-in account (or, without accounts, the client id): never drawn as a collaborator.
  final String self;
  final String selfName;
  final String? selfAvatar;

  /// Show "… joined" / "… left" (dify-sf only; Dify shows none).
  final bool toasts;

  late final StreamSubscription<PresenceChange> _sub;
  SessionPresence get presence => controller.session.presence;

  /// The header's online users: this user first, then the others in the order they arrived.
  final onlineUsers = ValueNotifier<List<OnlineUser>>(const []);

  /// Everyone else present, in the order they arrived.
  List<PresenceUser> get others => _others ??= [
    for (final u in presence.users.values)
      if (u.account != self) u,
  ]..sort((a, b) => a.since.compareTo(b.since));
  List<PresenceUser>? _others;

  /// Who (others) has which node's panel open, in the order they arrived.
  Map<String, List<PresenceUser>> get viewersByNode => _byNode ??= () {
    final m = <String, List<PresenceUser>>{};
    for (final u in others) {
      for (final p in u.panels) {
        (m[p] ??= []).add(u);
      }
    }
    return m;
  }();
  Map<String, List<PresenceUser>>? _byNode;

  /// [account]'s pointer on the canvas (canvas coordinates), if it is over the canvas.
  Offset? cursorOf(String account) {
    final c = presence.users[account]?.cursor;
    return c == null ? null : Offset(c.x, c.y);
  }

  /// The others who have [node]'s panel open, in the order they arrived.
  List<PresenceUser> viewersOf(String node) => viewersByNode[node] ?? const [];

  /// The pointer is at [canvas] (canvas coordinates) at [zoom]; null: it left the canvas. Dify's cursor service: at most
  /// every 300 ms and after moving more than 10 screen pixels.
  void pointer(Offset? canvas, double zoom) =>
      presence.moveCursor(canvas == null ? null : PresencePoint(canvas.dx, canvas.dy), minMove: 10 / zoom);

  /// This user drags nodes, holding node `grab.$1` at offset `grab.$2` from its top-left; null: the drag ended.
  void drag((String, Offset)? grab) =>
      presence.setDrag(grab == null ? null : PresenceDrag(grab.$1, grab.$2.dx, grab.$2.dy));

  void _selectionChanged() {
    final node = controller.selectedNode;
    // The node panel is open exactly for a selected `custom` node (workflow_panels.dart), never while previewing.
    final open = node != null && !controller.previewing && reactFlowTypeOf(node) == 'custom' ? node.id : null;
    presence.openPanel(open);
  }

  final _joined = <String>[], _left = <String>[];
  Timer? _toastTimer;

  void _changed(PresenceChange c) {
    _others = null;
    _byNode = null;
    _publishUsers();
    notifyListeners();
    if (!toasts) return;
    _joined.addAll([
      for (final u in c.joined)
        if (u.account != self) u.name,
    ]);
    _left.addAll([
      for (final u in c.left)
        if (u.account != self) u.name,
    ]);
    if (_joined.isEmpty && _left.isEmpty) return;
    // Many people arriving at once make one toast, not one each.
    _toastTimer ??= Timer(const Duration(milliseconds: 800), _flushToasts);
  }

  static String _names(List<String> names) => switch (names.length) {
    1 => names[0],
    2 => '${names[0]} and ${names[1]}',
    _ => '${names[0]} and ${names.length - 1} others',
  };

  void _flushToasts() {
    _toastTimer = null;
    if (_joined.isNotEmpty) toast.info('${_names(_joined)} joined', timeout: const Duration(seconds: 3));
    if (_left.isNotEmpty) toast.info('${_names(_left)} left', timeout: const Duration(seconds: 3));
    _joined.clear();
    _left.clear();
  }

  void _publishUsers() {
    final me = presence.users[self];
    final next = [
      OnlineUser(
        sid: controller.session.clientId,
        userId: self,
        username: me?.name ?? selfName,
        avatar: me?.avatarUrl ?? selfAvatar,
      ),
      for (final u in others) OnlineUser(sid: u.account, userId: u.account, username: u.name, avatar: u.avatarUrl),
    ];
    // Pointers move many times a second; the header changes only when who is here does.
    final now = onlineUsers.value;
    if (now.length == next.length &&
        Iterable<int>.generate(now.length).every(
          (i) =>
              now[i].userId == next[i].userId && now[i].username == next[i].username && now[i].avatar == next[i].avatar,
        )) {
      return;
    }
    onlineUsers.value = next;
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    unawaited(_sub.cancel());
    controller.removeListener(_selectionChanged);
    onlineUsers.dispose();
    super.dispose();
  }
}

/// Puts an [EditorPresence] in scope for the editor's header and canvas overlays. Reading it does not rebuild on presence
/// changes (pointers move many times a second): readers listen to what they need ([EditorPresence.onlineUsers], or the
/// presence itself in a painter).
class EditorPresenceScope extends InheritedWidget {
  const EditorPresenceScope({super.key, required this.presence, required super.child});
  final EditorPresence presence;

  static EditorPresence? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<EditorPresenceScope>()?.presence;

  @override
  bool updateShouldNotify(EditorPresenceScope old) => old.presence != presence;
}

/// Reports the pointer while it moves over the canvas, that it left (no cursor drawn for the others then), and the node
/// it drags.
class PresencePointerTracker extends StatefulWidget {
  const PresencePointerTracker({super.key, required this.presence, required this.canvas});

  final EditorPresence presence;
  final CanvasController canvas;

  @override
  State<PresencePointerTracker> createState() => _PresencePointerTrackerState();
}

class _PresencePointerTrackerState extends State<PresencePointerTracker> {
  @override
  void initState() {
    super.initState();
    widget.canvas.dragGrab.addListener(_drag);
  }

  @override
  void didUpdateWidget(PresencePointerTracker old) {
    super.didUpdateWidget(old);
    if (old.canvas != widget.canvas) {
      old.canvas.dragGrab.removeListener(_drag);
      widget.canvas.dragGrab.addListener(_drag);
    }
  }

  @override
  void dispose() {
    widget.canvas.dragGrab.removeListener(_drag);
    super.dispose();
  }

  void _drag() => widget.presence.drag(widget.canvas.dragGrab.value);

  void _pointer(Offset? local) {
    final view = widget.canvas.view;
    widget.presence.pointer(local == null ? null : view.toCanvas(local), view.scale);
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerMove: (e) => _pointer(e.localPosition),
      child: MouseRegion(
        opaque: false,
        hitTestBehavior: HitTestBehavior.translucent,
        onHover: (e) => _pointer(e.localPosition),
        onExit: (_) => _pointer(null),
      ),
    ),
  );
}
