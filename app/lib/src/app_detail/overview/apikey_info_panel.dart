/// web/app/components/app/overview/apikey-info-panel (Dify 1.17.1, community edition): "To get started, setup your
/// model provider first." above the Overview's charts while the workspace has no active LLM provider
/// (`GET models/model-types/llm`, a provider with `status: active`), with a button to the model provider settings
/// and a link to Dify Cloud; dismissible for the page's lifetime.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../open_url.dart';
import '../../workflow/workspace_models.dart';

/// The Cloud link of the community edition.
const difyCloudAppsUrl = 'https://cloud.dify.ai/apps';

class ApikeyInfoPanel extends StatefulWidget {
  const ApikeyInfoPanel({super.key, required this.models, required this.openProviderSettings, this.openUrl});

  /// The workspace's models (the LLM list decides whether the panel shows); null: none known, the panel shows.
  final WorkspaceModels? models;

  /// `setSettingsDestination('provider')`.
  final VoidCallback openProviderSettings;

  /// Opens the Cloud link in a new tab (`target="_blank" rel="noopener noreferrer"`); [openExternalUrl] by default.
  final void Function(String url)? openUrl;

  @override
  State<ApikeyInfoPanel> createState() => _ApikeyInfoPanelState();
}

class _ApikeyInfoPanelState extends State<ApikeyInfoPanel> {
  bool _show = true;

  @override
  void initState() {
    super.initState();
    if (widget.models case final m?) unawaited(m.ensureModelList('llm'));
  }

  @override
  Widget build(BuildContext context) {
    final models = widget.models;
    if (models == null) return _panel(context);
    return ListenableBuilder(
      listenable: models,
      builder: (context, _) {
        // `data: hasActiveProvider = false`: the panel shows while the list loads.
        final active = models.modelListJson('llm').any((p) => p['status'] == 'active');
        return active ? const SizedBox.shrink() : _panel(context);
      },
    );
  }

  Widget _panel(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    String t(String key) => DifyI18n.tr('appOverview', key);
    // `text-[24px] font-semibold text-text-primary mb-6 leading-8`
    final title = difyTextStyle(DifyTw.text24SemiboldLeading32, DifyColors.textPrimary);
    // `text-xs font-medium text-primary-600`
    final link = difyTextStyle(DifyType.systemXsMedium, DifyColors.primary600);
    return Container(
      key: const ValueKey('apikey-info-panel'),
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: DifyColors.componentsPanelBorder),
        boxShadow: DifyShadows.md,
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // `mb-6 leading-8`
                Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DifyTextLine(t('apiKeyInfo.selfHost.title.row1'), style: title),
                      DifyTextLine(t('apiKeyInfo.selfHost.title.row2'), style: title),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: DifyButton(
                    variant: DifyButtonVariant.primary,
                    onPressed: widget.openProviderSettings,
                    trailing: const DifyIcon('vender/line/general/link-external-02', size: 16),
                    child: DifyTextLine(
                      t('apiKeyInfo.setAPIBtn'),
                      style: DifyType.systemMdMedium.style, // `text-sm font-medium`
                    ),
                  ),
                ),
                // `mt-2 flex h-6.5 items-center space-x-1 p-1 text-xs font-medium text-primary-600`
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Semantics(
                    link: true,
                    label: t('apiKeyInfo.tryCloud'),
                    excludeSemantics: true,
                    onTap: () => (widget.openUrl ?? openExternalUrl)(difyCloudAppsUrl),
                    child: DifyPressable(
                      onPressed: () => (widget.openUrl ?? openExternalUrl)(difyCloudAppsUrl),
                      builder: (context, hovered, focused) => Container(
                        height: 26,
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 4,
                          children: [
                            DifyTextLine(t('apiKeyInfo.tryCloud'), style: link),
                            DifyIcon(
                              'vender/line/general/link-external-02',
                              size: 12,
                              color: DifyColors.primary600,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // `absolute top-4 right-4 flex size-8 cursor-pointer items-center justify-center`
          Positioned(
            top: 16,
            right: 16,
            child: Semantics(
              button: true,
              label: DifyI18n.tr('common', 'operation.close'),
              excludeSemantics: true,
              onTap: () => setState(() => _show = false),
              child: GestureDetector(
                key: const ValueKey('apikey-info-panel-close'),
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _show = false),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: SizedBox.square(
                    dimension: 32,
                    child: Center(child: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
