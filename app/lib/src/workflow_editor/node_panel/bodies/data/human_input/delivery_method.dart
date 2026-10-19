/// The Delivery Method section (components/delivery-method/index.tsx, method-selector.tsx, method-item.tsx,
/// upgrade-modal.tsx).
library;

import 'dart:math';

import 'package:flutter/material.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/css_metrics.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor.dart';
import '../data_common.dart';
import 'email_config.dart';
import 'human_input_kit.dart';
import 'human_input_model.dart';
import 'test_email_sender.dart';

typedef MethodList = List<Map<String, Object?>>;

/// A uuid4 (`uuid.v4`).
String uuid4() {
  final r = Random.secure();
  final b = [for (var i = 0; i < 16; i++) r.nextInt(256)];
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// What the email parts need around them: the variables (string / number / secret / array[string]) and their nodes,
/// the node's form content and inputs (for the test sender's variables).
@immutable
class EmailContext {
  const EmailContext({
    required this.nodeId,
    this.vars = const [],
    this.nodesMap = const {},
    this.formContent = '',
    this.formInputs = const [],
  });
  final String nodeId;
  final List<VarGroup> vars;
  final Map<String, WorkflowNodeInfo> nodesMap;
  final String formContent;
  final List<Object?> formInputs;
}

/// DeliveryMethodForm: the "Delivery Method" header (Infotip, the add selector unless [readonly]), the empty tip or
/// one [MethodItem] per method. A changed method replaces the one of its type; a deleted one removes its type.
/// [isTriggerMode]: the workflow starts from a trigger (no Webapp delivery).
class DeliveryMethodForm extends StatelessWidget {
  const DeliveryMethodForm({
    super.key,
    required this.value,
    required this.onChange,
    required this.email,
    this.readonly = false,
    this.isTriggerMode = false,
    this.newId = uuid4,
  });

  final MethodList value;
  final ValueChanged<MethodList> onChange;
  final EmailContext email;
  final bool readonly, isTriggerMode;
  final String Function() newId;

  void _change(Map<String, Object?> target) =>
      onChange([for (final m in value) m['type'] == target['type'] ? target : m]);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HiSectionHeader(
          title: hi('deliveryMethod.title'),
          tooltip: hi('deliveryMethod.tooltip'),
          actions: readonly
              ? null
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: MethodSelector(
                    data: value,
                    isTriggerMode: isTriggerMode,
                    newId: newId,
                    onAdd: (m) => onChange([...value, m]),
                    onShowUpgradeTip: () => showUpgradeModal(context),
                  ),
                ),
        ),
        if (value.isEmpty)
          HiEmptyTip(hi('deliveryMethod.emptyTip'))
        else
          Column(
            spacing: 4,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final m in value)
                MethodItem(
                  key: ValueKey(m['id']),
                  method: m,
                  email: email,
                  readonly: readonly,
                  onChange: _change,
                  onDelete: (type) => onChange([
                    for (final x in value)
                      if (x['type'] != type) x,
                  ]),
                ),
            ],
          ),
      ],
    ),
  );
}

/// MethodSelector: the `+` (named "Delivery Method") opening the methods list (`w-90`, bottom-end): Webapp (not
/// twice, not in trigger workflows), Email (not twice; without the feature it opens the upgrade tip; nothing while
/// the flag loads), and Slack / Teams / Discord as COMING SOON; on Dify Cloud the contact card below.
class MethodSelector extends StatefulWidget {
  const MethodSelector({
    super.key,
    required this.data,
    required this.onAdd,
    required this.onShowUpgradeTip,
    this.isTriggerMode = false,
    this.newId = uuid4,
  });

  final MethodList data;
  final ValueChanged<Map<String, Object?>> onAdd;
  final VoidCallback onShowUpgradeTip;
  final bool isTriggerMode;
  final String Function() newId;

  @override
  State<MethodSelector> createState() => _MethodSelectorState();
}

class _MethodSelectorState extends State<MethodSelector> {
  final _popup = DifyFloatingController();

  bool _has(String type) => widget.data.any((m) => m['type'] == type);

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final enabled = HumanInputHost.of(context).emailDeliveryEnabled;
    final webappAdded = _has(DeliveryMethodType.webapp), emailAdded = _has(DeliveryMethodType.email);
    final webappDisabled = w.isTriggerMode || webappAdded;
    final isCloud = DataPanelHost.of(context).isCloud;
    return DifyFloating(
      controller: _popup,
      placement: DifyPlacement.bottomEnd,
      sideOffset: 4,
      builder: (context, c) => DifyIconButton(
        label: hi('deliveryMethod.title'),
        onPressed: c.toggle,
        icon: const RemixIcon('add-line', size: 16),
      ),
      popupBuilder: (context) => SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Card(
              padding: const EdgeInsets.all(4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MethodOption(
                    type: DeliveryMethodType.webapp,
                    tile: methodTile(DeliveryMethodType.webapp, iconSize: 16, padding: 4, dim: webappDisabled)!,
                    dim: webappDisabled,
                    disabled: webappDisabled,
                    note: webappAdded
                        ? hi('deliveryMethod.added')
                        : w.isTriggerMode
                        ? hi('deliveryMethod.notAvailableInTriggerMode')
                        : null,
                    onTap: () => w.onAdd({'id': w.newId(), 'type': DeliveryMethodType.webapp, 'enabled': true}),
                  ),
                  _MethodOption(
                    type: DeliveryMethodType.email,
                    tile: methodTile(DeliveryMethodType.email, iconSize: 16, padding: 4, dim: emailAdded)!,
                    dim: emailAdded,
                    disabled: emailAdded || enabled == null,
                    note: emailAdded ? hi('deliveryMethod.added') : null,
                    onTap: () {
                      if (enabled == null) return;
                      if (enabled == false) {
                        _popup.close();
                        w.onShowUpgradeTip();
                        return;
                      }
                      if (emailAdded) return;
                      w.onAdd({'id': w.newId(), 'type': DeliveryMethodType.email, 'enabled': false});
                    },
                    // The upgrade tip opens from a disabled-looking row too.
                    tapWhenDisabled: enabled == false,
                  ),
                  for (final (type, icon) in const [
                    ('slack', DifyIcon('public/other/slack', size: 16)),
                    ('teams', DifyIcon('public/other/teams', size: 16)),
                  ])
                    _MethodOption(
                      type: type,
                      tile: Opacity(
                        opacity: 0.5,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: DifyColors.backgroundDefaultDodge,
                            border: Border.all(color: DifyColors.dividerRegular),
                            borderRadius: BorderRadius.circular(DifyRadius.sm),
                          ),
                          child: icon,
                        ),
                      ),
                      dim: true,
                      disabled: true,
                      comingSoon: true,
                    ),
                  _MethodOption(
                    type: DeliveryMethodType.discord,
                    tile: Opacity(
                      opacity: 0.5,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: DifyColors.componentsIconBgIndigoSolid,
                          border: Border.all(color: DifyColors.dividerRegular),
                          borderRadius: BorderRadius.circular(DifyRadius.sm),
                        ),
                        child: RemixIcon('discord-fill', size: 20, color: DifyColors.textPrimaryOnSurface),
                      ),
                    ),
                    dim: true,
                    disabled: true,
                    comingSoon: true,
                  ),
                ],
              ),
            ),
            if (isCloud) ...[
              const SizedBox(height: 4),
              _Card(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  spacing: 8,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: DifyColors.componentsIconBgMidnightSolid,
                        border: Border.all(color: DifyColors.dividerRegular),
                        borderRadius: BorderRadius.circular(DifyRadius.sm),
                      ),
                      child: RemixIcon('lightbulb-flash-fill', size: 16, color: DifyColors.textPrimaryOnSurface),
                    ),
                    Expanded(
                      child: DefaultTextStyle.merge(
                        style: difyStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(hi('deliveryMethod.contactTip1')),
                            Text.rich(
                              TextSpan(
                                children: transSpans(hi('deliveryMethod.contactTip2'), {
                                  'email': (inner) => TextSpan(
                                    text: inner.isEmpty ? 'support@dify.ai' : inner,
                                    style: TextStyle(color: DifyColors.textAccentLightModeOnly),
                                  ),
                                }),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// `rounded-xl border-[0.5px] border-components-panel-border bg-components-panel-bg-blur shadow-lg`.
class _Card extends StatelessWidget {
  const _Card({required this.child, required this.padding});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: DifyColors.componentsPanelBgBlur,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
      border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
      boxShadow: DifyShadows.lg,
    ),
    child: child,
  );
}

class _MethodOption extends StatelessWidget {
  const _MethodOption({
    required this.type,
    required this.tile,
    this.dim = false,
    this.disabled = false,
    this.note,
    this.comingSoon = false,
    this.onTap,
    this.tapWhenDisabled = false,
  });

  final String type;
  final Widget tile;
  final bool dim, disabled, comingSoon, tapWhenDisabled;
  final String? note;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = !disabled || tapWhenDisabled;
    return DifyPressable(
      onPressed: onTap,
      disabled: !active,
      builder: (context, hovered, _) => Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: BoxDecoration(
          color: hovered && !disabled ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Stack(
          children: [
            Row(
              spacing: 4,
              children: [
                tile,
                Expanded(
                  child: Opacity(
                    opacity: dim ? 0.5 : 1,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DifyText(
                            hi('deliveryMethod.types.$type.title'),
                            DifyType.systemSmMedium,
                            color: DifyColors.textPrimary,
                          ),
                          const SizedBox(height: 2),
                          DifyText(
                            hi('deliveryMethod.types.$type.description'),
                            DifyType.systemXsRegular,
                            color: DifyColors.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (note != null)
              Positioned(
                top: 9,
                right: 8,
                child: DifyText(note!, DifyType.systemXsRegular, color: DifyColors.textTertiary),
              ),
            if (comingSoon) const Positioned(top: 4, right: 4, child: HiBadge('COMING SOON', height: 16)),
          ],
        ),
      ),
    );
  }
}

/// MethodItem: a 32 px row (icon tile, the type capitalised, `DEBUG` for an email in debug mode); on hover (unless
/// [readonly]) the email's "Send test" and "Configure" buttons and Remove (the row turns destructive while Remove is
/// hovered); the enable Switch when there is a config or for Webapp, else "Not configured" with a warning dot.
class MethodItem extends StatefulWidget {
  const MethodItem({
    super.key,
    required this.method,
    required this.onChange,
    required this.onDelete,
    required this.email,
    this.readonly = false,
  });

  final Map<String, Object?> method;
  final ValueChanged<Map<String, Object?>> onChange;
  final ValueChanged<String> onDelete;
  final EmailContext email;
  final bool readonly;

  @override
  State<MethodItem> createState() => _MethodItemState();
}

class _MethodItemState extends State<MethodItem> {
  bool _hovered = false, _deleteHovered = false;

  Map<String, Object?>? get _config => switch (widget.method['config']) {
    final Map<String, Object?> m => m,
    _ => null,
  };

  Future<void> _configure() async {
    final w = widget;
    final config = await showEmailConfigureModal(context, config: _config, email: w.email);
    if (config != null) w.onChange({...w.method, 'config': config});
  }

  Future<void> _test() async {
    final w = widget;
    final jump = await showTestEmailSender(
      context,
      deliveryId: '${w.method['id']}',
      config: _config,
      email: w.email,
    );
    if (jump && mounted) await _configure();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final type = '${w.method['type']}';
    final config = _config;
    final isEmail = type == DeliveryMethodType.email;
    final debug = isEmail && jsTruthy(config?['debug_mode']);
    final userEmail = HumanInputHost.of(context).userEmail;
    final testTip = !isEmail
        ? ''
        : debug
        ? hi('deliveryMethod.emailSender.testSendTipInDebugMode', {'email': userEmail})
        : hi('deliveryMethod.emailSender.testSendTip');
    Widget action(String label, String icon, VoidCallback onPressed, {bool destructive = false}) => DifyTooltip(
      content: Text(label),
      child: MouseRegion(
        onEnter: destructive ? (_) => setState(() => _deleteHovered = true) : null,
        onExit: destructive ? (_) => setState(() => _deleteHovered = false) : null,
        child: DifyIconButton(
          label: label,
          tone: destructive ? DifyButtonTone.destructive : DifyButtonTone.normal,
          onPressed: onPressed,
          icon: RemixIcon(icon, size: 16),
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _deleteHovered = false;
      }),
      child: Container(
        key: ValueKey('method-row-$type'),
        height: 32,
        padding: const EdgeInsets.only(left: 6, right: 8),
        decoration: BoxDecoration(
          color: _deleteHovered
              ? DifyColors.stateDestructiveHover
              : _hovered
              ? DifyColors.componentsPanelOnPanelItemBgHover
              : DifyColors.componentsPanelOnPanelItemBg,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(
            color: _deleteHovered ? DifyColors.stateDestructiveBorder : DifyColors.componentsPanelBorderSubtle,
            width: Css.hairline,
          ),
          boxShadow: _hovered ? DifyShadows.sm : DifyShadows.xs,
        ),
        child: JustifyBetween(
          lead: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              ?methodTile(type),
              Flexible(
                child: DifyText(cssCapitalize(type), DifyType.systemXsMedium, color: DifyColors.textSecondary),
              ),
              if (debug) const HiBadge('DEBUG', height: 18),
            ],
          ),
          trail: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                if (!w.readonly && _hovered) ...[
                  if (isEmail && config != null) ...[
                    action(testTip, 'send-plane-2-line', _test),
                    action(wf('common.configure'), 'equalizer-2-line', _configure),
                  ],
                  action(cm('operation.remove'), 'delete-bin-line', () => w.onDelete(type), destructive: true),
                ],
                if (config != null || type == DeliveryMethodType.webapp)
                  DifySwitch(
                    checked: jsTruthy(w.method['enabled']),
                    disabled: w.readonly,
                    onCheckedChange: (v) => w.onChange({...w.method, 'enabled': v}),
                  ),
                if (isEmail && config == null)
                  Transform.translate(
                    offset: const Offset(4, 0),
                    child: DifyButton(
                      size: DifyButtonSize.small,
                      disabled: w.readonly,
                      onPressed: _configure,
                      trailing: const HiStatusDot(),
                      child: Text(hi('deliveryMethod.notConfigured')),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// upgrade-modal.tsx: "Unlock Email delivery for Human Input", its description, Dismiss, and on Dify Cloud the
/// upgrade button ([HumanInputHost.onUpgrade]).
Future<void> showUpgradeModal(BuildContext context) {
  final host = HumanInputHost.of(context), isCloud = DataPanelHost.of(context).isCloud;
  return showDifyDialog<void>(
    context,
    builder: (context) => DifyDialogSurface(
      padding: const EdgeInsets.all(24),
      scrollable: true,
      width: 580,
      label: hi('deliveryMethod.upgradeTip'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: DifyColors.componentsIconBgBlueSolid,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: RemixIcon('mail-send-fill', size: 24, color: DifyColors.textPrimaryOnSurface),
          ),
          const SizedBox(height: 16),
          DifyText(hi('deliveryMethod.upgradeTip'), DifyType.title2xlSemiBold, maxLines: null),
          const SizedBox(height: 8),
          Text(
            hi('deliveryMethod.upgradeTipContent'),
            style: difyStyle(DifyType.systemMdRegular, DifyColors.textTertiary),
          ),
          const SizedBox(height: 24),
          HiFooter(
            children: [
              SizedBox(
                width: 72,
                child: DifyButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(hi('deliveryMethod.upgradeTipHide')),
                ),
              ),
              if (isCloud)
                DifyButton(
                  variant: DifyButtonVariant.primary,
                  onPressed: host.onUpgrade,
                  child: Text(DifyI18n.tr('billing', 'upgradeBtn.encourageShort')),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
