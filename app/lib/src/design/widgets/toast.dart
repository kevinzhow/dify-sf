import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'button_style.dart';
import 'icon_button.dart';
import 'loading.dart' show DifySpinnerIcon;
import 'surface.dart';
import 'text.dart';

/// dify-ui's toast types (`toast.success`, `toast.error`, ...); a toast without one is neutral.
enum DifyToastType { success, error, warning, info }

/// A toast's `actionProps`: one secondary button under the text.
@immutable
class DifyToastAction {
  const DifyToastAction({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
}

/// What `toast.update` (and a promise's outcome) changes; null fields stay as they are.
@immutable
class DifyToastUpdate {
  const DifyToastUpdate({this.title, this.description, this.type, this.timeout});
  final String? title;
  final String? description;
  final DifyToastType? type;
  final Duration? timeout;
}

/// One toast: [title], an optional [description] and [action], a [type] (or the spinning loading icon while a
/// promise is pending). [timeout] null takes the host's; zero keeps it until it is closed.
@immutable
class DifyToastData {
  const DifyToastData({
    required this.id,
    required this.title,
    this.description,
    this.type,
    this.loading = false,
    this.timeout,
    this.onClose,
    this.action,
  });

  final String id;
  final String title;
  final String? description;
  final DifyToastType? type;
  final bool loading;
  final Duration? timeout;
  final VoidCallback? onClose;
  final DifyToastAction? action;

  DifyToastData apply(DifyToastUpdate u) => DifyToastData(
    id: id,
    title: u.title ?? title,
    description: u.description ?? description,
    type: u.type ?? type,
    loading: u.type == null && loading,
    timeout: u.timeout ?? timeout,
    onClose: onClose,
    action: action,
  );
}

/// Base UI's toast manager: what `toast.*` calls go through to every [DifyToastHost] showing it (none: the toast
/// is dropped).
class DifyToastManager {
  final _hosts = <_DifyToastHostState>{};
  var _ids = 0;

  /// Shows [data] (an [DifyToastData.id] of '' gets a new id); a toast with the same id is replaced. Its id.
  String add(DifyToastData data) {
    final d = data.id.isNotEmpty
        ? data
        : DifyToastData(
            id: 'toast-${++_ids}',
            title: data.title,
            description: data.description,
            type: data.type,
            loading: data.loading,
            timeout: data.timeout,
            onClose: data.onClose,
            action: data.action,
          );
    for (final h in [..._hosts]) {
      h._add(d);
    }
    return d.id;
  }

  /// Closes the toast [id], or every toast.
  void close([String? id]) {
    for (final h in [..._hosts]) {
      h._close(id);
    }
  }

  void update(String id, DifyToastUpdate update) {
    for (final h in [..._hosts]) {
      h._update(id, update);
    }
  }
}

/// dify-ui's `toast` API over a [DifyToastManager]: `toast('…')`, `toast.error('…')`, `toast.dismiss(id)`, ...
class DifyToast {
  const DifyToast(this.manager);
  final DifyToastManager manager;

  /// A toast of [type] (neutral when null); its id.
  String show(
    DifyToastType? type,
    String title, {
    String? description,
    Duration? timeout,
    String? id,
    VoidCallback? onClose,
    DifyToastAction? action,
  }) => manager.add(
    DifyToastData(
      id: id ?? '',
      title: title,
      description: description,
      type: type,
      timeout: timeout,
      onClose: onClose,
      action: action,
    ),
  );

  String call(
    String title, {
    String? description,
    Duration? timeout,
    String? id,
    VoidCallback? onClose,
    DifyToastAction? action,
  }) => show(null, title, description: description, timeout: timeout, id: id, onClose: onClose, action: action);

  String success(String title, {String? description, Duration? timeout, String? id, VoidCallback? onClose}) =>
      show(DifyToastType.success, title, description: description, timeout: timeout, id: id, onClose: onClose);

  String error(String title, {String? description, Duration? timeout, String? id, VoidCallback? onClose}) =>
      show(DifyToastType.error, title, description: description, timeout: timeout, id: id, onClose: onClose);

  String warning(String title, {String? description, Duration? timeout, String? id, VoidCallback? onClose}) =>
      show(DifyToastType.warning, title, description: description, timeout: timeout, id: id, onClose: onClose);

  String info(String title, {String? description, Duration? timeout, String? id, VoidCallback? onClose}) =>
      show(DifyToastType.info, title, description: description, timeout: timeout, id: id, onClose: onClose);

  /// Closes the toast [id], or every toast.
  void dismiss([String? id]) => manager.close(id);

  void update(String id, DifyToastUpdate update) => manager.update(id, update);

  /// A loading toast for [future], updated to [success]'s or [error]'s outcome (success / error type unless
  /// they name one). Completes like [future].
  Future<T> promise<T>(
    Future<T> future, {
    required String loading,
    required DifyToastUpdate Function(T value) success,
    required DifyToastUpdate Function(Object error) error,
  }) async {
    final id = manager.add(DifyToastData(id: '', title: loading, loading: true));
    try {
      final value = await future;
      final u = success(value);
      manager.update(id, u.type != null ? u : _typed(u, DifyToastType.success));
      return value;
    } catch (e) {
      final u = error(e);
      manager.update(id, u.type != null ? u : _typed(u, DifyToastType.error));
      rethrow;
    }
  }

  static DifyToastUpdate _typed(DifyToastUpdate u, DifyToastType type) =>
      DifyToastUpdate(title: u.title, description: u.description, type: type, timeout: u.timeout);
}

/// `toast.show` / `toast.error` as plain functions: the constant default of the panels' toast callbacks.
void difyToast(DifyToastType type, String message) => toast.show(type, message);
void difyToastError(String message) => toast.error(message);

/// The app's toast manager (dify-ui's default one).
final defaultToastManager = DifyToastManager();

/// dify-ui's `toast`: `toast.error(message)` shows on the app's [DifyToastHost].
final toast = DifyToast(defaultToastManager);

// ----- the host -----

/// ToastHost: the toasts of [manager] (the app's by default), stacked at the top-right (`top-4 right-4
/// sm:right-8`, 360 px wide): the newest in front, older ones peeking 5 px below it, all spread out while hovered
/// (timers paused). Toasts close after [timeout] (their own if they have one; zero: never), from their close button,
/// or swiped up or right; at most [limit] are shown. Put it in a Stack over the app (it fills it).
class DifyToastHost extends StatefulWidget {
  const DifyToastHost({
    super.key,
    this.timeout = const Duration(seconds: 5),
    this.limit = 3,
    this.manager,
    this.top,
    this.right,
  });

  final Duration timeout;
  final int limit;
  final DifyToastManager? manager;

  /// `offset`: the viewport's top and right (16 px; right 32 px from 640 px wide).
  final double? top, right;

  @override
  State<DifyToastHost> createState() => _DifyToastHostState();
}

class _Entry {
  _Entry(this.data);
  DifyToastData data;
  double? height;
  int index = 0;
  double offsetY = 0;
  bool ending = false;
  String? swipedOut;
  Offset swipe = Offset.zero;
  bool dragging = false;
  Timer? timer;
  Duration? remaining;
  final watch = Stopwatch();
}

class _DifyToastHostState extends State<DifyToastHost> {
  final _entries = <_Entry>[];
  bool _expanded = false, _hovered = false;
  bool _measureScheduled = false;
  DifyToastManager get _manager => widget.manager ?? defaultToastManager;

  static const _gap = 8.0, _peek = 5.0, _swipeThreshold = 40.0;
  static const _exit = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _manager._hosts.add(this);
  }

  @override
  void didUpdateWidget(DifyToastHost old) {
    super.didUpdateWidget(old);
    if (old.manager != widget.manager) {
      (old.manager ?? defaultToastManager)._hosts.remove(this);
      _manager._hosts.add(this);
    }
  }

  @override
  void dispose() {
    _manager._hosts.remove(this);
    for (final e in _entries) {
      e.timer?.cancel();
    }
    super.dispose();
  }

  _Entry? _find(String id) => _entries.where((e) => e.data.id == id && !e.ending).firstOrNull;

  void _add(DifyToastData d) {
    final e = _find(d.id);
    if (e != null) {
      e.data = d;
    } else {
      _entries.insert(0, _Entry(d));
    }
    _schedule(e ?? _entries.first);
    setState(() {});
  }

  void _update(String id, DifyToastUpdate u) {
    final e = _find(id);
    if (e == null) return;
    setState(() => e.data = e.data.apply(u));
    _schedule(e);
  }

  void _close(String? id, {String? swipe}) {
    final closing = [
      for (final e in _entries)
        if (!e.ending && (id == null || e.data.id == id)) e,
    ];
    if (closing.isEmpty) return;
    setState(() {
      for (final e in closing) {
        e
          ..ending = true
          ..swipedOut = swipe
          ..timer?.cancel();
      }
    });
    for (final e in closing) {
      // Gone once its exit transition is over.
      e.timer = Timer(_exit, () => setState(() => _entries.remove(e)));
      e.data.onClose?.call();
    }
  }

  // Timers: a toast closes after its timeout, which pauses while the stack is expanded.
  void _schedule(_Entry e) {
    e.timer?.cancel();
    e.timer = null;
    final t = e.data.loading ? Duration.zero : e.data.timeout ?? widget.timeout;
    e.remaining = t > Duration.zero ? t : null;
    if (!_expanded) _run(e);
  }

  void _run(_Entry e) {
    final left = e.remaining;
    if (left == null || e.ending || e.timer != null) return;
    e.watch
      ..reset()
      ..start();
    e.timer = Timer(left, () => _close(e.data.id));
  }

  void _pause(_Entry e) {
    final t = e.timer;
    if (t == null) return;
    t.cancel();
    e.timer = null;
    final left = e.remaining! - e.watch.elapsed;
    e.remaining = left > Duration.zero ? left : const Duration(milliseconds: 1);
  }

  /// Expanded while hovered, and while a toast is swiped (it may leave the viewport under the pointer).
  void _syncExpanded() {
    final v = _hovered || _entries.any((e) => e.dragging);
    if (_expanded == v) return;
    setState(() => _expanded = v);
    for (final e in _entries) {
      v ? _pause(e) : _run(e);
    }
  }

  void _hover(bool v) {
    _hovered = v;
    _syncExpanded();
  }

  void _measured(_Entry e, double h) {
    if (e.height == h) return;
    e.height = h;
    if (_measureScheduled) return;
    _measureScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (mounted) setState(() {});
    });
  }

  void _swipeEnd(_Entry e) {
    final s = e.swipe;
    e.dragging = false;
    if (-s.dy >= _swipeThreshold) {
      _close(e.data.id, swipe: 'up');
    } else if (s.dx >= _swipeThreshold) {
      _close(e.data.id, swipe: 'right');
    } else {
      setState(() => e.swipe = Offset.zero);
    }
    _syncExpanded();
  }

  /// Where [e] is drawn (Base UI's CSS variables): collapsed, toasts behind the front one take its height, shrink by
  /// 2.25 % per step and peek 5 px below it; expanded, they are listed 8 px apart.
  _Geom _target(_Entry e, double? frontHeight, double width) {
    final i = e.index;
    final height = _expanded || i == 0 ? e.height : frontHeight;
    final scale = _expanded ? 1.0 : 1 - i * 0.0225;
    final expandedY = e.offsetY + i * _gap;
    final content = !_expanded && i > 0 ? 0.0 : 1.0;
    if (e.ending) {
      return switch (e.swipedOut) {
        'up' => _Geom(dy: e.swipe.dy, fy: -1.5, opacity: 0, height: height, content: content),
        'right' => _Geom(dx: e.swipe.dx, fx: 1.5, dy: expandedY, opacity: 0, height: height, content: content),
        _ => _Geom(fy: -1.5, opacity: 0, height: height, content: content),
      };
    }
    final y = _expanded ? expandedY : i * _peek + (1 - scale) * (height ?? 0);
    return _Geom(
      dx: e.swipe.dx,
      dy: y + e.swipe.dy,
      scale: scale,
      opacity: i >= widget.limit ? 0 : 1,
      height: height,
      content: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final width = math.min(360.0, screen.width - 32);
    final active = [
      for (final e in _entries)
        if (!e.ending) e,
    ];
    var y = 0.0;
    for (final (i, e) in active.indexed) {
      e
        ..index = i
        ..offsetY = y;
      y += e.height ?? 0;
    }
    final frontHeight = active.firstOrNull?.height;
    final bottom = active.isEmpty ? 0.0 : y + (active.length - 1) * _gap;
    return DefaultTextStyle.merge(
      style: TextStyle(color: DifyColors.textPrimary, decoration: TextDecoration.none),
      child: Stack(
        children: [
          Positioned(
            top: widget.top ?? 16,
            right: widget.right ?? (screen.width >= 640 ? 32 : 16),
            width: width,
            bottom: 0,
            // A labelled semantics node for this full-height positioning area
            // becomes a Web DOM hit target, even when the toast stack is empty.
            // Announce only the actual cards below.
            child: MouseRegion(
              hitTestBehavior: HitTestBehavior.deferToChild,
              onEnter: (_) => _hover(true),
              onExit: (_) => _hover(false),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // The 8 px gaps between expanded toasts keep them expanded (Base UI's `after:` strips).
                  if (_expanded && active.isNotEmpty)
                    Positioned(top: 0, left: 0, right: 0, height: bottom, child: const AbsorbPointer()),
                  for (final e in _entries.reversed)
                    Positioned(
                      key: ObjectKey(e),
                      top: 0,
                      left: 0,
                      right: 0,
                      // The transform is outermost: hits land where the toast is drawn.
                      child: _ToastFrame(
                        target: _target(e, frontHeight, width),
                        instant: e.dragging,
                        child: (content) => ExcludeSemantics(
                          excluding: e.ending || e.index >= widget.limit,
                          child: Semantics(
                            container: true,
                            explicitChildNodes: true,
                            label: 'Notifications',
                            liveRegion: true,
                            child: IgnorePointer(
                              ignoring: e.ending || e.index >= widget.limit,
                              child: GestureDetector(
                                onPanStart: (_) {
                                  e.dragging = true;
                                  _syncExpanded();
                                },
                                onPanUpdate: (d) => setState(() {
                                  // swipeDirection up and right: movement the other ways does not move it.
                                  final s = e.swipe + d.delta;
                                  e.swipe = Offset(math.max(0, s.dx), math.min(0, s.dy));
                                }),
                                onPanEnd: (_) => _swipeEnd(e),
                                onPanCancel: () => _swipeEnd(e),
                                child: _ToastCard(
                                  data: e.data,
                                  content: content,
                                  onClose: () => _close(e.data.id),
                                  onHeight: (h) => _measured(e, h),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A toast's transform, opacity and height ([fx], [fy]: fractions of its own size, like CSS percentages).
@immutable
class _Geom {
  const _Geom({
    this.dx = 0,
    this.dy = 0,
    this.fx = 0,
    this.fy = 0,
    this.scale = 1,
    this.opacity = 1,
    this.content = 1,
    this.height,
  });

  /// `data-starting-style`: above, transparent.
  static const starting = _Geom(fy: -1.5, opacity: 0);

  final double dx, dy, fx, fy, scale, opacity, content;
  final double? height;

  static double _l(double a, double b, double t) => a + (b - a) * t;

  /// Transform over 500 ms on Base UI's curve, opacity over 500 ms, content opacity 200 ms, height 150 ms.
  static _Geom lerp(_Geom a, _Geom b, double t) {
    final move = const Cubic(0.22, 1, 0.36, 1).transform(t);
    final fade = Curves.ease.transform(t);
    final content = Curves.ease.transform(math.min(1, t * 2.5));
    final grow = Curves.ease.transform(math.min(1, t * 500 / 150));
    return _Geom(
      dx: _l(a.dx, b.dx, move),
      dy: _l(a.dy, b.dy, move),
      fx: _l(a.fx, b.fx, move),
      fy: _l(a.fy, b.fy, move),
      scale: _l(a.scale, b.scale, move),
      opacity: _l(a.opacity, b.opacity, fade),
      content: _l(a.content, b.content, content),
      height: a.height == null || b.height == null ? b.height : _l(a.height!, b.height!, grow),
    );
  }

  @override
  bool operator ==(Object o) =>
      o is _Geom &&
      o.dx == dx &&
      o.dy == dy &&
      o.fx == fx &&
      o.fy == fy &&
      o.scale == scale &&
      o.opacity == opacity &&
      o.content == content &&
      o.height == height;

  @override
  int get hashCode => Object.hash(dx, dy, fx, fy, scale, opacity, content, height);
}

/// Moves a toast to [target] with Base UI's transitions; it enters from above ([_Geom.starting]). [instant] while
/// it is being swiped.
class _ToastFrame extends StatefulWidget {
  const _ToastFrame({required this.target, required this.child, this.instant = false});
  final _Geom target;
  final bool instant;
  final Widget Function(double contentOpacity) child;

  @override
  State<_ToastFrame> createState() => _ToastFrameState();
}

class _ToastFrameState extends State<_ToastFrame> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 500))..forward();
  _Geom _from = _Geom.starting;
  late _Geom _to = widget.target;

  _Geom get _now => _Geom.lerp(_from, _to, _c.value);

  @override
  void didUpdateWidget(_ToastFrame old) {
    super.didUpdateWidget(old);
    if (widget.target == _to) return;
    if (widget.instant) {
      _from = _to = widget.target;
      _c.value = 1;
      return;
    }
    _from = _now;
    _to = widget.target;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) {
      final g = _now;
      return Transform(
        alignment: Alignment.topCenter,
        transform: Matrix4.identity()
          ..translateByDouble(g.dx, g.dy, 0, 1)
          ..scaleByDouble(g.scale, g.scale, 1, 1),
        child: FractionalTranslation(
          translation: Offset(g.fx, g.fy),
          child: Opacity(
            opacity: g.opacity.clamp(0, 1),
            child: SizedBox(height: g.height, child: widget.child(g.content.clamp(0, 1))),
          ),
        ),
      );
    },
  );
}

// `shadow-lg shadow-shadow-shadow-5`: the colour utility replaces shadow-lg's colours.
List<BoxShadow> get _shadow => [for (final s in DifyShadows.lg) s.copyWith(color: DifyColors.shadowShadow5)];

/// The toast's card (ToastCard): the blurred panel with the type's halo, its icon, title, description, action and
/// close button; [onHeight] reports the height it needs.
class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.data, required this.content, required this.onClose, required this.onHeight});
  final DifyToastData data;
  final double content;
  final VoidCallback onClose;
  final ValueChanged<double> onHeight;

  static (String, Color, Color)? _tone(DifyToastData d) => d.loading
      ? ('loader-2-line', DifyColors.textAccent, DifyColors.componentsBadgeStatusLightNormalHalo)
      : switch (d.type) {
          DifyToastType.success => (
            'checkbox-circle-fill',
            DifyColors.textSuccess,
            DifyColors.componentsBadgeStatusLightSuccessHalo,
          ),
          DifyToastType.error => (
            'error-warning-fill',
            DifyColors.textDestructive,
            DifyColors.componentsBadgeStatusLightErrorHalo,
          ),
          DifyToastType.warning => (
            'alert-fill',
            DifyColors.textWarningSecondary,
            DifyColors.componentsBadgeStatusLightWarningHalo,
          ),
          DifyToastType.info => (
            'information-2-fill',
            DifyColors.textAccent,
            DifyColors.componentsBadgeStatusLightNormalHalo,
          ),
          null => null,
        };

  @override
  Widget build(BuildContext context) {
    final tone = _tone(data);
    Widget? icon = tone == null ? null : RemixIcon(tone.$1, size: 20, color: tone.$2);
    if (data.loading) icon = DifySpinnerIcon(child: icon!);
    final text = Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DifyTextLine(data.title, style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textPrimary)),
          if (data.description != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: DifyTextLine(
                data.description!,
                style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textSecondary),
              ),
            ),
          if (data.action case final a?)
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _ActionButton(action: a),
              ),
            ),
        ],
      ),
    );
    return Semantics(
      container: true,
      role: SemanticsRole.dialog,
      label: data.title,
      explicitChildNodes: true,
      child: DifyBlurredBox(
        blur: 5,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBgBlur,
          border: Border.all(color: DifyColors.componentsPanelBorder),
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          boxShadow: _shadow,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DifyRadius.xl - 1),
          child: Stack(
            children: [
              Positioned.fill(
                child: Opacity(
                  opacity: 0.4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          tone?.$3 ?? DifyColors.backgroundDefaultSubtle,
                          DifyColors.backgroundGradientMaskTransparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _NaturalHeight(
                // The card's 1 px border is around the content.
                onHeight: (h) => onHeight(h + 2),
                child: Opacity(
                  opacity: content,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 4,
                      children: [
                        Padding(padding: const EdgeInsets.all(2), child: icon),
                        Expanded(child: text),
                        Padding(
                          padding: const EdgeInsets.all(2),
                          child: DifyIconButton(
                            label: 'Close notification',
                            size: DifyIconButtonSize.sm,
                            icon: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
                            onPressed: onClose,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The toast's action: a secondary button (`px-3 py-2 system-sm-medium`, 0.5 px border, shadow-xs).
class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.action});
  final DifyToastAction action;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: action.label,
    onPressed: action.onPressed,
    builder: (context, hovered, focused) => DifyBlurredBox(
      blur: 5,
      borderRadius: BorderRadius.circular(DifyRadius.md),
      decoration: BoxDecoration(
        color: hovered ? DifyColors.stateBaseHover : DifyColors.componentsButtonSecondaryBg,
        border: Border.all(color: DifyColors.componentsButtonSecondaryBorder, width: 0.5),
        borderRadius: BorderRadius.circular(DifyRadius.md),
        boxShadow: [for (final s in DifyShadows.xs) s.copyWith(color: DifyColors.shadowShadow3)],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: DifyTextLine(
        action.label,
        style: difyTextStyle(DifyType.systemSmMedium, DifyColors.componentsButtonSecondaryText),
      ),
    ),
  );
}

/// Lays its child out at the height it needs (reported to [onHeight]) and takes at most the height it is given:
/// the card's `overflow-hidden` box shrunk to the front toast's height.
class _NaturalHeight extends SingleChildRenderObjectWidget {
  const _NaturalHeight({required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderNaturalHeight(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderNaturalHeight r) => r.onHeight = onHeight;
}

class _RenderNaturalHeight extends RenderProxyBox {
  _RenderNaturalHeight(this.onHeight);
  ValueChanged<double> onHeight;

  @override
  void performLayout() {
    final c = constraints;
    child!.layout(BoxConstraints(minWidth: c.minWidth, maxWidth: c.maxWidth), parentUsesSize: true);
    onHeight(child!.size.height);
    size = c.constrain(child!.size);
  }
}
