import 'package:flutter/widgets.dart';

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../files/file_links.dart';
import '../i18n/dify_i18n.dart';

/// A server-normalized progress image. Failed/expired links remain an explicit
/// placeholder and never turn a running node into a failed workflow.
class AgentProgressImage extends StatelessWidget {
  const AgentProgressImage({
    super.key,
    required this.url,
    this.caption = '',
    this.height = 132,
    this.expandable = true,
  });
  final String url, caption;
  final double height;
  final bool expandable;
  @override
  Widget build(BuildContext context) {
    final safe = runtimeFileLink(url);
    Widget unavailable() => Center(
      child: DifyTextLine(
        DifyI18n.tr('agent-v-2', 'inline.progressImageUnavailable'),
        maxLines: 3,
        style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
      ),
    );
    final picture = Container(
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DifyColors.backgroundSectionBurn,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: safe == null
          ? unavailable()
          : Image.network(safe, fit: BoxFit.contain, semanticLabel: caption, errorBuilder: (_, _, _) => unavailable()),
    );
    if (!expandable || safe == null) return picture;
    return DifyPressable(
      semanticLabel: DifyI18n.tr('agent-v-2', 'inline.enlargeProgressImage'),
      onPressed: () => showDifyDialog<void>(
        context,
        builder: (dialog) => DifyDialogSurface(
          width: 960,
          bordered: true,
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: DifyButton(
                  onPressed: () => Navigator.of(dialog).pop(),
                  child: DifyTextLine(DifyI18n.tr('common', 'operation.close')),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: InteractiveViewer(
                  child: AgentProgressImage(
                    url: safe,
                    caption: caption,
                    height: MediaQuery.sizeOf(dialog).height * .6,
                    expandable: false,
                  ),
                ),
              ),
              if (caption.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: DifyTextLine(
                    caption,
                    maxLines: null,
                    style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      ),
      builder: (_, _, _) => picture,
    );
  }
}
