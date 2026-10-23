import 'package:flutter/widgets.dart';

import '../../../design/css_metrics.dart';
import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../format.dart' as format;
import '../hotkey.dart';
import 'actions_section.dart';
import 'suggested_action.dart';
import 'summary_section.dart';
import 'utils.dart';
import 'version_info_modal.dart';

export 'suggested_action.dart' show PublisherLinkHandler;
export 'summary_section.dart' show PublishedWorkflowInfo;
export 'version_info_modal.dart' show PublisherToast, PublisherToastType, VersionInfoUpdate;

/// The app being published (the parts of Dify's `appDetail` the publisher reads).
@immutable
class PublisherAppInfo {
  const PublisherAppInfo({
    required this.id,
    this.name = '',
    required this.mode,
    this.description = '',
    this.appBaseUrl = '',
    this.accessToken = '',
    this.accessMode,
  });

  final String id;
  final String name;

  /// `AppModeEnum`: `workflow`, `advanced-chat`, `chat`, `agent-chat` or `completion`.
  final String mode;
  final String description;

  /// `site.app_base_url` and `site.access_token`: the web app's address.
  final String appBaseUrl;
  final String accessToken;

  /// `access_mode` (`public`, `private`, `private_all`, `sso_verified`): `sso_verified` (external members) apps
  /// ignore [PublisherCapabilities.noAccessPermission].
  final String? accessMode;
}

/// What the user may do and what the host knows, which Dify reads from permissions, system features and queries.
@immutable
class PublisherCapabilities {
  const PublisherCapabilities({
    this.canViewAccessPoint = false,
    this.showDeployAction = false,
    this.showMarketplaceAction = false,
    this.noAccessPermission = false,
    this.canManageTools = true,
    this.workflowToolLoading = false,
    this.workflowToolOutdated = false,
    this.hasHiddenVariables = false,
  });

  /// The app ACL's `canViewAccessPoint`: shows the Access Point action.
  final bool canViewAccessPoint;

  /// The Deploy action (Dify shows it with multi-environment deployment, whose environment tabs aren't ported).
  final bool showDeployAction;

  /// `systemFeatures.enable_creators_platform`: shows Publish to Marketplace.
  final bool showMarketplaceAction;

  /// Web app auth is on and the user may not open this app's web app (`useGetUserCanAccessApp`).
  final bool noAccessPermission;

  /// `tool.manage`: Workflow as Tool is configurable.
  final bool canManageTools;

  /// The workflow tool's configuration is loading / no longer matches the workflow (useConfigureButton).
  final bool workflowToolLoading;
  final bool workflowToolOutdated;

  /// The start node has hidden inputs: Open web app gets a run config button ([AppPublisher.onOpenRunConfig]).
  final bool hasHiddenVariables;
}

/// app-publisher's AppPublisher: the header's primary "Publish" button and its panel (PublisherPanel +
/// PublisherContent's built-in publisher): the published version, publishing (also `Mod+Shift+P` while mounted),
/// restoring, naming the version, and the quick actions. Publishing locks until the panel is reopened.
///
/// Everything Dify fetches is given as data ([app], [publishedWorkflow], [capabilities]) and every side effect is a
/// callback; a missing callback leaves its action without effect (or disabled where Dify disables it).
class AppPublisher extends StatefulWidget {
  const AppPublisher({
    super.key,
    this.disabled = false,
    this.publishDisabled = false,
    this.publishedAt,
    this.draftUpdatedAt,
    this.onPublish,
    this.onRestore,
    this.onToggle,
    this.crossAxisOffset = 0,
    this.toolPublished = false,
    this.workflowToolAvailable = true,
    this.missingStartNode = false,
    this.hasTriggerNode = false,
    this.startNodeLimitExceeded = false,
    this.hasHumanInputNode = false,
    this.app,
    this.publishedWorkflow,
    this.capabilities = const PublisherCapabilities(),
    this.onOpenLink,
    this.onOpenRunConfig,
    this.onConfigureWorkflowTool,
    this.onPublishToMarketplace,
    this.onUpdateVersionInfo,
    this.onToast,
    this.formatTimeFromNow = _fromNow,
  });

  /// The trigger is disabled and the panel can't open.
  final bool disabled;

  /// The publish button (and the hotkey) is disabled.
  final bool publishDisabled;

  /// When the app was last published (ms); for workflow apps [publishedWorkflow]'s `created_at` takes precedence.
  final int? publishedAt;

  /// When the draft was last saved (ms): "Auto-Saved · <time>" for workflow apps.
  final int? draftUpdatedAt;

  /// Publishes the draft. Throwing keeps the panel unlocked (Dify logs the error; the caller toasts it).
  final Future<void> Function()? onPublish;

  /// Restores the published version over the draft (chat apps); the panel closes after it, stays open if it throws.
  final Future<void> Function()? onRestore;

  /// The panel opened (true) or closed (false) by the user.
  final ValueChanged<bool>? onToggle;

  /// The panel's offset along the button (`alignOffset`).
  final double crossAxisOffset;

  /// The workflow is published as a tool.
  final bool toolPublished;

  /// The workflow can be a tool (a connected User Input node, ...).
  final bool workflowToolAvailable;
  final bool missingStartNode;
  final bool hasTriggerNode;

  /// The plan's trigger limit is exceeded: shows the upgrade hint under the publish button.
  final bool startNodeLimitExceeded;
  final bool hasHumanInputNode;

  /// The app; null: unknown (no mode-specific parts, Dify's missing `appDetail`).
  final PublisherAppInfo? app;

  /// The published workflow version (`useAppWorkflow`), for workflow and chatflow apps; null: none or not loaded,
  /// [publishedAt] is used then.
  final PublishedWorkflowInfo? publishedWorkflow;
  final PublisherCapabilities capabilities;

  /// Opens the web app (external) or a console page (`/app/<id>/access-point`, `/app/<id>/deploy`,
  /// `/integrations/tools/workflow`).
  final PublisherLinkHandler? onOpenLink;

  /// Opens the web app after asking for the start node's hidden inputs (WorkflowLaunchDialog), with the app's URL.
  final ValueChanged<String>? onOpenRunConfig;

  /// Opens the workflow tool configuration (WorkflowToolDrawer); the panel closes first.
  final VoidCallback? onConfigureWorkflowTool;

  /// Publishes the app to the creators platform and opens its redirect URL; throwing toasts
  /// `common.publishToMarketplaceFailed`. "Publishing..." shows while it runs; null disables the action.
  final Future<void> Function()? onPublishToMarketplace;

  /// Saves the published version's name and release notes; success and failure are toasted.
  final Future<void> Function(VersionInfoUpdate update)? onUpdateVersionInfo;
  final PublisherToast? onToast;

  /// dayjs `fromNow` of a time in ms ("3 minutes ago").
  final String Function(int milliseconds) formatTimeFromNow;

  @override
  State<AppPublisher> createState() => _AppPublisherState();
}

String _fromNow(int milliseconds) => format.formatTimeFromNow(milliseconds);

class _AppPublisherState extends State<AppPublisher> {
  bool _open = false;

  /// usePublishController's `published`: set after publishing, reset when the panel opens.
  bool _published = false;
  bool _publishingToMarketplace = false;

  String? get _mode => widget.app?.mode;
  bool get _isWorkflowApp => _mode == 'workflow' || _mode == 'advanced-chat';
  bool get _isChatApp => _mode == 'chat' || _mode == 'agent-chat' || _mode == 'completion';

  int? get _currentPublishedAt {
    final w = widget.publishedWorkflow;
    if (!_isWorkflowApp || w == null) return widget.publishedAt;
    return w.createdAt != 0 ? w.createdAt * 1000 : null;
  }

  void _setOpen(bool open) {
    if (mounted && open != _open) setState(() => _open = open);
  }

  void _handleOpenChange(bool next) {
    if (widget.disabled) return _setOpen(false);
    if (next) _published = false;
    widget.onToggle?.call(next);
    _setOpen(next);
  }

  Future<void> _handlePublish() async {
    try {
      await widget.onPublish?.call();
      if (mounted) setState(() => _published = true);
    } catch (_) {
      if (mounted) setState(() => _published = false);
    }
  }

  Future<void> _handleRestore() async {
    try {
      await widget.onRestore?.call();
      _setOpen(false);
    } catch (_) {}
  }

  void _hotkey() {
    if (widget.publishDisabled || _published) return;
    _handlePublish();
  }

  void _openVersionEditor() {
    final info = widget.publishedWorkflow;
    if (info == null) return;
    _setOpen(false);
    showVersionInfoModal(context, versionInfo: info, onPublish: _updateVersionInfo, onToast: widget.onToast);
  }

  Future<void> _updateVersionInfo(VersionInfoUpdate update) async {
    final save = widget.onUpdateVersionInfo;
    if (widget.app == null || update.id == null || save == null) return;
    try {
      await save(update);
      widget.onToast?.call(PublisherToastType.success, DifyI18n.tr('workflow', 'versionHistory.action.updateSuccess'));
    } catch (_) {
      widget.onToast?.call(PublisherToastType.error, DifyI18n.tr('workflow', 'versionHistory.action.updateFailure'));
    }
  }

  Future<void> _publishToMarketplace() async {
    final publish = widget.onPublishToMarketplace;
    if (widget.app == null || _publishingToMarketplace || publish == null) return;
    setState(() => _publishingToMarketplace = true);
    try {
      await publish();
    } catch (_) {
      widget.onToast?.call(PublisherToastType.error, DifyI18n.tr('workflow', 'common.publishToMarketplaceFailed'));
    } finally {
      if (mounted) setState(() => _publishingToMarketplace = false);
    }
  }

  void _configureWorkflowTool() {
    if (!widget.capabilities.canManageTools) return;
    _setOpen(false);
    widget.onConfigureWorkflowTool?.call();
  }

  Widget _panel(BuildContext context) {
    final w = widget, caps = w.capabilities, app = w.app;
    final publishedAt = _currentPublishedAt;
    final hasPublishedVersion = publishedAt != null && publishedAt != 0;
    final appUrl = getPublisherAppUrl(
      appBaseUrl: app?.appBaseUrl ?? '',
      accessToken: app?.accessToken ?? '',
      mode: _mode,
    );
    final noAccessPermission = caps.noAccessPermission && app != null && app.accessMode != 'sso_verified';
    final r = BorderRadius.circular(DifyRadius.xxl);
    return Container(
      width: 352,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height - 32),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        borderRadius: r,
        // shadow-xl shadow-shadow-shadow-5: the colour utility replaces shadow-xl's colours.
        boxShadow: [for (final s in DifyShadows.xl) s.copyWith(color: DifyColors.shadowShadow5)],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PublisherSummarySection(
              draftUpdatedAt: w.draftUpdatedAt,
              formatTimeFromNow: w.formatTimeFromNow,
              onPublish: _handlePublish,
              onRestore: _handleRestore,
              isChatApp: _isChatApp,
              isWorkflowApp: _isWorkflowApp,
              onEditVersion: _openVersionEditor,
              publishDisabled: w.publishDisabled,
              published: _published,
              publishedAt: publishedAt,
              startNodeLimitExceeded: w.startNodeLimitExceeded,
              versionInfo: _isWorkflowApp ? w.publishedWorkflow : null,
            ),
            PublisherActionsSection(
              appId: app?.id,
              appMode: _mode,
              appUrl: appUrl,
              canViewAccessPoint: caps.canViewAccessPoint,
              disabledFunctionButton: !hasPublishedVersion || w.missingStartNode || noAccessPermission,
              disabledFunctionTooltip: getDisabledFunctionTooltip(
                publishedAt: publishedAt,
                missingStartNode: w.missingStartNode,
                noAccessPermission: noAccessPermission,
              ),
              onOpenRunConfig: w.onOpenRunConfig,
              hasHumanInputNode: w.hasHumanInputNode,
              hasTriggerNode: w.hasTriggerNode,
              marketplaceActionDisabled: !hasPublishedVersion,
              publishedAt: publishedAt,
              publishingToMarketplace: _publishingToMarketplace,
              showDeployAction: caps.showDeployAction,
              showMarketplaceAction: caps.showMarketplaceAction,
              showRunConfig: caps.hasHiddenVariables,
              toolPublished: w.toolPublished,
              workflowToolAvailable: w.workflowToolAvailable && caps.canManageTools,
              workflowToolIsLoading: caps.workflowToolLoading,
              workflowToolMessage: !hasPublishedVersion || !w.workflowToolAvailable
                  ? DifyI18n.tr('workflow', 'common.workflowAsToolDisabledHint')
                  : null,
              workflowToolOutdated: caps.workflowToolOutdated,
              onConfigureWorkflowTool: _configureWorkflowTool,
              onPublishToMarketplace: w.onPublishToMarketplace == null ? null : _publishToMarketplace,
              onOpenLink: w.onOpenLink,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = DifyI18n.tr('workflow', 'common.publish');
    return PageHotkey(
      hotkey: appPublishHotkey,
      onPressed: _hotkey,
      child: DifyPopover(
        open: _open,
        onOpenChange: _handleOpenChange,
        placement: DifyPlacement.bottomEnd,
        sideOffset: 4,
        alignOffset: widget.crossAxisOffset,
        surface: false,
        semanticLabel: label,
        // Button variant primary, `py-2 pr-2 pl-3` (DifyButton has no padding override).
        builder: (context, c) => PublisherPressable(
          disabled: widget.disabled,
          onPressed: c.toggle,
          label: label,
          expanded: _open,
          builder: (context, hovered, focused) => DifyButtonSurface(
            look: difyButtonLook(
              DifyButtonVariant.primary,
              DifyButtonTone.normal,
              hovered: hovered,
              disabled: widget.disabled,
            ),
            radius: DifyButtonSize.medium.radius,
            focused: focused,
            child: Container(
              height: 32,
              padding: const EdgeInsets.only(left: 12, right: 8),
              child: DefaultTextStyle.merge(
                style: DifyButtonSize.medium.text,
                maxLines: 1,
                softWrap: false,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    DifyTextLine(label),
                    RemixIcon('arrow-down-s-line', color: DifyColors.componentsButtonPrimaryText),
                  ],
                ),
              ),
            ),
          ),
        ),
        content: Builder(builder: _panel),
      ),
    );
  }
}
