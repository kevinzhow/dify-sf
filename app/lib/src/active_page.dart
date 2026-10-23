import 'package:flutter/widgets.dart';

/// Whether the page below is the one on screen. The app detail shell keeps its pages alive while another one shows
/// (the editor keeps its session); page-wide keyboard handlers (which listen to every key, not to the focus) ask
/// [ActivePage.isActive] when a key arrives and leave the key alone on a page that is not shown.
class ActivePage extends InheritedWidget {
  const ActivePage({super.key, required this.active, required super.child});

  final bool active;

  /// Read at key time, without a dependency: true outside any [ActivePage].
  static bool isActive(BuildContext context) => context.getInheritedWidgetOfExactType<ActivePage>()?.active ?? true;

  @override
  bool updateShouldNotify(ActivePage old) => old.active != active;
}
