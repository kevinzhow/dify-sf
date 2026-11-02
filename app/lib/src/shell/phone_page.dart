/// Full-screen pages pushed from the phone home (the Account tab's settings): edge to edge, a [DifyTopAppBar] with
/// the back button over a body on `components-panel-bg` that keeps clear of the bottom inset and the keyboard.
library;

import 'package:flutter/widgets.dart';

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';

/// Pushes a [PhonePage] titled [title] around [builder]'s body.
Future<T?> pushPhonePage<T>(
  BuildContext context, {
  required String title,
  required WidgetBuilder builder,
  bool scrollable = true,
  RouteSettings? settings,
}) => Navigator.of(context).push<T>(
  difyPageRoute<T>(
    edgeToEdge: true,
    settings: settings,
    builder: (context) => PhonePage(
      title: title,
      scrollable: scrollable,
      child: Builder(builder: builder),
    ),
  ),
);

/// A pushed phone page: the app bar (title, back) on background-body under the status bar, then [child] on
/// components-panel-bg, scrolling (`px-4 pt-4`) when [scrollable]. The page's background reaches under the system
/// bars; its content stays inside the safe area.
class PhonePage extends StatelessWidget {
  const PhonePage({
    super.key,
    required this.title,
    required this.child,
    this.scrollable = true,
    this.actions = const [],
  });

  final String title;
  final Widget child;
  final bool scrollable;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return DifyPage(
      edgeToEdge: true,
      backgroundColor: DifyColors.componentsPanelBg,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DifyTopAppBar(title: title, actions: actions, backgroundColor: DifyColors.componentsPanelBg),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: scrollable
                  ? SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
                      child: SafeArea(top: false, bottom: false, child: child),
                    )
                  : SafeArea(top: false, child: child),
            ),
          ),
        ],
      ),
    );
  }
}
