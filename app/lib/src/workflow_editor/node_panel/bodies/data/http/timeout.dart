/// The HTTP node's Timeout section (components/timeout/index.tsx).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../design/dify_tokens.g.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../../workflow/dify_json.dart';
import '../data_common.dart';

/// A number field's committed text (dify-ui NumberField with `maximumFractionDigits: 0`): an integer clamped to
/// [min]..[max], null for an empty field; [fallback] when the text is no number.
int? timeoutValueOf(String text, {required int min, required int max, int? fallback}) {
  final t = text.trim();
  if (t.isEmpty) return null;
  final n = num.tryParse(t);
  if (n == null) return fallback;
  return n.round().clamp(min, max);
}

/// Timeout: a collapsible "Timeout" with the connection, read and write timeouts (seconds; empty: the server's
/// default). The maxima are the payload's `max_*` values, else [defaultTimeout]'s (the server's block default), else
/// 10 / 600 / 600.
class HttpTimeout extends StatelessWidget {
  const HttpTimeout({
    super.key,
    required this.payload,
    required this.onChange,
    this.readonly = false,
    this.defaultTimeout = const {},
  });

  final Map<String, Object?> payload;
  final ValueChanged<Map<String, Object?>> onChange;
  final bool readonly;
  final Map<String, Object?> defaultTimeout;

  int _max(String key, int fallback) {
    for (final v in [payload[key], defaultTimeout[key]]) {
      if (v is num && v != 0) return v.toInt();
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    Widget field(String key, String label, String placeholder, int max) => TimeoutField(
      title: wf(label),
      description: wf(placeholder),
      value: switch (payload[key]) {
        final num n => n.toInt(),
        _ => null,
      },
      readOnly: readonly,
      min: 1,
      max: max,
      onChange: (v) => onChange({...payload, key: v}),
    );
    return FieldCollapse(
      title: wf('nodes.http.timeout.title'),
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            field(
              'connect',
              'nodes.http.timeout.connectLabel',
              'nodes.http.timeout.connectPlaceholder',
              _max('max_connect_timeout', 10),
            ),
            field(
              'read',
              'nodes.http.timeout.readLabel',
              'nodes.http.timeout.readPlaceholder',
              _max('max_read_timeout', 600),
            ),
            field(
              'write',
              'nodes.http.timeout.writeLabel',
              'nodes.http.timeout.writePlaceholder',
              _max('max_write_timeout', 600),
            ),
          ],
        ),
      ),
    );
  }
}

/// InputField: the label (`text-[13px] font-medium text-text-primary`) and its description (`text-xs
/// text-text-tertiary`) on one 18 px line, the number input 4 px below. The typed number is committed on blur or
/// Enter (null when emptied).
class TimeoutField extends StatefulWidget {
  const TimeoutField({
    super.key,
    required this.title,
    required this.description,
    required this.value,
    required this.onChange,
    required this.min,
    required this.max,
    this.readOnly = false,
  });

  final String title, description;
  final int? value;
  final ValueChanged<int?> onChange;
  final int min, max;
  final bool readOnly;

  @override
  State<TimeoutField> createState() => _TimeoutFieldState();
}

class _TimeoutFieldState extends State<TimeoutField> {
  late final _focus = FocusNode(debugLabel: 'TimeoutField')..addListener(_focusChanged);
  late String _text = _shown;

  String get _shown => widget.value?.toString() ?? '';

  @override
  void didUpdateWidget(TimeoutField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus) _text = _shown;
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    if (widget.readOnly) return;
    final next = timeoutValueOf(_text, min: widget.min, max: widget.max, fallback: widget.value);
    setState(() => _text = next?.toString() ?? '');
    if (next != widget.value) widget.onChange(next);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        SizedBox(
          height: 18,
          child: LayoutBuilder(
            builder: (context, c) => Row(
              spacing: 8,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: (c.maxWidth - 8).clamp(0, double.infinity)),
                  child: Text(
                    w.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 18 / 13,
                      fontWeight: FontWeight.w500,
                      color: DifyColors.textPrimary,
                    ),
                  ),
                ),
                Flexible(
                  child: Text(
                    w.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
        ),
        Semantics(
          textField: true,
          label: w.title,
          hint: w.description,
          readOnly: w.readOnly,
          child: DifyInput(
            value: _text,
            focusNode: _focus,
            placeholder: w.description,
            readOnly: w.readOnly,
            height: 32,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            formatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]'))],
            onChanged: (v) => _text = v,
            onSubmitted: (_) => _commit(),
          ),
        ),
      ],
    );
  }
}

/// The payload's timeout, `{}` when missing.
Map<String, Object?> timeoutOf(Object? data) => switch (jsGet(data, 'timeout')) {
  final Map m => m.cast<String, Object?>(),
  _ => <String, Object?>{},
};
