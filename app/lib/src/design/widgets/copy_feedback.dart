/// Dify's CopyFeedback (web/app/components/base/copy-feedback).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../i18n/dify_i18n.dart';
import '../dify_icon.dart';
import 'widgets.dart';

/// DifyCopyFeedback: an IconButton copying [content], "Copy" / "Copied" (2 s) as its name and tooltip.
class DifyCopyFeedback extends StatefulWidget {
  const DifyCopyFeedback({super.key, required this.content});
  final String content;

  @override
  State<DifyCopyFeedback> createState() => _DifyCopyFeedbackState();
}

class _DifyCopyFeedbackState extends State<DifyCopyFeedback> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.content));
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = DifyI18n.tr('app-overview', 'overview.appInfo.embedded.${_copied ? 'copied' : 'copy'}');
    return DifyTooltip(
      content: DifyTextLine(label),
      child: DifyIconButton(
        label: label,
        icon: RemixIcon(_copied ? 'clipboard-fill' : 'clipboard-line', size: 16),
        onPressed: _copy,
      ),
    );
  }
}
