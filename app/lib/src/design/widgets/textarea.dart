/// dify-ui's native resizable Textarea (packages/dify-ui/src/textarea).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import '../dify_tokens.g.dart';
import '../css_metrics.dart';
import '../../i18n/dify_i18n.dart';
import 'widgets.dart';

/// CSS `min-h-20 w-full px-3 py-2`: a scrollable multiline field, with the
/// browser's resize affordance. Callers can disable resizing like `resize-none`.
class DifyTextarea extends StatefulWidget {
  const DifyTextarea({
    super.key,
    required this.value,
    this.onChanged,
    this.onFocusChange,
    this.placeholder,
    this.semanticLabel,
    this.disabled = false,
    this.readOnly = false,
    this.minHeight = 80,
    this.verticalPadding = 8,
    this.maxLength,
    this.textStyle = DifyType.systemSmRegular,
    this.resizable = true,
  });
  final String value;
  final ValueChanged<String>? onChanged;
  final ValueChanged<bool>? onFocusChange;
  final String? placeholder, semanticLabel;
  final bool disabled, readOnly, resizable;
  final double minHeight, verticalPadding;
  final int? maxLength;
  final DifyTextStyle textStyle;
  @override
  State<DifyTextarea> createState() => _DifyTextareaState();
}

class _DifyTextareaState extends State<DifyTextarea> with DifyControlledText<DifyTextarea> {
  final _focus = FocusNode(debugLabel: 'textarea');
  final _resizeFocus = FocusNode(debugLabel: 'textarea resize');
  Size? _resized;
  @override
  String textOf(DifyTextarea widget) => widget.value;
  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() => widget.onFocusChange?.call(_focus.hasFocus);
  @override
  void didUpdateWidget(DifyTextarea old) {
    super.didUpdateWidget(old);
    syncText();
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _resizeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final style = difyTextStyle(w.textStyle, DifyColors.componentsInputTextFilled);
    final line = MediaQuery.textScalerOf(context).scale(style.fontSize ?? 13) * (style.height ?? 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : Css.nativeInputWidth(style, MediaQuery.textScalerOf(context)) + 26;
        final width = (_resized?.width ?? maxWidth).clamp(constraints.minWidth, maxWidth);
        final maxHeight = constraints.hasBoundedHeight ? constraints.maxHeight : double.infinity;
        final minimum = w.minHeight.clamp(constraints.minHeight, maxHeight);
        final height = (_resized?.height ?? minimum).clamp(minimum, maxHeight);
        void resize(Offset delta) => setState(
          () => _resized = Size(
            (width + delta.dx).clamp(constraints.minWidth, maxWidth),
            (height + delta.dy).clamp(minimum, maxHeight),
          ),
        );
        return SizedBox(
          width: width,
          height: height,
          child: DifyInputBox(
            focusNode: _focus,
            disabled: w.disabled,
            readOnly: w.readOnly,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Semantics(
                    container: true,
                    label: w.semanticLabel,
                    child: difyTextField(
                      context: context,
                      controller: controller,
                      focusNode: _focus,
                      style: style,
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: w.verticalPadding),
                      placeholder: w.placeholder,
                      disabled: w.disabled,
                      readOnly: w.readOnly,
                      minLines: null,
                      maxLines: null,
                      expands: true,
                      centerCap: false,
                      keyboardType: TextInputType.multiline,
                      formatters: w.maxLength == null ? null : [LengthLimitingTextInputFormatter(w.maxLength)],
                      onChanged: (value) {
                        w.onChanged?.call(value);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && controller.text != widget.value) syncText();
                        });
                      },
                    ),
                  ),
                ),
                if (w.resizable && !w.disabled)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Focus(
                      focusNode: _resizeFocus,
                      skipTraversal: true,
                      onKeyEvent: (_, event) {
                        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
                        final delta = switch (event.logicalKey) {
                          LogicalKeyboardKey.arrowDown => Offset(0, line),
                          LogicalKeyboardKey.arrowUp => Offset(0, -line),
                          LogicalKeyboardKey.arrowRight => Offset(line, 0),
                          LogicalKeyboardKey.arrowLeft => Offset(-line, 0),
                          _ => null,
                        };
                        if (delta == null) return KeyEventResult.ignored;
                        resize(delta);
                        return KeyEventResult.handled;
                      },
                      child: Semantics(
                        label: DifyI18n.tr('common', 'operation.resizeTextArea'),
                        container: true,
                        value: '${height.round()}',
                        increasedValue: '${(height + line).clamp(minimum, maxHeight).round()}',
                        decreasedValue: '${(height - line).clamp(minimum, maxHeight).round()}',
                        onIncrease: () => resize(Offset(0, line)),
                        onDecrease: () => resize(Offset(0, -line)),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeUpLeftDownRight,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (_) => _resizeFocus.requestFocus(),
                            onPanUpdate: (event) => resize(event.delta),
                            child: SizedBox(
                              key: const Key('textarea-resize'),
                              width: 16,
                              height: 16,
                              child: Align(
                                alignment: Alignment.bottomRight,
                                child: CustomPaint(
                                  size: const Size(12, 12),
                                  painter: _ResizeGrip(DifyColors.textTertiary),
                                ),
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
        );
      },
    );
  }
}

/// Native textarea's two diagonal grip strokes, inside its corner hit target.
class _ResizeGrip extends CustomPainter {
  const _ResizeGrip(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    canvas.drawLine(Offset(size.width / 3, size.height * 5 / 6), Offset(size.width * 5 / 6, size.height / 3), paint);
    canvas.drawLine(
      Offset(size.width * 7 / 12, size.height * 5 / 6),
      Offset(size.width * 5 / 6, size.height * 7 / 12),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ResizeGrip old) => color != old.color;
}
