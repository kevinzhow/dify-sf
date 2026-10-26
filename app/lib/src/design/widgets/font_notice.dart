import 'package:flutter/widgets.dart';

import '../dify_fonts.dart';
import '../dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import 'button.dart';
import 'text.dart';

/// A failed lazy shard is recoverable without reloading or losing input.
class DifyFontLoadNotice extends StatelessWidget {
  const DifyFontLoadNotice({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: DifyFonts.failed,
    builder: (context, failed, _) => !failed
        ? const SizedBox.shrink()
        : Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 480),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: DifyColors.componentsPanelBg,
                    borderRadius: BorderRadius.circular(DifyRadius.lg),
                    boxShadow: DifyShadows.lg,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: DifyTextLine(DifyI18n.tr('common', 'web.fontLoadFailed'), maxLines: 3)),
                      const SizedBox(width: 12),
                      DifyButton(
                        size: DifyButtonSize.small,
                        onPressed: DifyFonts.retry,
                        child: DifyTextLine(DifyI18n.tr('common', 'operation.retry')),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
  );
}
