/// Android back (and `Navigator.maybePop`) closes the newest open layer of a page before the page itself: popups, a
/// phone home tab, an inline search. Like raft-flutter's `RaftBackDismiss`, every open layer holds one back step on
/// its route and the steps unwind newest first. Unlike it, the steps sit in the route's pop entries (the mechanism
/// behind `PopScope`) rather than in its local history: a `Navigator.pop` in code (a dialog closing itself while one of
/// its popups is still closing) pops the route as before, and the platform's predictive back is told about every
/// change by the route itself.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

/// One route's open layers, registered as a single pop entry: it vetoes back while a layer is open and then
/// dismisses the newest one.
class _RouteLayers extends PopEntry<Object?> {
  _RouteLayers(this.route);

  final ModalRoute<Object?> route;
  final steps = <DifyBackStep>[];

  final _canPop = ValueNotifier<bool>(true);

  @override
  ValueListenable<bool> get canPopNotifier => _canPop;

  /// The entry stays registered for the route's lifetime (unregistering here could happen while the route iterates
  /// its entries to deliver a back press); with no layer open it lets back through.
  void _changed() => _canPop.value = steps.isEmpty;

  void register() => route.registerPopEntry(this);

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (didPop || steps.isEmpty) return;
    final top = steps.last;
    top.detach();
    top.onDismiss();
  }
}

/// Each route's layers (weakly: they go with the route).
final _layers = Expando<_RouteLayers>('DifyBackDismiss layers');

/// Closes the newest layer of [context]'s route and says whether there was one: for a route whose own `PopScope`
/// handles back first and wants its layers to close before it acts.
bool difyDismissTopLayer(BuildContext context) {
  final route = ModalRoute.of(context);
  final layers = route == null ? null : _layers[route];
  if (layers == null || layers.steps.isEmpty) return false;
  layers.onPopInvokedWithResult(false, null);
  return true;
}

/// One back step of an open layer (the imperative form of [DifyBackDismiss], for layers that open and close in event
/// handlers: [DifyFloating]). [attach] adds it to the current route of a context; back then calls [onDismiss] instead
/// of popping the route. [detach] removes it at once, without calling [onDismiss]. Both are safe during a build.
class DifyBackStep {
  DifyBackStep({required this.onDismiss});

  final VoidCallback onDismiss;
  _RouteLayers? _owner;

  bool get attached => _owner != null;

  /// Adds the step to [context]'s route when that route is the current one (a layer of a covered page gets none).
  void attach(BuildContext context) {
    if (_owner != null) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    final layers = _layers[route] ??= (_RouteLayers(route)..register());
    _owner = layers;
    layers.steps.add(this);
    layers._changed();
  }

  void detach() {
    final owner = _owner;
    _owner = null;
    if (owner == null) return;
    owner.steps.remove(this);
    owner._changed();
  }
}

/// While [enabled], holds a back step ([DifyBackStep]) on the enclosing route, when that route is the current one:
/// back calls [onDismiss] instead of popping the route. Turning [enabled] off, or unmounting, removes it without
/// calling [onDismiss]. Steps unwind newest first across every layer of the route. Escape is not involved: desktop
/// layers keep their own Escape handling.
class DifyBackDismiss extends StatefulWidget {
  const DifyBackDismiss({super.key, required this.onDismiss, required this.child, this.enabled = true});

  final VoidCallback onDismiss;
  final bool enabled;
  final Widget child;

  @override
  State<DifyBackDismiss> createState() => _DifyBackDismissState();
}

class _DifyBackDismissState extends State<DifyBackDismiss> {
  late final _step = DifyBackStep(onDismiss: () => widget.onDismiss());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A dependency on the route: when it becomes current again (a page above it closed) a pending step attaches.
    ModalRoute.of(context);
    _sync();
  }

  @override
  void didUpdateWidget(DifyBackDismiss old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() => widget.enabled ? _step.attach(context) : _step.detach();

  @override
  void dispose() {
    _step.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
