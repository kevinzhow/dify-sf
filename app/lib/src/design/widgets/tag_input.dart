/// Dify's TagInput (web/app/components/base/tag-input).
library;

import 'dart:ui' show SemanticsValidationResult;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../i18n/dify_i18n.dart';
import '../css_metrics.dart';
import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

String _docs(String key) => DifyI18n.tr('dataset-documents', key);

/// base/tag-input: the [items] as chips with a remove button each, then a dashed "+" field that adds its trimmed
/// text on [customizedConfirmKey] (Enter) or blur. Empty text is ignored (an error when [required]); duplicates and
/// tags over 20 characters are refused with [onError] (Dify's `toast.error`). With Tab as the confirm key (the stop
/// sequences) the whole input is the `rounded-lg bg-components-input-bg-normal` box and Enter types `↵`.
class DifyTagInput extends StatefulWidget {
  const DifyTagInput({
    super.key,
    required this.items,
    required this.onChange,
    this.placeholder,
    this.label,
    this.disableAdd = false,
    this.disableRemove = false,
    this.required = false,
    this.isInWorkflow = false,
    this.customizedConfirmKey = LogicalKeyboardKey.enter,
    this.onError = difyToastError,
    this.invalid = false,
    this.description,
  });

  final List<String> items;
  final ValueChanged<List<String>> onChange;
  final String? placeholder;

  /// The input's `aria-invalid` and `aria-describedby` text.
  final bool invalid;
  final String? description;

  /// The input's accessible name.
  final String? label;
  final bool disableAdd, disableRemove, required, isInWorkflow;
  final LogicalKeyboardKey customizedConfirmKey;

  /// `toast.error` with the message (the app's toast host by default); null: refused tags are dropped silently.
  final ValueChanged<String>? onError;

  @override
  State<DifyTagInput> createState() => _DifyTagInputState();
}

class _DifyTagInputState extends State<DifyTagInput> {
  final _text = TextEditingController();
  late final _focus = FocusNode(debugLabel: 'TagInput', onKeyEvent: _onKey)..addListener(_onFocus);
  bool _focused = false;

  bool get _special => widget.customizedConfirmKey == LogicalKeyboardKey.tab;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focus.hasFocus == _focused) return;
    setState(() => _focused = _focus.hasFocus);
    if (!_focus.hasFocus) _newTag(_text.text);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (_special && e.logicalKey == LogicalKeyboardKey.enter) {
      _text.text = '${_text.text}↵';
      return KeyEventResult.handled;
    }
    if (e.logicalKey == widget.customizedConfirmKey && e.logicalKey != LogicalKeyboardKey.enter) {
      _newTag(_text.text);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// `handleNewTag`.
  void _newTag(String value) {
    final w = widget;
    final v = value.trim();
    if (v.isEmpty) {
      if (w.required) w.onError?.call(_docs('segment.keywordEmpty'));
      return;
    }
    if (w.items.contains(v)) {
      w.onError?.call(_docs('segment.keywordDuplicate'));
      return;
    }
    if (v.length > 20) {
      w.onError?.call(_docs('segment.keywordError'));
      return;
    }
    w.onChange([...w.items, v]);
    _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final placeholder =
        w.placeholder ??
        (_special ? DifyI18n.tr('common', 'model.params.stop_sequencesPlaceholder') : _docs('segment.addKeyWord'));
    final style = difyStyle(DifyType.systemXsRegular, DifyColors.textPrimary);
    final hintStyle = style.copyWith(color: DifyColors.textPlaceholder);
    Widget input = ListenableBuilder(
      listenable: _text,
      builder: (context, _) {
        final shown = _text.text.isEmpty ? placeholder : _text.text;
        final p = TextPainter(
          text: TextSpan(text: shown, style: style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        final width = p.width.ceilToDouble() + 2;
        p.dispose();
        return SizedBox(
          width: width.clamp(0, w.isInWorkflow ? 146 : 300),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: TextField(
              controller: _text,
              focusNode: _focus,
              style: style,
              cursorColor: const Color(0xFF295EFF),
              cursorWidth: 1,
              decoration: InputDecoration.collapsed(hintText: placeholder, hintStyle: hintStyle),
              // Enter adds the tag and keeps the focus (no blur, which would add again).
              onEditingComplete: () {},
              onSubmitted: (v) {
                if (!_special) _newTag(v);
              },
            ),
          ),
        );
      },
    );
    if (w.label != null || w.invalid || w.description != null) {
      input = Semantics(
        label: w.label,
        hint: w.description,
        validationResult: w.invalid ? SemanticsValidationResult.invalid : SemanticsValidationResult.none,
        child: input,
      );
    }
    return Container(
      constraints: BoxConstraints(minWidth: w.isInWorkflow ? 0 : 200),
      padding: _special ? const EdgeInsets.only(left: 4, bottom: 4) : EdgeInsets.zero,
      decoration: _special
          ? BoxDecoration(color: DifyColors.componentsInputBgNormal, borderRadius: BorderRadius.circular(DifyRadius.lg))
          : null,
      child: Wrap(
        children: [
          for (final (i, item) in w.items.indexed)
            Container(
              margin: const EdgeInsets.only(top: 4, right: 4),
              padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
              decoration: BoxDecoration(
                color: DifyColors.componentsBadgeWhiteToDark,
                border: Border.all(color: DifyColors.dividerDeep),
                borderRadius: BorderRadius.circular(DifyRadius.md),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DifyText(item, DifyType.systemXsRegular, color: DifyColors.textSecondary),
                  if (!w.disableRemove)
                    DifyPressable(
                      semanticLabel: '${DifyI18n.tr('common', 'operation.remove')} $item',
                      onPressed: () => w.onChange([...w.items]..removeAt(i)),
                      builder: (context, hovered, focused) => SizedBox(
                        width: 16,
                        height: 16,
                        child: Center(child: RemixIcon('close-line', size: 14, color: DifyColors.textTertiary)),
                      ),
                    ),
                ],
              ),
            ),
          if (!w.disableAdd)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: _special
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(DifyRadius.md),
                      border: Border.all(color: _focused ? DifyColors.dividerDeep : const Color(0x00000000)),
                    )
                  : null,
              foregroundDecoration: _special
                  ? null
                  : CssDashedBorder(color: DifyColors.dividerDeep, radius: DifyRadius.md),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: [
                  if (!_focused && !_special) RemixIcon('add-line', size: 14, color: DifyColors.textPlaceholder),
                  Flexible(child: input),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
