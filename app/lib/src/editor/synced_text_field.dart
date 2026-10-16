import 'dart:async';

import 'package:flutter/material.dart';

/// A text field bound to one register of the shared document.
///
/// * Typing is debounced into one small op per pause ([onCommit]), flushed on submit and on losing focus.
/// * [onCommit] receives the version the user was looking at when this draft *began* (`baseSeq`), so a write
///   that landed meanwhile makes the edit conflict instead of being silently overwritten.
/// * While the user has an unsent draft, remote changes do not clobber it; otherwise the field always shows
///   the document's current value (including the winner after a rejected edit).
class SyncedTextField extends StatefulWidget {
  const SyncedTextField({
    super.key,
    required this.value,
    required this.currentVersion,
    required this.onCommit,
    this.label,
    this.maxLines = 1,
    this.minLines,
    this.monospace = false,
    this.debounce = const Duration(milliseconds: 700),
    this.decoration,
    this.keyboardType,
  });

  final String value;

  /// The document version right now (read at the first keystroke of a draft).
  final int Function() currentVersion;
  final void Function(String text, int baseSeq) onCommit;
  final String? label;
  final int? maxLines;
  final int? minLines;
  final bool monospace;
  final Duration debounce;
  final InputDecoration? decoration;
  final TextInputType? keyboardType;

  @override
  State<SyncedTextField> createState() => _SyncedTextFieldState();
}

class _SyncedTextFieldState extends State<SyncedTextField> {
  late final TextEditingController _controller = TextEditingController(text: widget.value);
  late final FocusNode _focus = FocusNode()..addListener(_onFocus);
  Timer? _timer;
  int? _draftBase;
  bool get _dirty => _draftBase != null;

  @override
  void didUpdateWidget(SyncedTextField old) {
    super.didUpdateWidget(old);
    if (!_dirty && widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length.clamp(0, widget.value.length)),
      );
    }
  }

  void _onChanged(String text) {
    _draftBase ??= widget.currentVersion();
    _timer?.cancel();
    _timer = Timer(widget.debounce, _flush);
  }

  void _onFocus() {
    if (!_focus.hasFocus) _flush();
  }

  void _flush() {
    _timer?.cancel();
    final base = _draftBase;
    if (base == null) return;
    _draftBase = null;
    final text = _controller.text;
    if (text != widget.value) widget.onCommit(text, base);
  }

  @override
  void dispose() {
    _flush(); // never drop a draft because the panel closed
    _timer?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      keyboardType: widget.keyboardType,
      style: widget.monospace ? const TextStyle(fontFamily: 'monospace', fontSize: 13) : null,
      decoration: (widget.decoration ?? const InputDecoration()).copyWith(
        labelText: widget.label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: _onChanged,
      onSubmitted: (_) => _flush(),
    );
  }
}
