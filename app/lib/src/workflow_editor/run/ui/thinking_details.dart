/// Dify's shared ThinkingDetails shell for inline `<think>` and structured reasoning.
/// Dimensions and colours follow markdown-blocks/thinking-details.tsx. The clock is monotonic.
library;

import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';

import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';

class ThinkingDetails extends StatefulWidget {
  const ThinkingDetails({super.key, required this.done, required this.child});
  final bool done;
  final Widget child;
  @override
  State<ThinkingDetails> createState() => _ThinkingDetailsState();
}

class _ThinkingDetailsState extends State<ThinkingDetails> {
  final _watch = Stopwatch();
  double _elapsed = 0;
  late bool _complete = widget.done;
  bool _open = false;
  Ticker? _ticker;

  @override
  void initState() {
    super.initState();
    if (!_complete) {
      _watch.start();
      _ticker = Ticker((_) {
        final e = (_watch.elapsedMilliseconds ~/ 100) / 10;
        if (e != _elapsed) setState(() => _elapsed = e);
      })..start();
    }
  }

  @override
  void didUpdateWidget(ThinkingDetails old) {
    super.didUpdateWidget(old);
    if (widget.done && !_complete) {
      setState(() => _complete = true);
      _watch.stop();
      _ticker?.dispose();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = _complete ? _open : true;
    final label =
        '${DifyI18n.tr('common', _complete ? 'chat.thought' : 'chat.thinking')}(${_elapsed.toStringAsFixed(1)}s)';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MergeSemantics(
          child: Semantics(
            expanded: open,
            child: DifyPressable(
              onPressed: () => setState(() => _open = !open),
              builder: (context, hovered, focused) => DecoratedBox(
                decoration: BoxDecoration(border: focused ? Border.all(color: DifyColors.stateAccentSolid) : null),
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Row(
                    children: [
                      AnimatedRotation(
                        turns: open ? 0.25 : 0,
                        duration: const Duration(milliseconds: 500),
                        child: RemixIcon('arrow-right-s-line', size: 12, color: DifyColors.textSecondary),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: DifyTextLine(
                          label,
                          style: TextStyle(
                            fontFamily: cardFontFamily,
                            fontSize: 15,
                            height: 1.6,
                            fontWeight: FontWeight.w700,
                            color: DifyColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (open)
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelBgAlt,
              border: Border(left: BorderSide(color: DifyColors.componentsPanelBorder)),
            ),
            child: widget.child,
          ),
      ],
    );
  }
}
