import 'package:flutter/widgets.dart';

import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import 'suggested_action.dart';

/// buildIntegrationPath('workflow-tool').
const workflowToolsPath = '/integrations/tools/workflow';

String _w(String key) => DifyI18n.tr('workflow', key);

/// app-publisher/workflow-tool-action: "Workflow as Tool". Not configured yet (or loading) it is a
/// [SuggestedAction] with a "Needs Setup" badge (a spinner while loading); configured, a card with its Ready /
/// Update Needed state, Configure (Reconfigure) and "Manage in Tools". [message] explains a [disabled] action.
class WorkflowToolAction extends StatelessWidget {
  const WorkflowToolAction({
    super.key,
    required this.disabled,
    required this.isLoading,
    this.message,
    required this.outdated,
    required this.published,
    required this.onConfigure,
    this.onOpenLink,
  });

  final bool disabled;
  final bool isLoading;
  final String? message;
  final bool outdated;
  final bool published;
  final VoidCallback onConfigure;
  final PublisherLinkHandler? onOpenLink;

  @override
  Widget build(BuildContext context) {
    final reason = disabled ? message : null;
    final label = _w('common.workflowAsTool');
    if (!published || isLoading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SuggestedAction(
            label: label,
            disabled: disabled,
            description: _w('common.workflowAsToolDescription'),
            endIcon: isLoading
                ? publisherStatus(DifyI18n.tr('common', 'loading'), const DifySpinner(size: 16))
                : _SetupStatus(_w('common.configureRequired')),
            icon: const RemixIcon('hammer-line'),
            onPressed: onConfigure,
          ),
          if (reason != null) _DisabledReason(reason),
        ],
      );
    }
    final configureLabel = outdated ? _w('common.workflowAsToolReconfigure') : _w('common.configure');
    final manageLabel = _w('common.manageInTools');
    final state = outdated ? _w('common.workflowAsToolUpdateNeeded') : _w('common.workflowAsToolReady');
    Widget card = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              const PublisherIconTile(icon: RemixIcon('hammer-line')),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 28),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 4, 4, 4),
                        child: Row(
                          spacing: 8,
                          children: [
                            Expanded(
                              child: DifyTextLine(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                              ),
                            ),
                            _StateLabel(state, outdated: outdated),
                          ],
                        ),
                      ),
                    ),
                    if (outdated)
                      Padding(
                        padding: const EdgeInsets.only(right: 16, bottom: 4),
                        child: DifyTextLine(
                          _w('common.workflowAsToolTip'),
                          style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textWarning),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        spacing: 4,
                        children: [
                          Flexible(
                            child: DifyButton(
                              size: DifyButtonSize.small,
                              disabled: disabled,
                              onPressed: onConfigure,
                              semanticLabel: configureLabel,
                              leading: const RemixIcon('equalizer-2-line', size: 14),
                              child: DifyTextLine(configureLabel, overflow: TextOverflow.ellipsis),
                            ),
                          ),
                          Flexible(
                            child: _ManageInTools(label: manageLabel, disabled: disabled, onOpenLink: onOpenLink),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (reason != null) _DisabledReason(reason),
      ],
    );
    return disabled ? Opacity(opacity: 0.3, child: card) : card;
  }
}

/// `flex h-6 items-center gap-1 rounded-md px-2 system-xs-medium`: a link to the tools page, or a disabled button.
class _ManageInTools extends StatelessWidget {
  const _ManageInTools({required this.label, required this.disabled, this.onOpenLink});
  final String label;
  final bool disabled;
  final PublisherLinkHandler? onOpenLink;

  @override
  Widget build(BuildContext context) => PublisherPressable(
    label: label,
    disabled: disabled,
    link: disabled ? null : workflowToolsPath,
    onPressed: () => onOpenLink?.call(workflowToolsPath, external: false),
    builder: (context, hovered, focused) {
      final color = disabled ? DifyColors.componentsButtonTertiaryTextDisabled : DifyColors.textTertiary;
      return Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: DifyFocusDecoration(
          color: hovered ? DifyColors.componentsButtonTertiaryBgHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
          boxShadow: difyFocusRing(focused && !disabled),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            Flexible(
              child: DifyTextLine(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: difyTextStyle(DifyType.systemXsMedium, color),
              ),
            ),
            RemixIcon('arrow-right-up-line', size: 14, color: color),
          ],
        ),
      );
    },
  );
}

/// disabled-reason.tsx: `mt-1 px-2.5 pb-2 system-xs-regular text-text-tertiary opacity-30`.
class _DisabledReason extends StatelessWidget {
  const _DisabledReason(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: 0.3,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: DifyTextLine(message, style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary)),
    ),
  );
}

/// setup-status.tsx: `rounded-[5px] border border-divider-deep bg-components-badge-bg-dimm px-1 py-0.5
/// system-2xs-medium-uppercase text-text-tertiary`.
class _SetupStatus extends StatelessWidget {
  const _SetupStatus(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => publisherStatus(
    label,
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: DifyColors.componentsBadgeBgDimm,
        border: Border.all(color: DifyColors.dividerDeep),
        borderRadius: BorderRadius.circular(DifyRadius.badge),
      ),
      child: DifyTextLine(
        difyTransform(DifyType.system2xsMediumUppercase, label),
        maxLines: 1,
        softWrap: false,
        style: difyTextStyle(DifyType.system2xsMediumUppercase, DifyColors.textTertiary),
      ),
    ),
  );
}

/// state-label.tsx: a small StatusDot and the label, `system-xs-semibold-uppercase` in green (warning when
/// [outdated]).
class _StateLabel extends StatelessWidget {
  const _StateLabel(this.label, {required this.outdated});
  final String label;
  final bool outdated;

  @override
  Widget build(BuildContext context) => publisherStatus(
    label,
    Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        DifyStatusDot(
          size: DifyStatusDotSize.small,
          status: outdated ? DifyStatusDotStatus.warning : DifyStatusDotStatus.success,
        ),
        DifyTextLine(
          difyTransform(DifyType.systemXsSemiboldUppercase, label),
          style: difyTextStyle(
            DifyType.systemXsSemiboldUppercase,
            outdated ? DifyColors.utilColorsWarningWarning600 : DifyColors.utilColorsGreenGreen600,
          ),
        ),
      ],
    ),
  );
}
