/// Agent v2's binding field (nodes/agent-v2/components/agent-roster-field.tsx, edit-in-console-link.tsx,
/// save-inline-agent-to-roster-dialog.tsx) and the agent picker (block-selector/agent-selector.tsx
/// AgentSelectorContent): the agent card in its states, the "Change" popover, the roster agent drawer, the inline
/// setup dialog and the "Save to Agents" dialog.
library;

import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../design/widgets/app_icon_picker.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../panel_fields/panel_fields.dart';
import 'group_host.dart';

String _w(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String _c(String key) => DifyI18n.tr('common', key);
String _a(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('agent-v-2', key, params);

/// AgentRosterDrawerMode.
enum AgentRosterDrawerMode { setup, detail }

/// `getAgentACLCapabilities(permission_keys).canConfigure`: edit, test-and-run or release-and-version.
bool canConfigureAgent(Object? permissionKeys) {
  final keys = jsList(permissionKeys);
  return keys.contains('agent.acl.edit') ||
      keys.contains('agent.acl.test_and_run') ||
      keys.contains('agent.acl.release_and_version');
}

/// `getAgentDetailPath(agentId, 'configure')`.
String agentConfigurePath(String agentId) => '/agents/$agentId/configure';

Color _hex(Object? bg, Color fallback) {
  if (bg is! String || !bg.startsWith('#') || bg.length != 7) return fallback;
  final v = int.tryParse(bg.substring(1), radix: 16);
  return v == null ? fallback : Color(0xFF000000 | v);
}

/// AgentRosterAvatar (AppIcon): the agent's emoji on its background (`rounded-lg`), or its image; [size] 32 (small),
/// 36 (the drawer's `size-9`), 20 (tiny).
class AgentAvatar extends StatelessWidget {
  const AgentAvatar({super.key, required this.agent, this.size = 32});
  final Json agent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final type = agent['icon_type'], icon = jsStr(agent['icon']);
    final radius = BorderRadius.circular(size >= 32 ? DifyRadius.lg : DifyRadius.md);
    if ((type == 'image' || type == 'link') && icon != null && icon.isNotEmpty) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.network(
          icon,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => SizedBox(width: size, height: size),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _hex(agent['icon_background'], DifyAppIconColors.defaultBackground),
        borderRadius: radius,
      ),
      child: Text(icon ?? '🤖', style: difyEmojiTextStyle(size * 0.56)),
    );
  }
}

/// InlineSetupAvatar: `size-8 rounded-full bg-background-default-burn` with the agent-v2 configure icon.
class InlineSetupAvatar extends StatelessWidget {
  const InlineSetupAvatar({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('inline-setup-avatar'),
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(shape: BoxShape.circle, color: DifyColors.backgroundDefaultBurn),
    child: DifyIcon('vender/agent-v2/configure', size: 14, color: DifyColors.textTertiary),
  );
}

/// The `h-13 rounded-[10px] border-[0.5px] bg-components-panel-on-panel-item-bg py-2 pr-4 pl-2 shadow-xs` card box,
/// destructive-bordered for the error / required states.
class _CardBox extends StatelessWidget {
  const _CardBox({required this.child, this.destructive = false, this.hovered = false, this.minHeight = false});
  final Widget child;
  final bool destructive, hovered, minHeight;

  @override
  Widget build(BuildContext context) => Container(
    height: minHeight ? null : 52,
    constraints: const BoxConstraints(minHeight: 52),
    padding: EdgeInsets.fromLTRB(8, 8, destructive && minHeight ? 8 : 16, 8),
    decoration: BoxDecoration(
      color: hovered ? DifyColors.componentsPanelOnPanelItemBgHover : DifyColors.componentsPanelOnPanelItemBg,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(
        color: destructive ? DifyColors.stateDestructiveBorder : DifyColors.componentsPanelBorder,
        width: 0.5,
      ),
      boxShadow: DifyShadows.xs,
    ),
    child: child,
  );
}

Widget _bar(double width, double height, double k) =>
    DifySkeletonRectangle(width: width, height: height, opacity: k, margin: EdgeInsets.zero);

/// The loading card's content: a `size-8 rounded-lg` square and two bars.
Widget _loadingContent() => Semantics(
  label: 'loading',
  child: Row(
    key: const ValueKey('agent-roster-loading'),
    spacing: 8,
    children: [
      const DifySkeletonRectangle(width: 32, height: 32, radius: DifyRadius.lg, margin: EdgeInsets.zero),
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [_bar(96, 10, 0.2), _bar(64, 8, 0.15)],
      ),
    ],
  ),
);

/// The destructive icon tile (`size-8 rounded-lg bg-state-destructive-hover`, `i-ri-error-warning-line`).
Widget _errorTile() => Container(
  width: 32,
  height: 32,
  alignment: Alignment.center,
  decoration: BoxDecoration(
    color: DifyColors.stateDestructiveHover,
    borderRadius: BorderRadius.circular(DifyRadius.lg),
  ),
  child: RemixIcon('error-warning-line', size: 16, color: DifyColors.textDestructive),
);

/// AgentRosterField: "Agent" with "Change" (the agent picker), then the agent card: an error with Retry, the
/// trigger opening the roster drawer or the inline setup dialog, a static card while it cannot open, a loading
/// card, or "Agent is required".
class AgentRosterField extends StatefulWidget {
  const AgentRosterField({
    super.key,
    required this.onChange,
    this.agent,
    this.agentId,
    this.canOpenPanel = true,
    this.errorMessage,
    this.isPanelOpen,
    this.isPanelCopyPending = false,
    this.isLoading = false,
    this.isInlineSetup = false,
    this.isRetrying = false,
    this.isPending = false,
    this.panelBody,
    this.panelMode = AgentRosterDrawerMode.detail,
    this.showPanelDetailActions = true,
    this.onMakeCopy,
    this.onPanelOpenChange,
    this.onRetry,
    this.onSaveInlineToRoster,
    this.onStartFromScratch,
    this.onOpenUrl,
    this.drawerWidth = 400,
  });

  final Json? agent;
  final String? agentId;
  final bool canOpenPanel;
  final String? errorMessage;
  final bool? isPanelOpen;
  final bool isPanelCopyPending, isLoading, isInlineSetup, isRetrying, isPending;
  final WidgetBuilder? panelBody;
  final AgentRosterDrawerMode panelMode;
  final bool showPanelDetailActions;
  final ValueChanged<Json> onChange;
  final VoidCallback? onMakeCopy, onRetry, onSaveInlineToRoster, onStartFromScratch;
  final ValueChanged<bool>? onPanelOpenChange;
  final void Function(String url)? onOpenUrl;

  /// The node panel's width (the drawer covers it: `--workflow-node-panel-width`).
  final double drawerWidth;

  @override
  State<AgentRosterField> createState() => _AgentRosterFieldState();
}

class _AgentRosterFieldState extends State<AgentRosterField> {
  final _selector = DifyFloatingController();
  final _drawer = OverlayPortalController();
  final _triggerFocus = FocusNode(debugLabel: 'agent roster trigger');
  bool _localPanelOpen = false;
  BuildContext? _dialogContext;
  bool _dialogShowing = false;

  bool get _panelOpen => widget.isPanelOpen ?? _localPanelOpen;

  void _setPanelOpen(bool open) {
    if (widget.onPanelOpenChange != null) {
      widget.onPanelOpenChange!(open);
    } else {
      setState(() => _localPanelOpen = open);
    }
  }

  @override
  void didUpdateWidget(AgentRosterField old) {
    super.didUpdateWidget(old);
    if (widget.isPending && _selector.isOpen) _selector.close();
  }

  @override
  void dispose() {
    _triggerFocus.dispose();
    if (_dialogShowing && _dialogContext != null && _dialogContext!.mounted) {
      final ctx = _dialogContext!;
      scheduleMicrotask(() {
        if (ctx.mounted) Navigator.of(ctx).maybePop();
      });
    }
    super.dispose();
  }

  /// Keeps the drawer and the inline dialog in step with the open state.
  void _syncPanel() {
    final showDrawer = _panelOpen && widget.agent != null && widget.canOpenPanel && !widget.isInlineSetup;
    final showDialog = _panelOpen && widget.agent != null && widget.canOpenPanel && widget.isInlineSetup;
    if (showDrawer != _drawer.isShowing) showDrawer ? _drawer.show() : _drawer.hide();
    if (showDialog && !_dialogShowing) {
      _dialogShowing = true;
      showDifyDialog<void>(
        context,
        dismissible: false,
        builder: (ctx) {
          _dialogContext = ctx;
          final agent = widget.agent ?? const {};
          return _EscapeCloses(
            child: DifyDialogSurface(
              label: jsKey(agent['name']),
              width: 1120,
              height: 760,
              child: _InlineDialogBody(builder: widget.panelBody),
            ),
          );
        },
      ).then((_) {
        _dialogShowing = false;
        _dialogContext = null;
        if (mounted && _panelOpen) _setPanelOpen(false);
        if (mounted) _triggerFocus.requestFocus();
      });
    } else if (!showDialog && _dialogShowing) {
      final ctx = _dialogContext;
      _dialogShowing = false;
      _dialogContext = null;
      if (ctx != null && ctx.mounted) Navigator.of(ctx).pop();
    }
  }

  Widget _agentContent(Json agent) {
    final inline = widget.isInlineSetup;
    return Row(
      spacing: 8,
      children: [
        if (inline) const InlineSetupAvatar() else AgentAvatar(agent: agent),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 2,
            children: [
              DifyText(
                inline ? _w('nodes.agent.roster.inlineSetup.name') : jsKey(agent['name']),
                DifyType.systemSmMedium,
                color: DifyColors.textSecondary,
              ),
              DifyText(
                inline ? _w('nodes.agent.roster.inlineSetup.type') : (jsStr(agent['role']) ?? ''),
                DifyType.systemXsRegular,
                color: DifyColors.textTertiary,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _trigger(Json agent) {
    final name = widget.isInlineSetup ? _w('nodes.agent.roster.inlineSetup.name') : jsKey(agent['name']);
    return DifyPressable(
      focusNode: _triggerFocus,
      semanticLabel: _w('nodes.agent.roster.openPanel', {'name': name}),
      onPressed: () => _setPanelOpen(true),
      builder: (context, hovered, focused) => _CardBox(
        hovered: hovered,
        child: Row(
          children: [
            Expanded(child: widget.isLoading ? _loadingContent() : _agentContent(agent)),
            RemixIcon('arrow-right-line', size: 16, color: DifyColors.textTertiary),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final w = widget;
    final agent = w.agent;
    if (w.errorMessage != null) {
      return Semantics(
        container: true,
        liveRegion: true,
        label: 'alert',
        child: _CardBox(
          destructive: true,
          minHeight: true,
          child: Row(
            spacing: 8,
            children: [
              _errorTile(),
              Expanded(
                child: DifyText(
                  w.errorMessage!,
                  DifyType.systemXsMedium,
                  color: DifyColors.textDestructive,
                  maxLines: 2,
                ),
              ),
              if (w.onRetry != null)
                DifyButton(
                  size: DifyButtonSize.small,
                  loading: w.isRetrying,
                  onPressed: w.onRetry,
                  child: Text(_c('operation.retry')),
                ),
            ],
          ),
        ),
      );
    }
    if (agent != null) {
      if (!w.canOpenPanel) return _CardBox(child: _agentContent(agent));
      return _trigger(agent);
    }
    if (w.isPending || w.agentId != null) return _CardBox(child: _loadingContent());
    return _CardBox(
      destructive: true,
      child: Row(
        spacing: 8,
        children: [
          _errorTile(),
          Expanded(
            child: DifyText(
              _w('errorMsg.fieldRequired', {'field': _w('nodes.agent.roster.label')}),
              DifyType.systemSmMedium,
              color: DifyColors.textDestructive,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPanel();
    });
    return OverlayPortal(
      controller: _drawer,
      overlayChildBuilder: (context) => Positioned(
        right: 4,
        top: 56,
        bottom: 4,
        width: w.drawerWidth,
        child: w.agent == null
            ? const SizedBox.shrink()
            : AgentRosterDrawer(
                agent: w.agent!,
                mode: w.panelMode,
                isInlineSetup: w.isInlineSetup,
                showDetailActions: w.showPanelDetailActions,
                isCopyPending: w.isPanelCopyPending,
                onMakeCopy: w.onMakeCopy,
                onSaveInlineToRoster: w.onSaveInlineToRoster,
                onOpenUrl: w.onOpenUrl,
                onClose: () => _setPanelOpen(false),
                body: w.panelBody,
              ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: [
            SizedBox(
              height: 24,
              child: Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: DifyText(
                      _w('nodes.agent.roster.label'),
                      DifyType.systemSmSemiboldUppercase,
                      color: DifyColors.textSecondary,
                    ),
                  ),
                  Flexible(
                    child: DifyFloating(
                      controller: _selector,
                      placement: DifyPlacement.bottomEnd,
                      sideOffset: 4,
                      builder: (context, c) => Opacity(
                        opacity: w.isPending ? 0.5 : 1,
                        child: DifyPressable(
                          semanticLabel: _w('nodes.agent.roster.change'),
                          disabled: w.isPending,
                          onPressed: c.toggle,
                          builder: (context, hovered, focused) => Container(
                            height: 24,
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: hovered && !w.isPending ? DifyColors.stateBaseHover : null,
                              borderRadius: BorderRadius.circular(DifyRadius.md),
                            ),
                            child: DifyText(
                              _w('nodes.agent.roster.change'),
                              DifyType.systemXsMedium,
                              color: hovered && !w.isPending ? DifyColors.textSecondary : DifyColors.textTertiary,
                            ),
                          ),
                        ),
                      ),
                      popupBuilder: (context) => Semantics(
                        container: true,
                        role: SemanticsRole.dialog,
                        label: _a('roster.nodeSelector.dialogLabel'),
                        explicitChildNodes: true,
                        child: AgentSelectorContent(
                          onClose: _selector.close,
                          onOpenUrl: w.onOpenUrl,
                          onSelect: (agent) {
                            _selector.close();
                            w.onChange(agent);
                          },
                          onStartFromScratch: w.onStartFromScratch == null
                              ? null
                              : () {
                                  _selector.close();
                                  w.onStartFromScratch!();
                                },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _body(),
          ],
        ),
      ),
    );
  }
}

/// The inline dialog's body: the host's workspace, or an empty panel (`h-full min-h-80 bg-components-panel-bg`).
class _InlineDialogBody extends StatelessWidget {
  const _InlineDialogBody({required this.builder});
  final WidgetBuilder? builder;

  @override
  Widget build(BuildContext context) =>
      builder?.call(context) ?? ColoredBox(color: DifyColors.componentsPanelBg, child: SizedBox.expand());
}

/// AgentRosterDrawer: over the node panel (`top-14 bottom-1 rounded-2xl border-[0.5px] shadow-2xl`), the header
/// (avatar, name or "Inline setup", the lock, the role or the setup description, More and close), the detail
/// actions (Edit in Agents when the agent may be configured, Make a copy) and the agent's read-only content.
/// Escape closes it.
class AgentRosterDrawer extends StatelessWidget {
  const AgentRosterDrawer({
    super.key,
    required this.agent,
    required this.onClose,
    this.mode = AgentRosterDrawerMode.detail,
    this.isInlineSetup = false,
    this.showDetailActions = true,
    this.isCopyPending = false,
    this.onMakeCopy,
    this.onSaveInlineToRoster,
    this.onOpenUrl,
    this.body,
    this.canCreateAgents = true,
  });

  final Json agent;
  final VoidCallback onClose;
  final AgentRosterDrawerMode mode;
  final bool isInlineSetup, showDetailActions, isCopyPending, canCreateAgents;
  final VoidCallback? onMakeCopy, onSaveInlineToRoster;
  final void Function(String url)? onOpenUrl;
  final WidgetBuilder? body;

  @override
  Widget build(BuildContext context) {
    final isSetup = mode == AgentRosterDrawerMode.setup;
    final title = isInlineSetup ? _w('nodes.agent.roster.inlineSetup.name') : jsKey(agent['name']);
    final description = isSetup ? _w('nodes.agent.roster.inlineSetup.description') : jsStr(agent['role']);
    final showInlineActions = isInlineSetup && onSaveInlineToRoster != null && canCreateAgents;
    final services = LlmGroupScope.of(context);
    final showActions = !isSetup && showDetailActions;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
      child: FocusScope(
        autofocus: true,
        child: DifyDrawerPopup(
          label: title,
          borderRadius: BorderRadius.circular(DifyRadius.xxl),
          border: Border.all(color: DifyColors.dividerSubtle, width: 0.5),
          boxShadow: DifyShadows.n2xl,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: isSetup
                    ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
                    : const EdgeInsets.fromLTRB(12, 12, 16, 12),
                decoration: BoxDecoration(
                  color: DifyColors.componentsPanelBg,
                  border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Row(
                            spacing: 8,
                            children: [
                              if (isInlineSetup)
                                const InlineSetupAvatar(size: 36)
                              else
                                AgentAvatar(agent: agent, size: 36),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  spacing: isSetup ? 0 : 2,
                                  children: [
                                    Row(
                                      spacing: 4,
                                      children: [
                                        Flexible(
                                          child: DifyText(
                                            title,
                                            isSetup ? DifyType.systemXlSemibold : DifyType.systemSmMedium,
                                            color: isSetup ? DifyColors.textPrimary : DifyColors.textSecondary,
                                          ),
                                        ),
                                        if (!isSetup) RemixIcon('lock-line', size: 12, color: DifyColors.textTertiary),
                                      ],
                                    ),
                                    if (description != null && description.isNotEmpty)
                                      DifyText(
                                        description,
                                        DifyType.systemXsRegular,
                                        color: DifyColors.textTertiary,
                                        maxLines: isSetup ? null : 1,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            spacing: 4,
                            children: [
                              if (showInlineActions) ...[
                                DifyDropdownMenu(
                                  placement: DifyPlacement.bottomEnd,
                                  semanticLabel: _w('nodes.agent.roster.more'),
                                  builder: (context, c) => DifyIconButton(
                                    label: _w('nodes.agent.roster.more'),
                                    icon: const RemixIcon('more-fill', size: 16),
                                    onPressed: c.toggle,
                                  ),
                                  children: [
                                    DifyMenuItem(
                                      leading: RemixIcon(
                                        'inbox-archive-line',
                                        size: 16,
                                        color: DifyColors.textTertiary,
                                      ),
                                      onSelect: onSaveInlineToRoster,
                                      child: Text(_a('roster.saveToRoster')),
                                    ),
                                  ],
                                ),
                                Container(width: 1, height: 14, color: DifyColors.dividerRegular),
                              ],
                              DifyIconButton(
                                label: _c('operation.close'),
                                icon: const RemixIcon('close-line', size: 16),
                                onPressed: onClose,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (showActions)
                      SizedBox(
                        height: 32,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Row(
                            spacing: 8,
                            children: [
                              if (canConfigureAgent(agent['permission_keys']))
                                Expanded(
                                  child: EditInConsoleLink(
                                    agentId: jsKey(agent['id']),
                                    onOpenUrl: onOpenUrl ?? (_) {},
                                  ),
                                ),
                              Expanded(
                                child: DifyButton(
                                  loading: isCopyPending,
                                  onPressed: onMakeCopy,
                                  leading: const RemixIcon('file-copy-2-line', size: 16),
                                  child: Text(_w('nodes.agent.roster.makeCopy'), overflow: TextOverflow.ellipsis),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Semantics(
                  container: true,
                  label: _w('nodes.agent.roster.panelLabel', {'name': jsKey(agent['name'])}),
                  child:
                      body?.call(context) ??
                      (services.rosterAgentContentBuilder?.call(context, jsKey(agent['id'])) ??
                          ColoredBox(color: DifyColors.componentsPanelBg, child: SizedBox.expand())),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// EditInConsoleLink: a secondary button-styled link "Edit in Agents" to the agent's configure page (new tab).
class EditInConsoleLink extends StatelessWidget {
  const EditInConsoleLink({super.key, required this.agentId, required this.onOpenUrl});
  final String agentId;
  final void Function(String url) onOpenUrl;

  /// The link's target (`getAgentDetailPath(agentId, 'configure')`).
  String get href => agentConfigurePath(agentId);

  @override
  Widget build(BuildContext context) {
    final label = _w('nodes.agent.roster.editInConsole');
    return Semantics(
      link: true,
      linkUrl: Uri.tryParse(href),
      child: DifyButton(
        semanticLabel: label,
        onPressed: () => onOpenUrl(href),
        leading: const RemixIcon('external-link-line', size: 16),
        child: Text(label, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

// ---- block-selector/agent-selector.tsx ---------------------------------------------------------------------------

/// `AGENT_SELECTOR_PAGE_SIZE`.
const agentSelectorPageSize = 8;

/// `toAgentRosterNodeData`.
Json toAgentRosterNodeData(Json agent) => {
  'description': agent['description'],
  'icon': agent['icon'],
  'icon_background': agent['icon_background'],
  'icon_type': agent['icon_type'],
  'id': agent['id'],
  'name': agent['name'],
  'role': agent['role'],
};

/// AgentSelectorContent: `w-60 rounded-xl` with the search (300 ms debounce, trimmed) over the invite options, the
/// status line, the agents (or the loading skeleton), "Start from Scratch" when given and "Manage in Agents". An
/// agent without an active config snapshot is refused with "Model not selected".
class AgentSelectorContent extends StatefulWidget {
  const AgentSelectorContent({
    super.key,
    required this.onSelect,
    required this.onClose,
    this.onStartFromScratch,
    this.onOpenUrl,
  });

  final ValueChanged<Json> onSelect;
  final VoidCallback onClose;
  final VoidCallback? onStartFromScratch;
  final void Function(String url)? onOpenUrl;

  @override
  State<AgentSelectorContent> createState() => _AgentSelectorContentState();
}

class _AgentSelectorContentState extends State<AgentSelectorContent> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _keyword = '';
  List<Json> _agents = const [];
  bool _loading = true, _error = false;
  int _generation = 0;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _load();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final gen = ++_generation;
    final fetch = LlmGroupScope.of(context).agentInviteOptions;
    if (fetch == null) {
      setState(() {
        _loading = false;
        _agents = const [];
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final agents = await fetch(_keyword);
      if (!mounted || gen != _generation) return;
      setState(() {
        _agents = agents.take(agentSelectorPageSize).toList();
        _loading = false;
        _error = false;
      });
    } on Object {
      if (!mounted || gen != _generation) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      final k = v.trim();
      if (k == _keyword) return;
      _keyword = k;
      _load();
    });
  }

  void _select(Json agent) {
    if (!jsTruthy(agent['active_config_snapshot_id'])) {
      LlmGroupScope.of(context).toast?.call(LlmToastType.error, _w('nodes.agent.modelNotSelected'));
      return;
    }
    widget.onSelect(toAgentRosterNodeData(agent));
  }

  String? get _status => _loading
      ? _c('loading')
      : _error
      ? _a('roster.loadingError')
      : _agents.isEmpty
      ? (_keyword.isNotEmpty ? _a('roster.emptySearch') : _a('roster.empty'))
      : null;

  Widget _footerButton({required String icon, required String label, required VoidCallback onPressed}) => DifyPressable(
    semanticLabel: label,
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: hovered ? DifyColors.stateBaseHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      child: Row(
        spacing: 8,
        children: [
          RemixIcon(icon, size: 16, color: DifyColors.textTertiary),
          Expanded(child: DifyText(label, DifyType.systemSmRegular, color: DifyColors.textSecondary)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Container(
      width: 240,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
        boxShadow: DifyShadows.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: DifyColors.componentsInputBgNormal,
                borderRadius: BorderRadius.circular(DifyRadius.lg),
              ),
              child: Row(
                children: [
                  Padding(
                    padding: EdgeInsets.only(right: 2),
                    child: RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
                  ),
                  Expanded(
                    child: Semantics(
                      label: _a('roster.searchLabel'),
                      textField: true,
                      child: DifySurface(
                        child: DifyTextField(
                          controller: _search,
                          autofocus: true,
                          onChanged: _onSearch,
                          style: difyStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled),
                          decoration: DifyFieldDecoration(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                            hintText: _a('roster.nodeSelector.searchPlaceholder'),
                            hintStyle: difyStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextPlaceholder),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (status != null)
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: DifyText(status, DifyType.systemXsRegular, color: DifyColors.textTertiary),
              ),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 216),
            child: _loading
                ? const _SelectorSkeleton()
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!_error)
                          for (final agent in _agents)
                            _AgentSelectorItem(agent: agent, onPressed: () => _select(agent)),
                      ],
                    ),
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.onStartFromScratch != null)
                  _footerButton(
                    icon: 'add-line',
                    label: _a('roster.nodeSelector.startFromScratch'),
                    onPressed: widget.onStartFromScratch!,
                  ),
                _footerButton(
                  icon: 'arrow-right-up-line',
                  label: _a('roster.nodeSelector.manageInAgentConsole'),
                  onPressed: () {
                    widget.onOpenUrl?.call('/agents');
                    widget.onClose();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentSelectorItem extends StatelessWidget {
  const _AgentSelectorItem({required this.agent, required this.onPressed});
  final Json agent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final role = jsStr(agent['role']);
    final secondary = role != null && role.isNotEmpty ? role : (jsStr(agent['description']) ?? '');
    return DifyPressable(
      semanticLabel: jsKey(agent['name']),
      onPressed: onPressed,
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
        decoration: BoxDecoration(
          color: hovered || focused ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Row(
          spacing: 8,
          children: [
            AgentAvatar(agent: agent),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: [
                  DifyText(jsKey(agent['name']), DifyType.systemSmMedium, color: DifyColors.textSecondary),
                  DifyText(secondary, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AgentSelectorLoadingSkeleton: four rows (round avatar and two bars) fading out.
class _SelectorSkeleton extends StatelessWidget {
  const _SelectorSkeleton();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in const [0.2, 0.2, 0.2, 0.1])
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
              child: Row(
                spacing: 8,
                children: [
                  DifySkeletonRectangle(width: 32, height: 32, radius: 16, opacity: o, margin: EdgeInsets.zero),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 6,
                    children: [_bar(80, 8, o), _bar(112, 8, o)],
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

// ---- save-inline-agent-to-roster-dialog.tsx ----------------------------------------------------------------------

/// `defaultAgentIcon`.
const defaultAgentIcon = (icon: '🧸', background: '#F5F3FF');

/// `createAgentIconSelection` (emoji and image / link icons).
Json createAgentIconSelection(Json agent) {
  final type = agent['icon_type'], icon = jsStr(agent['icon']);
  if ((type == 'image' || type == 'link') && icon != null && icon.isNotEmpty) {
    return {'type': type, 'icon': icon, 'url': agent['icon_url'] ?? icon};
  }
  return {
    'type': 'emoji',
    'icon': icon == null || icon.isEmpty ? defaultAgentIcon.icon : icon,
    'background': jsTruthy(agent['icon_background']) ? agent['icon_background'] : defaultAgentIcon.background,
  };
}

/// The saveToRoster request body (`{variant, save_strategy, new_agent_name, description, role, icon_type, icon,
/// icon_background}`).
Json saveToRosterBody({required String name, required String description, required String role, required Json icon}) =>
    {
      'variant': 'workflow',
      'save_strategy': 'save_to_roster',
      'new_agent_name': name.trim(),
      'description': description.trim(),
      'role': role.trim(),
      'icon_type': icon['type'],
      'icon': icon['type'] == 'image' ? (icon['fileId'] ?? icon['icon']) : icon['icon'],
      'icon_background': icon['type'] == 'emoji' ? icon['background'] : null,
    };

/// SaveInlineAgentToRosterDialog: "Save to Agents" (w-130) with the agent's icon, an empty name, its role and
/// description; Save hands the body to [save] (the composer's saveToRoster) and, with the new roster agent's id,
/// to [onSaved]. It cannot be closed while saving.
Future<void> showSaveInlineAgentToRosterDialog(
  BuildContext context, {
  required Json initialAgent,
  required Future<String?> Function(Json body) save,
  required ValueChanged<String> onSaved,
  UploadAppIcon? uploadIcon,
}) => showDifyDialog<void>(
  context,
  dismissible: false,
  builder: (ctx) => DifyDialogSurface(
    label: _a('roster.saveToRosterDialog.title'),
    width: 520,
    child: SaveInlineAgentToRosterForm(
      initialAgent: initialAgent,
      uploadIcon: uploadIcon,
      save: save,
      onDone: (id) {
        Navigator.of(ctx).pop();
        if (id != null) onSaved(id);
      },
    ),
  ),
);

/// Dify's dialogs with `disablePointerDismissal`: a tap outside does not close them, Escape does.
class _EscapeCloses extends StatelessWidget {
  const _EscapeCloses({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (node, e) {
      if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    },
    child: child,
  );
}

/// The dialog's form (SaveInlineAgentToRosterFormSession): its values are taken from [initialAgent] once.
class SaveInlineAgentToRosterForm extends StatefulWidget {
  const SaveInlineAgentToRosterForm({
    super.key,
    required this.initialAgent,
    required this.save,
    required this.onDone,
    this.uploadIcon,
    this.pickIconFile,
  });
  final Json initialAgent;
  final Future<String?> Function(Json body) save;
  final UploadAppIcon? uploadIcon;
  final Future<IconFile?> Function()? pickIconFile;

  /// Closes the dialog: the saved agent id, or null for Cancel.
  final void Function(String? agentId) onDone;

  @override
  State<SaveInlineAgentToRosterForm> createState() => _SaveInlineAgentToRosterFormState();
}

class _SaveInlineAgentToRosterFormState extends State<SaveInlineAgentToRosterForm> {
  late String _name = '';
  late String _role = jsStr(widget.initialAgent['role']) ?? '';
  late String _description = jsStr(widget.initialAgent['description']) ?? '';
  late Json _icon = createAgentIconSelection(widget.initialAgent);
  bool _pending = false;
  bool _nameMissing = false;

  Future<void> _changeIcon() async {
    if (_pending) return;
    final selection = await showAppIconPicker(
      context,
      initialEmoji: _icon['type'] == 'emoji'
          ? (icon: jsKey(_icon['icon']), background: jsStr(_icon['background']))
          : null,
      upload: widget.uploadIcon,
      pickFile: widget.pickIconFile,
    );
    if (mounted && selection != null) setState(() => _icon = selection);
  }

  Future<void> _submit() async {
    if (_pending) return;
    if (_name.isEmpty || _name.trim().isEmpty) {
      setState(() => _nameMissing = true);
      return;
    }
    setState(() => _pending = true);
    String? id;
    try {
      id = await widget.save(saveToRosterBody(name: _name, description: _description, role: _role, icon: _icon));
    } on Object {
      id = null;
    }
    if (!mounted) return;
    setState(() => _pending = false);
    if (id != null && id.isNotEmpty) widget.onDone(id);
  }

  Widget _label(String text, {bool optional = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      spacing: 4,
      children: [
        Flexible(child: DifyText(text, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
        if (optional)
          Flexible(child: DifyText(_c('label.optional'), DifyType.systemXsRegular, color: DifyColors.textTertiary)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final optional = _c('label.optional');
    return Focus(
      onKeyEvent: (node, e) {
        if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
        if (!_pending) widget.onDone(null);
        return KeyEventResult.handled;
      },
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 56, 12),
                child: DifyText(_a('roster.saveToRosterDialog.title'), DifyType.title2xlSemiBold),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 20,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 16,
                      children: [
                        DifyPressable(
                          semanticLabel: _a('roster.saveToRosterForm.changeIcon'),
                          onPressed: _pending ? null : _changeIcon,
                          builder: (context, hovered, focused) => ClipOval(
                            child: Container(
                              width: 64,
                              height: 64,
                              alignment: Alignment.center,
                              color: _hex(_icon['background'], DifyAgentRosterColors.defaultIconBackground),
                              child: _icon['type'] == 'emoji'
                                  ? Text(jsKey(_icon['icon']), style: difyEmojiTextStyle(32))
                                  : Image.network(jsKey(_icon['url']), width: 64, height: 64, fit: BoxFit.cover),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _label(_a('roster.createForm.nameLabel')),
                              DifyInput(
                                key: const ValueKey('roster-name'),
                                value: _name,
                                invalid: _nameMissing,
                                semanticLabel: _a('roster.createForm.nameLabel'),
                                placeholder: _a('roster.createForm.namePlaceholder'),
                                onChanged: (v) => setState(() {
                                  _name = v;
                                  _nameMissing = false;
                                }),
                                onSubmitted: (_) => _submit(),
                              ),
                              if (_nameMissing)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: DifyText(
                                    _a('roster.createForm.nameRequired'),
                                    DifyType.systemXsRegular,
                                    color: DifyColors.textDestructive,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _label(_a('roster.createForm.roleLabel'), optional: true),
                              DifyInput(
                                key: const ValueKey('roster-role'),
                                value: _role,
                                semanticLabel: '${_a('roster.createForm.roleLabel')} $optional',
                                placeholder: _a('roster.createForm.rolePlaceholder'),
                                onChanged: (v) => _role = v,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _label(_a('roster.createForm.descriptionLabel'), optional: true),
                        SizedBox(
                          height: 80,
                          child: DifyInput(
                            key: const ValueKey('roster-description'),
                            value: _description,
                            semanticLabel: '${_a('roster.createForm.descriptionLabel')} $optional',
                            placeholder: _a('roster.createForm.descriptionPlaceholder'),
                            onChanged: (v) => _description = v,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  spacing: 8,
                  children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: DifyButton(
                          disabled: _pending,
                          onPressed: () => widget.onDone(null),
                          child: Text(_c('operation.cancel')),
                        ),
                      ),
                    ),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: DifyButton(
                          variant: DifyButtonVariant.primary,
                          loading: _pending,
                          onPressed: _submit,
                          child: Text(_c('operation.save')),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            top: 20,
            right: 20,
            child: DifyIconButton(
              label: _c('operation.close'),
              size: DifyIconButtonSize.lg,
              disabled: _pending,
              icon: const RemixIcon('close-line', size: 16),
              onPressed: () => widget.onDone(null),
            ),
          ),
        ],
      ),
    );
  }
}
