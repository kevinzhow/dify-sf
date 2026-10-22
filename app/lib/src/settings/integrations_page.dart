/// integrations/index.tsx, modal.tsx, section-renderer.tsx and page-header.tsx: where Dify 1.17.1 keeps the model
/// providers: the Integrations page (the sidebar of sections and the section's page) in the settings modal (Dify's
/// settings destination `provider`, opened by the model selector's "Model Provider Settings" and the main
/// navigation's Integrations). dify-sf has the Model Provider section; Dify's tool, data source, trigger, agent
/// strategy, extension and custom endpoint sections need plugins or services it does not have, and its install /
/// marketplace and permission actions need plugins.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Colors;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../cards/provider_icon_image.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../open_url.dart';
import '../workflow/workspace_models.dart';
import 'model_provider/model_provider_env.dart';
import 'model_provider/model_provider_page.dart';

String _t(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// IntegrationSection, as far as dify-sf has the sections.
enum IntegrationSection { provider }

/// The docs page of the Model Provider section's "Learn more".
const modelProviderDocsUrl = 'https://docs.dify.ai/en/use-dify/workspace/model-providers';

/// Opens the integrations settings modal on [section] (Dify's settings destination); resolves when it closes.
Future<void> showIntegrationsSetting(
  BuildContext context, {
  required ModelProviderEnv env,
  IntegrationSection section = IntegrationSection.provider,
}) => showDifyDialog<void>(
  context,
  barrierLabel: 'Dismiss',
  barrierColor: Colors.transparent,
  transition: DifyDialogTransition.fade,
  builder: (context) => ModelProviderScope(
    env: env,
    child: IntegrationsSettingModal(section: section),
  ),
);

/// Opens the model provider settings for a member with [role] over [models], then refetches what the editor reads.
Future<void> showModelProviderSettings(BuildContext context, {required WorkspaceModels models, String? role}) async {
  await showIntegrationsSetting(context, env: ModelProviderEnv.forRole(models, role));
  unawaited(models.reload());
}

/// IntegrationsSettingModal: MenuDialog (the whole screen on `bg-background-sidenav-bg backdrop-blur-md`, the close
/// button with "ESC" at `top-6 right-6`) around `mx-auto flex h-dvh w-[min(1440px,calc(100vw-48px))] py-6` and the
/// panel (`rounded-2xl border border-divider-subtle bg-components-panel-bg shadow-2xl`) holding the page.
class IntegrationsSettingModal extends StatelessWidget {
  const IntegrationsSettingModal({super.key, this.section = IntegrationSection.provider, this.onCancel});

  final IntegrationSection section;

  /// Defaults to closing the dialog.
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    void close() => onCancel != null ? onCancel!() : Navigator.of(context).maybePop();
    final title = _t('settings.integrations');
    return DifySurface(
      child: Semantics(
        container: true,
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: title,
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): close},
          child: Focus(
            autofocus: true,
            child: ClipRect(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: ColoredBox(
                  color: DifyColors.backgroundSidenavBg,
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final width = (c.maxWidth - 48).clamp(0.0, 1440.0);
                      return Stack(
                        children: [
                          Center(
                            child: SizedBox(
                              width: width,
                              height: c.maxHeight,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 24),
                                child: Container(
                                  clipBehavior: Clip.antiAlias,
                                  decoration: BoxDecoration(
                                    color: DifyColors.componentsPanelBg,
                                    borderRadius: BorderRadius.circular(DifyRadius.xxl),
                                    border: Border.all(color: DifyColors.dividerSubtle),
                                    boxShadow: DifyShadows.n2xl,
                                  ),
                                  child: IntegrationsPage(section: section),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 24,
                            right: 24,
                            child: Column(
                              children: [
                                DifyIconButton(
                                  key: const ValueKey('integrations-close'),
                                  label: _t('operation.close'),
                                  variant: DifyButtonVariant.tertiary,
                                  size: DifyIconButtonSize.xl,
                                  icon: const RemixIcon('close-line', size: 20),
                                  onPressed: close,
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: ExcludeSemantics(
                                    child: Text(
                                      'ESC',
                                      style: difyTextStyle(DifyType.system2xsMediumUppercase, DifyColors.textTertiary),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// IntegrationsPage: the sidebar (`w-50 border-r border-divider-burn px-2 py-2`, "Integrations" in
/// `title-2xl-semi-bold`, the section buttons `h-8 rounded-lg py-1 pr-1 pl-2 system-sm-medium`, the active one
/// `bg-state-base-active`) and the section: its header (`items-start pt-3 pb-2`, the title in
/// `title-2xl-semi-bold`, the description with "Learn more", then the page's toolbar) and the scrolling body.
class IntegrationsPage extends StatefulWidget {
  const IntegrationsPage({super.key, this.section = IntegrationSection.provider, this.onSectionChange});

  final IntegrationSection section;
  final ValueChanged<IntegrationSection>? onSectionChange;

  @override
  State<IntegrationsPage> createState() => _IntegrationsPageState();
}

class _IntegrationsPageState extends State<IntegrationsPage> {
  String _providerSearch = '';

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final sectionTitle = _t('settings.provider');
    return ProviderIconScope(
      source: env.models.icons,
      child: ColoredBox(
        color: DifyColors.componentsPanelBg,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 200,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: DifyColors.componentsPanelBg,
                border: Border(right: BorderSide(color: DifyColors.dividerBurn)),
              ),
              alignment: AlignmentDirectional.topEnd,
              child: SizedBox(
                width: 184,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 4, 0, 2),
                      child: SizedBox(
                        height: 24,
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Semantics(
                            header: true,
                            child: Text(
                              _t('settings.integrations'),
                              style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: _SidebarNavItem(
                        label: sectionTitle,
                        icon: 'brain-2-line',
                        active: widget.section == IntegrationSection.provider,
                        onTap: () => widget.onSectionChange?.call(IntegrationSection.provider),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ModelProviderPage(
                hideSystemModelSelectorProviderSettingsFooter: true,
                stickyToolbar: true,
                searchText: _providerSearch,
                onSearchTextChange: (v) => setState(() => _providerSearch = v),
                layout: (context, toolbar, body) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 12,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 2,
                            children: [
                              Text(
                                sectionTitle,
                                key: const ValueKey('integrations-section-title'),
                                style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                              ),
                              _DescriptionWithLearnMore(text: _t('modelProvider.pageDesc'), href: modelProviderDocsUrl),
                            ],
                          ),
                          toolbar,
                        ],
                      ),
                    ),
                    Expanded(
                      child: Semantics(
                        container: true,
                        label: sectionTitle,
                        child: SingleChildScrollView(
                          key: const ValueKey('integrations-scroll'),
                          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                          child: body,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A sidebar section button (sidebar-nav-item.tsx).
class _SidebarNavItem extends StatelessWidget {
  const _SidebarNavItem({required this.label, required this.icon, required this.active, required this.onTap});

  final String label, icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onTap,
    builder: (context, hovered, focused) => Semantics(selected: active, child: _item(hovered, focused)),
  );

  Widget _item(bool hovered, bool focused) {
    final color = active
        ? DifyColors.componentsMenuItemTextActive
        : hovered
        ? DifyColors.componentsMenuItemTextHover
        : DifyColors.componentsMenuItemText;
    return Container(
      height: 32,
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: active
            ? DifyColors.stateBaseActive
            : hovered
            ? DifyColors.stateBaseHover
            : null,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
      ),
      child: Row(
        spacing: 8,
        children: [
          SizedBox.square(
            dimension: 20,
            child: Center(child: RemixIcon(icon, size: 16, color: color)),
          ),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: difyTextStyle(DifyType.systemSmMedium, color),
            ),
          ),
        ],
      ),
    );
  }
}

/// DescriptionWithLearnMore: the description (`system-xs-regular text-text-tertiary`, truncated) and "Learn more"
/// (`text-text-accent`, the external link icon).
class _DescriptionWithLearnMore extends StatelessWidget {
  const _DescriptionWithLearnMore({required this.text, required this.href});
  final String text, href;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 2,
    children: [
      Flexible(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
        ),
      ),
      Semantics(
        link: true,
        linkUrl: Uri.parse(href),
        label: _t('modelProvider.learnMore'),
        excludeSemantics: true,
        child: GestureDetector(
          onTap: () => openExternalUrl(href),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _t('modelProvider.learnMore'),
                  style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textAccent),
                ),
                RemixIcon('external-link-line', size: 12, color: DifyColors.textAccent),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}
