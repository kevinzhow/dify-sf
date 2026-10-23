/// dify-ui's Input (packages/dify-ui/src/input) and the text-field box it shares with NumberField.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../dify_tokens.g.dart';
import '../css_metrics.dart';
import '../dify_fonts.dart';
import 'widgets.dart';

/// The text-field box shared by Input and NumberField: `rounded-lg border border-transparent
/// bg-components-input-bg-normal`, hover `border-components-input-border-hover bg-components-input-bg-hover`, focus
/// `border-components-input-border-active bg-components-input-bg-active shadow-xs`, disabled
/// `bg-components-input-bg-disabled`; read-only boxes keep the normal look.
class DifyInputBox extends StatefulWidget {
  const DifyInputBox({
    super.key,
    required this.focusNode,
    required this.child,
    this.disabled = false,
    this.readOnly = false,
    this.invalid = false,
  });
  final FocusNode focusNode;
  final Widget child;
  final bool disabled, readOnly, invalid;

  @override
  State<DifyInputBox> createState() => _DifyInputBoxState();
}

class _DifyInputBoxState extends State<DifyInputBox> {
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_changed);
  }

  @override
  void didUpdateWidget(DifyInputBox old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_changed);
      widget.focusNode.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final focused = w.focusNode.hasFocus && !w.disabled;
    final hovered = _hovered && !w.readOnly && !w.disabled;
    var bg = DifyColors.componentsInputBgNormal;
    var border = const Color(0x00000000);
    if (w.disabled) {
      bg = DifyColors.componentsInputBgDisabled;
    } else if (w.invalid) {
      bg = DifyColors.componentsInputBgDestructive;
      border = DifyColors.componentsInputBorderDestructive;
    } else if (focused) {
      bg = DifyColors.componentsInputBgActive;
      border = DifyColors.componentsInputBorderActive;
    } else if (hovered) {
      bg = DifyColors.componentsInputBgHover;
      border = DifyColors.componentsInputBorderHover;
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        decoration: Css.boxDecoration(
          BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(color: border),
            boxShadow: focused ? DifyShadows.xs : null,
          ),
        ),
        child: w.child,
      ),
    );
  }
}

/// A [TextEditingController] kept in step with a controlled value: replaced when [value] changes from outside, left
/// alone while it matches (so the selection survives typing).
mixin DifyControlledText<T extends StatefulWidget> on State<T> {
  late final controller = TextEditingController(text: textOf(widget));
  String textOf(T widget);

  void syncText() {
    final text = textOf(widget);
    if (controller.text != text) controller.value = TextEditingValue(text: text, selection: _end(text));
  }

  static TextSelection _end(String s) => TextSelection.collapsed(offset: s.length);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

/// [TextField] with Dify's input text: `system-sm-regular text-components-input-text-filled`, placeholder colour,
/// `caret-primary-600`, no decoration of its own.
TextField difyTextField({
  required BuildContext context,
  required TextEditingController controller,
  required FocusNode focusNode,
  required TextStyle style,
  required EdgeInsets padding,
  String? placeholder,
  bool readOnly = false,
  bool disabled = false,
  ValueChanged<String>? onChanged,
  ValueChanged<String>? onSubmitted,
  List<TextInputFormatter>? formatters,
  TextInputType? keyboardType,
  bool obscureText = false,
  Iterable<String>? autofillHints,
  int? maxLength,
  TextInputAction? textInputAction,
  int? minLines,
  int? maxLines = 1,
}) => TextField(
  controller: controller,
  focusNode: focusNode,
  readOnly: readOnly,
  enabled: !disabled,
  obscureText: obscureText,
  autofillHints: autofillHints,
  autocorrect: !obscureText && keyboardType != TextInputType.emailAddress,
  enableSuggestions: !obscureText,
  textInputAction: textInputAction,
  maxLength: maxLength,
  maxLengthEnforcement: maxLength == null ? null : MaxLengthEnforcement.enforced,
  onChanged: onChanged,
  onSubmitted: onSubmitted,
  inputFormatters: formatters,
  keyboardType: keyboardType,
  style: DifyFonts.resolveStyle(style).copyWith(color: disabled ? DifyColors.componentsInputTextFilledDisabled : null),
  strutStyle: Css.lineStrut(
    DefaultTextStyle.of(context).style.merge(style),
    textScaler: MediaQuery.textScalerOf(context),
    centerCap: true,
  ),
  cursorColor: const Color(0xFF155EEF), // caret-primary-600
  cursorWidth: 1,
  minLines: minLines,
  maxLines: maxLines,
  decoration: InputDecoration(
    isCollapsed: true,
    border: InputBorder.none,
    contentPadding: padding,
    // Not the desktop platforms' compact density, which takes 8 px off the box (CSS has no such thing).
    visualDensity: VisualDensity.standard,
    hint: placeholder == null
        ? null
        : DifyTextLine(
            centerCap: true,
            placeholder,
            style: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
    hintStyle: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
    // `maxlength` shows no counter in a browser.
    counterText: '',
  ),
);

/// Focus only an interactive input-group add-on on pointer down. Static labels delegate their tap to the input;
/// other pressables throughout the app keep their existing focus lifecycle (e.g. comment reply navigation).
class _InputAddon extends StatefulWidget {
  const _InputAddon({required this.child, required this.focusInput, required this.focusControl});
  final bool focusControl;
  final Widget child;
  final VoidCallback focusInput;
  @override
  State<_InputAddon> createState() => _InputAddonState();
}

class _InputAddonState extends State<_InputAddon> {
  final _scope = FocusNode(debugLabel: 'input addon', canRequestFocus: false, skipTraversal: true);
  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _scope,
    canRequestFocus: false,
    skipTraversal: true,
    child: Listener(
      onPointerDown: (_) {
        if (!widget.focusControl) return;
        final target = _scope.descendants.where((n) => n.canRequestFocus && !n.skipTraversal).firstOrNull;
        target?.requestFocus();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.focusInput,
        child: TextFieldTapRegion(child: widget.child),
      ),
    ),
  );
}

/// dify-ui's Input: `w-full rounded-lg px-3 py-1.75 system-sm-regular` on the input box (32 px high). Controlled:
/// shows [value], reports edits with [onChanged]. [formatters] run on each edit (e.g. spaces to underscores).
class DifyInput extends StatefulWidget {
  const DifyInput({
    super.key,
    required this.value,
    this.onChanged,
    this.onSubmitted,
    this.placeholder,
    this.semanticLabel,
    this.readOnly = false,
    this.disabled = false,
    this.invalid = false,
    this.formatters,
    this.keyboardType,
    this.focusNode,
    this.height,
    this.leading,
    this.trailing,
    this.focusInteractiveAddons = true,
    this.onKeyEvent,
    this.textStyle,
    this.fontFamily,
    this.obscureText = false,
    this.autofillHints,
    this.maxLength,
    this.textInputAction,
  });

  final String value;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? placeholder;

  /// `aria-label`.
  final String? semanticLabel;
  final bool readOnly, disabled, invalid;
  final List<TextInputFormatter>? formatters;
  final TextInputType? keyboardType;
  final FocusNode? focusNode;

  /// A fixed height (`h-8` …); the default is the padding plus the line.
  final double? height;

  /// InputGroup addons before and after the text (the text loses its padding on that side).
  final Widget? leading, trailing;

  /// Pointer focus for interactive add-ons. False when the control manages focus itself (e.g. a search clear
  /// button that must not blur the search input even briefly). Static add-ons still focus the input.
  final bool focusInteractiveAddons;

  /// Keys pressed while the field has focus, before the text field sees them.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// The text's style (`system-sm-regular text-components-input-text-filled` by default); [fontFamily] replaces
  /// just the family (`font-mono` call sites).
  final TextStyle? textStyle;
  final String? fontFamily;

  /// `type="password"`, `autocomplete`, `maxlength` and the keyboard's action (Enter submits a form).
  final bool obscureText;
  final Iterable<String>? autofillHints;
  final int? maxLength;
  final TextInputAction? textInputAction;

  @override
  State<DifyInput> createState() => _DifyInputState();
}

class _DifyInputState extends State<DifyInput> with DifyControlledText<DifyInput> {
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode(debugLabel: 'DifyInput'));

  @override
  String textOf(DifyInput w) => w.value;

  @override
  void didUpdateWidget(DifyInput old) {
    super.didUpdateWidget(old);
    syncText();
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    Widget field = difyTextField(
      context: context,
      controller: controller,
      focusNode: _focus,
      style: (w.textStyle ?? difyTextStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled)).copyWith(
        fontFamily: w.fontFamily,
      ),
      padding: EdgeInsets.fromLTRB(w.leading == null ? 12 : 0, 7, w.trailing == null ? 12 : 0, 7),
      placeholder: w.placeholder,
      readOnly: w.readOnly,
      disabled: w.disabled,
      onChanged: w.onChanged,
      onSubmitted: w.onSubmitted,
      formatters: w.formatters,
      keyboardType: w.keyboardType,
      obscureText: w.obscureText,
      autofillHints: w.autofillHints,
      maxLength: w.maxLength,
      textInputAction: w.textInputAction,
    );
    if (w.height != null) {
      field = SizedBox(
        height: w.height! - 2,
        child: Center(child: field),
      );
    }
    if (w.onKeyEvent != null) {
      field = Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: w.onKeyEvent, child: field);
    }
    if (w.leading != null || w.trailing != null) {
      // Taps on the addons (the clear button) are not taps outside the field.
      field = FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Row(
          children: [
            if (w.leading != null)
              FocusTraversalOrder(
                order: const NumericFocusOrder(2),
                child: _InputAddon(
                  focusControl: w.focusInteractiveAddons,
                  focusInput: _focus.requestFocus,
                  child: w.leading!,
                ),
              ),
            Expanded(
              child: FocusTraversalOrder(order: const NumericFocusOrder(1), child: field),
            ),
            if (w.trailing != null)
              FocusTraversalOrder(
                order: const NumericFocusOrder(3),
                child: _InputAddon(
                  focusControl: w.focusInteractiveAddons,
                  focusInput: _focus.requestFocus,
                  child: w.trailing!,
                ),
              ),
          ],
        ),
      );
    }
    return Semantics(
      label: w.semanticLabel,
      validationResult: w.invalid ? SemanticsValidationResult.invalid : SemanticsValidationResult.none,
      child: DifyInputBox(
        focusNode: _focus,
        disabled: w.disabled,
        readOnly: w.readOnly,
        invalid: w.invalid,
        child: field,
      ),
    );
  }
}

/// Decoration-free multi-line input for a custom Dify surface (for example the
/// chat composer). Reuse the design system's TextField, font metrics and native
/// editing lifecycle rather than rebuilding EditableText accessibility and IME.
class DifyEditableArea extends StatelessWidget {
  const DifyEditableArea({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.style,
    required this.placeholder,
    this.enabled = true,
    this.readOnly = false,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle style;
  final String placeholder;
  final bool enabled, readOnly;
  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: difyTextField(
      context: context,
      controller: controller,
      focusNode: focusNode,
      style: style,
      padding: EdgeInsets.zero,
      placeholder: placeholder,
      disabled: !enabled,
      readOnly: readOnly,
      keyboardType: TextInputType.multiline,
      minLines: 1,
      maxLines: null,
    ),
  );
}
