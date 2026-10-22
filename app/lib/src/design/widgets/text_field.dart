/// Text entry used by Dify's content editors, which own their surrounding box.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../dify_tokens.g.dart';
import 'input.dart';
import 'text.dart';
import 'selection.dart';

/// Dify input content: an optional label/error, placeholder and CSS padding.
/// Material borders, floating labels, density and counters are not exposed.
class DifyFieldDecoration {
  const DifyFieldDecoration({
    this.labelText,
    this.hintText,
    this.hintStyle,
    this.errorText,
    this.contentPadding,
    this.outlined = false,
    this.counterText,
  });
  const DifyFieldDecoration.collapsed({this.hintText, this.hintStyle})
    : labelText = null,
      errorText = null,
      contentPadding = EdgeInsets.zero,
      outlined = false,
      counterText = null;
  final String? labelText, hintText, errorText, counterText;
  final TextStyle? hintStyle;
  final EdgeInsetsGeometry? contentPadding;
  final bool outlined;

  DifyFieldDecoration copyWith({
    String? labelText,
    String? hintText,
    TextStyle? hintStyle,
    String? errorText,
    EdgeInsetsGeometry? contentPadding,
    bool? outlined,
    String? counterText,
  }) => DifyFieldDecoration(
    labelText: labelText ?? this.labelText,
    hintText: hintText ?? this.hintText,
    hintStyle: hintStyle ?? this.hintStyle,
    errorText: errorText ?? this.errorText,
    contentPadding: contentPadding ?? this.contentPadding,
    outlined: outlined ?? this.outlined,
    counterText: counterText ?? this.counterText,
  );
}

/// A borderless editor with Dify's typography, caret and placeholder. The caller
/// supplies a Dify surface or asks for the standard input box with `outlined`.
/// All Material interaction defaults affecting layout are pinned here, including
/// multiline inputs and custom chip-aware controllers/context menus.
class DifyTextField extends StatefulWidget {
  const DifyTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.style,
    this.strutStyle,
    this.decoration = const DifyFieldDecoration(),
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.onTap,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.expands = false,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.maxLengthEnforcement,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.textAlign = TextAlign.start,
    this.textAlignVertical,
    this.cursorColor,
    this.cursorWidth = 1,
    this.contextMenuBuilder,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final DifyFieldDecoration decoration;
  final ValueChanged<String>? onChanged, onSubmitted;
  final VoidCallback? onEditingComplete, onTap;
  final bool enabled, readOnly, autofocus, autocorrect, enableSuggestions, expands;
  final int? maxLines, minLines, maxLength;
  final MaxLengthEnforcement? maxLengthEnforcement;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final TextAlign textAlign;
  final TextAlignVertical? textAlignVertical;
  final Color? cursorColor;
  final double cursorWidth;
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  @override
  State<DifyTextField> createState() => _DifyTextFieldState();
}

class _DifyTextFieldState extends State<DifyTextField> {
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());
  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget, d = widget.decoration;
    final style = difyTextStyle(
      DifyType.systemSmRegular,
      DifyColors.componentsInputTextFilled,
    ).merge(w.style).copyWith(letterSpacing: w.style?.letterSpacing ?? 0);
    Widget field = TextField(
      controller: w.controller,
      focusNode: _focus,
      style: style,
      strutStyle: w.strutStyle,
      onChanged: w.onChanged,
      onSubmitted: w.onSubmitted,
      onEditingComplete: w.onEditingComplete,
      onTap: w.onTap,
      enabled: w.enabled,
      readOnly: w.readOnly,
      autofocus: w.autofocus,
      autocorrect: w.autocorrect,
      enableSuggestions: w.enableSuggestions,
      expands: w.expands,
      maxLines: w.maxLines,
      minLines: w.minLines,
      maxLength: w.maxLength,
      maxLengthEnforcement: w.maxLengthEnforcement,
      keyboardType: w.keyboardType,
      textInputAction: w.textInputAction,
      inputFormatters: w.inputFormatters,
      textAlign: w.textAlign,
      textAlignVertical: w.textAlignVertical,
      cursorColor: w.cursorColor ?? DifyColors.primary600,
      cursorWidth: w.cursorWidth,
      contextMenuBuilder: w.contextMenuBuilder ?? difySelectionToolbar,
      decoration: InputDecoration(
        isCollapsed: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
        visualDensity: VisualDensity.standard,
        contentPadding:
            d.contentPadding ??
            (d.outlined ? const EdgeInsets.symmetric(horizontal: 12, vertical: 7) : EdgeInsets.zero),
        hintText: d.hintText,
        hintStyle: d.hintStyle ?? style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
        counterText: '',
      ),
    );
    if (d.outlined) {
      field = DifyInputBox(
        focusNode: _focus,
        disabled: !w.enabled,
        readOnly: w.readOnly,
        invalid: d.errorText != null,
        child: field,
      );
    }
    if (d.labelText != null || d.errorText != null) {
      field = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (d.labelText != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(d.labelText!, style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary)),
            ),
          field,
          if (d.errorText != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(d.errorText!, style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textDestructive)),
            ),
        ],
      );
    }
    return Material(type: MaterialType.transparency, child: field);
  }
}

/// Read-only content inside the Dify input surface (variables and references).
class DifyFieldBox extends StatelessWidget {
  const DifyFieldBox({super.key, required this.child, this.decoration = const DifyFieldDecoration()});
  final Widget child;
  final DifyFieldDecoration decoration;
  @override
  Widget build(BuildContext context) {
    final d = decoration;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (d.labelText != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(d.labelText!, style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary)),
          ),
        Container(
          padding: d.contentPadding ?? const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: child,
        ),
        if (d.errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(d.errorText!, style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textDestructive)),
          ),
      ],
    );
  }
}
