/// dify-ui's Textarea (packages/dify-ui/src/textarea).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dify_tokens.g.dart';
import '../css_metrics.dart';
import '../dify_fonts.dart';
import 'widgets.dart';

/// dify-ui's Textarea (medium): `min-h-20 rounded-lg px-3 py-2 system-sm-regular` on the input colours (hover and
/// focus borders, `shadow-xs` while focused). [minHeight] and [verticalPadding] follow the call site's classes.
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
  });

  /// The text shown; a different value replaces what is typed.
  final String value;
  final ValueChanged<String>? onChanged;
  final ValueChanged<bool>? onFocusChange;
  final String? placeholder, semanticLabel;
  final bool disabled, readOnly;
  final double minHeight, verticalPadding;

  /// `maxLength`: typing stops there.
  final int? maxLength;
  final DifyTextStyle textStyle;

  @override
  State<DifyTextarea> createState() => _DifyTextareaState();
}

class _DifyTextareaState extends State<DifyTextarea> {
  late final _controller = TextEditingController(text: widget.value);
  final _focus = FocusNode(debugLabel: 'textarea');
  bool _hovered = false, _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus == _focused) return;
      setState(() => _focused = _focus.hasFocus);
      widget.onFocusChange?.call(_focused);
    });
  }

  @override
  void didUpdateWidget(DifyTextarea old) {
    super.didUpdateWidget(old);
    if (_controller.text != widget.value) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final focused = _focused && !w.disabled, hovered = _hovered && !w.disabled;
    final style = difyTextStyle(
      w.textStyle,
      w.disabled ? DifyColors.componentsInputTextFilledDisabled : DifyColors.componentsInputTextFilled,
    );
    return Semantics(
      label: w.semanticLabel,
      textField: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          constraints: BoxConstraints(minHeight: w.minHeight),
          decoration: BoxDecoration(
            color: w.disabled
                ? DifyColors.componentsInputBgDisabled
                : focused
                ? DifyColors.componentsInputBgActive
                : hovered
                ? DifyColors.componentsInputBgHover
                : DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(
              color: focused
                  ? DifyColors.componentsInputBorderActive
                  : hovered
                  ? DifyColors.componentsInputBorderHover
                  : const Color(0x00000000),
            ),
            boxShadow: focused ? DifyShadows.xs : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              enabled: !w.disabled,
              readOnly: w.readOnly,
              onChanged: (value) {
                w.onChanged?.call(value);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _controller.text != widget.value) _controller.text = widget.value;
                });
              },
              inputFormatters: w.maxLength == null ? null : [LengthLimitingTextInputFormatter(w.maxLength)],
              minLines: w.minHeight >= 80 ? 3 : null,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              style: DifyFonts.resolveStyle(style),
              strutStyle: Css.lineStrut(
                DefaultTextStyle.of(context).style.merge(style),
                textScaler: MediaQuery.textScalerOf(context),
              ),
              cursorColor: const Color(0xFF155EEF),
              cursorWidth: 1,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: w.verticalPadding),
                hint: w.placeholder == null
                    ? null
                    : DifyTextLine(
                        w.placeholder!,
                        style: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
                        maxLines: null,
                      ),
                hintStyle: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
