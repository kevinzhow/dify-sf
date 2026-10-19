/// Dify's Infotip (web/app/components/base/infotip).
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../css_metrics.dart';
import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

/// Infotip (base/infotip): a 16 px question mark (`text-text-quaternary`, hover tertiary) that opens a popover with
/// [content] on hover (300 ms in, 200 ms out) or on tap; the box is `max-w-75 rounded-md px-3 py-2 system-xs-regular
/// text-text-tertiary` on the popover surface, above the icon.
class Infotip extends StatefulWidget {
  const Infotip({
    super.key,
    required this.label,
    required this.content,
    this.icon = 'question-line',
    this.iconSize = 14,
    this.width,
  });

  /// `aria-label`.
  final String label;
  final Widget content;
  final String icon;
  final double iconSize;

  /// `popupClassName="w-[240px]"` and the like.
  final double? width;

  @override
  State<Infotip> createState() => _InfotipState();
}

class _InfotipState extends State<Infotip> {
  final _floating = DifyFloatingController();
  Timer? _timer;
  bool _hovered = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _schedule(bool open) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: open ? 300 : 200), () => open ? _floating.open() : _floating.close());
  }

  bool _mouse(PointerEvent e) => e.kind == PointerDeviceKind.mouse;

  @override
  Widget build(BuildContext context) => DifyFloating(
    controller: _floating,
    placement: DifyPlacement.top,
    sideOffset: 8,
    focusPopup: false,
    builder: (context, c) => Semantics(
      container: true,
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (e) {
          setState(() => _hovered = true);
          if (_mouse(e)) _schedule(true);
        },
        onExit: (e) {
          setState(() => _hovered = false);
          if (_mouse(e)) _schedule(false);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: () {
            _timer?.cancel();
            c.toggle();
          },
          child: SizedBox.square(
            dimension: 16,
            child: Center(
              child: RemixIcon(
                widget.icon,
                size: widget.iconSize,
                color: _hovered ? DifyColors.textTertiary : DifyColors.textQuaternary,
              ),
            ),
          ),
        ),
      ),
    ),
    popupBuilder: (context) => MouseRegion(
      onEnter: (_) => _timer?.cancel(),
      onExit: (e) => _mouse(e) ? _schedule(false) : null,
      child: Container(
        width: widget.width,
        constraints: const BoxConstraints(maxWidth: 300),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.md),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          boxShadow: DifyShadows.lg,
        ),
        child: DefaultTextStyle.merge(
          style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
          child: widget.content,
        ),
      ),
    ),
  );
}
