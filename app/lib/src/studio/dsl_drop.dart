/// apps/hooks/use-dsl-drag-drop.ts: dragging a file over the Studio page shows the drop overlay; dropping a `.yaml` /
/// `.yml` file opens the Create-from-DSL dialog with it. The platform's drag events (desktop_drop on desktop and the
/// web) feed [DslDragDrop]; tests drive it directly.
library;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/widgets.dart';

/// A dropped file: its name, and readers for its size and text.
typedef DroppedDslFile = ({String name, Future<int> Function() length, Future<String> Function() read});

/// Whether [name] is a DSL file (`.yaml` / `.yml`, any case).
bool isDslFileName(String name) {
  final n = name.toLowerCase();
  return n.endsWith('.yaml') || n.endsWith('.yml');
}

/// The hook's state: [dragging] while files are over the zone (false while not [enabled]).
class DslDragDrop extends ChangeNotifier {
  DslDragDrop({required this.onDslFileDropped, bool enabled = true})
    : _enabled = enabled; // ignore: prefer_initializing_formals

  void Function(DroppedDslFile file) onDslFileDropped;
  bool _enabled;
  bool _dragging = false;

  bool get enabled => _enabled;
  set enabled(bool v) {
    if (v == _enabled) return;
    _enabled = v;
    if (!v) _dragging = false;
    notifyListeners();
  }

  /// `enabled ? dragging : false`.
  bool get dragging => _enabled && _dragging;

  /// `dragenter`: only a drag that carries files counts (`dataTransfer.types.includes('Files')`).
  void dragEnter({bool hasFiles = true}) {
    if (!_enabled || !hasFiles || _dragging) return;
    _dragging = true;
    notifyListeners();
  }

  /// `dragleave`: ends the drag unless it moved to something inside the zone ([toInside]).
  void dragLeave({bool toInside = false}) {
    if (!_enabled || toInside || !_dragging) return;
    _dragging = false;
    notifyListeners();
  }

  /// `drop`: the first file, if it is a DSL file.
  void drop(List<DroppedDslFile>? files) {
    if (!_enabled) return;
    if (_dragging) {
      _dragging = false;
      notifyListeners();
    }
    if (files == null || files.isEmpty) return;
    final file = files.first;
    if (isDslFileName(file.name)) onDslFileDropped(file);
  }
}

/// Connects [drop] to the platform's file drops over [child] (desktop_drop's DropTarget).
class DslDropZone extends StatelessWidget {
  const DslDropZone({super.key, required this.drop, required this.child});

  final DslDragDrop drop;
  final Widget child;

  static List<DroppedDslFile> filesOf(DropDoneDetails details) => [
    for (final f in details.files) (name: f.name, length: f.length, read: f.readAsString),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: drop,
    builder: (context, _) => DropTarget(
      enable: drop.enabled,
      onDragEntered: (_) => drop.dragEnter(),
      onDragExited: (_) => drop.dragLeave(),
      onDragDone: (details) => drop.drop(filesOf(details)),
      child: child,
    ),
  );
}
