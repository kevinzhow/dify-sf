/// CopyId (nodes/tool/components/copy-id.tsx): an MCP tool's provider id under the card's description; a click
/// copies it (the tooltip and label turn to "Copied" until the pointer leaves, each change 100 ms debounced).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';

class CopyId extends StatefulWidget {
  const CopyId({super.key, required this.content});
  final String content;

  @override
  State<CopyId> createState() => _CopyIdState();
}

class _CopyIdState extends State<CopyId> {
  bool _copied = false;
  Timer? _timer;

  void _debounced(VoidCallback f) {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 100), f);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = DifyI18n.tr('appOverview', 'overview.appInfo.embedded.${_copied ? 'copied' : 'copy'}');
    return MouseRegion(
      onExit: (_) => _debounced(() {
        if (mounted) setState(() => _copied = false);
      }),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: DifyTooltip(
          content: Text(label),
          // The button handles the tap itself: it does not reach the card (event.stopPropagation()).
          child: DifyPressable(
            semanticLabel: label,
            onPressed: () => _debounced(() {
              unawaited(Clipboard.setData(ClipboardData(text: widget.content)));
              if (mounted) setState(() => _copied = true);
            }),
            builder: (context, hovered, focused) => Row(
              spacing: 2,
              children: [
                Expanded(
                  child: DifyText(
                    widget.content,
                    DifyType.system2xsRegular,
                    color: hovered ? DifyColors.textTertiary : DifyColors.textQuaternary,
                  ),
                ),
                Opacity(
                  opacity: hovered ? 1 : 0,
                  child: RemixIcon('file-copy-line', size: 12, color: DifyColors.textTertiary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
