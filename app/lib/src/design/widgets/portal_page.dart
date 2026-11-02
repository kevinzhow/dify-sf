/// A full-screen page shown from a widget's own tree (dify-sf's phones; Dify's console expands editors in place).
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'back_dismiss.dart';
import 'bottom_sheet.dart' show DifyModalLayer, DifyPortalSemantics, DifySheetRecipe;
import 'page.dart' show DifyWindowInsets;
import 'top_app_bar.dart';

/// A full-screen page a widget shows from where it is declared (the code editor's and the prompt editor's expanded
/// form on a phone): over the whole window, an opaque page with a [DifyTopAppBar] (a back button, [title] and
/// [subtitle], [actions]) and [builder]'s content filling the rest, kept above the keyboard and clear of the system
/// bars. It slides in from the trailing edge like a pushed page, and back (the app bar's, Android's, Escape) calls
/// [onClose]; the owner closes it by setting [open] to false.
///
/// Unlike a route pushed on the navigator, the content keeps the inherited state of where the page is declared (the
/// editor's stores and scopes), and it is the same subtree that leaves its inline place ([child], usually empty while
/// [open]), so a text field moved in with a GlobalKey keeps its text, selection and undo history. The window's insets
/// and keyboard come from [DifyWindowInsets], since a page's own are consumed.
class DifyPortalPage extends StatefulWidget {
  const DifyPortalPage({
    super.key,
    required this.open,
    required this.onClose,
    required this.title,
    required this.builder,
    this.subtitle,
    this.actions = const [],
    this.child = const SizedBox.shrink(),
  });

  final bool open;
  final VoidCallback onClose;
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final WidgetBuilder builder;

  /// What shows in the declaring tree (the inline form, or nothing while the page is open).
  final Widget child;

  @override
  State<DifyPortalPage> createState() => _DifyPortalPageState();
}

class _DifyPortalPageState extends State<DifyPortalPage> with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController();
  late final _anim = AnimationController(vsync: this, duration: DifySheetRecipe.openDuration)
    ..addStatusListener((s) {
      if (s == AnimationStatus.dismissed && mounted) setState(() {});
    });
  late final _curve = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
  late final _back = DifyBackStep(onDismiss: () => widget.onClose());

  @override
  void initState() {
    super.initState();
    // The portal stays shown (empty while closed): opening builds the page in the same frame as the inline content
    // leaves, so a GlobalKey moves that content instead of losing it.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _portal.show();
      if (widget.open) _sync();
    });
  }

  @override
  void didUpdateWidget(DifyPortalPage old) {
    super.didUpdateWidget(old);
    if (old.open != widget.open) _sync();
  }

  @override
  void dispose() {
    _back.detach();
    _curve.dispose();
    _anim.dispose();
    super.dispose();
  }

  /// Slides in or out; the back step is held while open (attached after the frame: a build may not change it).
  void _sync() {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.open) {
      reduce ? _anim.value = 1 : _anim.forward();
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.open) _back.attach(context);
      });
    } else {
      _back.detach();
      reduce ? _anim.value = 0 : _anim.reverse();
    }
  }

  @override
  Widget build(BuildContext context) => DifyPortalSemantics(modal: widget.open, child: _portalWidget());

  Widget _portalWidget() => OverlayPortal(
    controller: _portal,
    overlayLocation: OverlayChildLocation.rootOverlay,
    overlayChildBuilder: (context) {
      if (!widget.open && _anim.isDismissed) return const SizedBox.shrink();
      final media = MediaQuery.of(context);
      final insets = DifyWindowInsets.of(context), keyboard = DifyWindowInsets.viewInsetsOf(context).bottom;
      final page = MediaQuery(
        data: media.copyWith(
          padding: insets,
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: Shortcuts(
          shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
          child: Actions(
            actions: {
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) {
                  widget.onClose();
                  return null;
                },
              ),
            },
            child: ColoredBox(
              key: const ValueKey('dify-portal-page'),
              color: DifyColors.componentsPanelBg,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The page covers what is under it (for accessibility what is under it is hidden: DifyPortalSemantics).
                  const _Absorb(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DifyTopAppBar(
                        title: widget.title,
                        subtitle: widget.subtitle,
                        leading: DifyAppBarBackButton(onPressed: widget.onClose),
                        actions: widget.actions,
                      ),
                      Expanded(
                        child: Padding(
                          // The keyboard replaces the bottom inset (Android reports none under it).
                          padding: EdgeInsets.fromLTRB(
                            insets.left,
                            0,
                            insets.right,
                            keyboard > 0 ? keyboard : insets.bottom,
                          ),
                          child: MediaQuery.removePadding(
                            context: context,
                            removeLeft: true,
                            removeTop: true,
                            removeRight: true,
                            removeBottom: true,
                            child: MediaQuery.removeViewInsets(
                              context: context,
                              removeBottom: true,
                              // Closing, the content is back in its inline place already: the page leaves empty.
                              child: widget.open ? Builder(builder: widget.builder) : const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      return SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(_curve),
        // A page for accessibility, as a route's: its parts are separate nodes, and nothing in it blocks past it. A
        // layer opened from the page (a picker) hides it.
        child: Semantics(
          container: true,
          scopesRoute: true,
          explicitChildNodes: true,
          child: DifyModalLayer(
            child: IgnorePointer(ignoring: !widget.open, child: page),
          ),
        ),
      );
    },
    child: DifyPortalSemantics.place(modal: widget.open, child: widget.child),
  );
}

/// Takes every pointer that reaches it, without semantics.
class _Absorb extends StatelessWidget {
  const _Absorb();

  @override
  Widget build(BuildContext context) => const ExcludeSemantics(
    child: Listener(behavior: HitTestBehavior.opaque, child: SizedBox.expand()),
  );
}

/// Names the full-screen pages ([DifyPortalPage]) opened inside it: an editor expanded from a node's settings takes
/// the node's [title] and [subtitle] (its type) rather than a generic one.
class DifyPortalPageTitle extends InheritedWidget {
  const DifyPortalPageTitle({super.key, required this.title, this.subtitle, required super.child});

  final String title;
  final String? subtitle;

  static DifyPortalPageTitle? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DifyPortalPageTitle>();

  @override
  bool updateShouldNotify(DifyPortalPageTitle oldWidget) => title != oldWidget.title || subtitle != oldWidget.subtitle;
}
