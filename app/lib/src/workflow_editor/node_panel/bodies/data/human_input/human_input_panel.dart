/// The Human Input node's panel (nodes/human-input/panel.tsx with hooks/use-config.ts and use-form-content.ts):
/// delivery methods, the form content with its input fields, user actions, timeout and the output variables.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/var_types.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import '../data_common.dart';
import 'delivery_method.dart';
import 'form_content.dart';
import 'form_preview.dart';
import 'human_input_config.dart';
import 'human_input_kit.dart';
import 'human_input_model.dart';
import 'user_action.dart';
import '../../../panel_edit.dart';

export 'human_input_config.dart' show HumanInputConfig;
export 'human_input_kit.dart' show HiMember, HumanInputHost, SendTestEmail;

/// The Human Input panel body.
Widget humanInputPanelBody(BuildContext context, NodePanelProps props) => HumanInputPanel(props: props);

class HumanInputPanel extends StatefulWidget {
  const HumanInputPanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<HumanInputPanel> createState() => _HumanInputPanelState();
}

class _HumanInputPanelState extends State<HumanInputPanel> {
  final _preview = OverlayPortalController();
  final _expanded = OverlayPortalController();
  bool _isPreview = false, _isExpand = false, _outputCollapsed = true;

  NodePanelProps get props => widget.props;

  List<Map<String, Object?>> _maps(Object? x) => [
    for (final e in jsList(x))
      if (e is Map<String, Object?>) e,
  ];

  HumanInputConfig get _config => HumanInputConfig(props);

  String _nodeName(String id) {
    final n = props.controller.doc.nodes[id];
    return n == null || n.title.isEmpty ? id : n.title;
  }

  Widget _formContentSection(BuildContext context, {required bool expanded}) {
    final data = props.data;
    final readOnly = props.readOnly;
    final scope = NodeVars.of(props).filtered(
      typeIn(const {VarType.string, VarType.number, VarType.secret, VarType.arrayString}),
    );
    final formInputs = jsList(data['inputs']);
    Widget headerButton({
      required String label,
      required String icon,
      required bool active,
      required VoidCallback onTap,
    }) => DifyPressable(
      semanticLabel: label,
      onPressed: onTap,
      builder: (context, hovered, _) => Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active
              ? DifyColors.stateAccentActive
              : hovered
              ? DifyColors.componentsButtonGhostBgHover
              : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: RemixIcon(icon, size: 16, color: active ? DifyColors.textAccent : DifyColors.textSecondary),
      ),
    );
    final content = FormContent(
      nodeId: props.id,
      value: jsStr(data['form_content']) ?? '',
      formInputs: formInputs,
      scope: scope,
      nodesMap: NodeVars.of(props).nodesMap,
      isExpand: expanded,
      readonly: readOnly,
      version: versionOf(props),
      actions: FormContentActions(
        onChange: (v, base) => _config.formContentChange(v, base: base),
        onInsert: _config.formInputInsert,
        onInputChange: _config.formInputsChange,
        onRename: (payload, oldName) => _config.formInputRename(payload, oldName),
        onRemove: _config.formInputRemove,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
        children: [
          HiSectionHeader(
            title: hi('formContent.title'),
            tooltip: hi('formContent.tooltip'),
            actions: readOnly
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DifyButton(
                        variant: DifyButtonVariant.ghost,
                        size: DifyButtonSize.small,
                        semanticLabel: hi('formContent.preview'),
                        onPressed: () => setState(() {
                          _isPreview = !_isPreview;
                          _isPreview ? _preview.show() : _preview.hide();
                        }),
                        leading: RemixIcon(
                          'eye-line',
                          size: 14,
                          color: _isPreview ? DifyColors.textAccent : null,
                        ),
                        child: Text(
                          hi('formContent.preview'),
                          style: _isPreview ? TextStyle(color: DifyColors.textAccent) : null,
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 12,
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        color: DifyColors.dividerRegular,
                      ),
                      headerButton(
                        label: cm('operation.copy'),
                        icon: 'clipboard-line',
                        active: false,
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: jsStr(props.data['form_content']) ?? ''));
                          showDataToast(context, DataToastType.success, cm('actionMsg.copySuccessfully'));
                        },
                      ),
                      const SizedBox(width: 4),
                      headerButton(
                        label: DifyI18n.tr('share', _isExpand ? 'chat.collapse' : 'chat.expand'),
                        icon: _isExpand ? 'collapse-diagonal-line' : 'expand-diagonal-line',
                        active: _isExpand,
                        onTap: () => setState(() {
                          _isExpand = !_isExpand;
                          _isExpand ? _expanded.show() : _expanded.hide();
                        }),
                      ),
                    ],
                  ),
          ),
          if (expanded) Expanded(child: content) else content,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = props.data;
    final readOnly = props.readOnly;
    final store = props.actions.store;
    final doc = props.controller.doc;
    final actions = _maps(data['user_actions']);
    final formInputs = jsList(data['inputs']);
    final emailCtx = EmailContext(
      nodeId: props.id,
      vars: NodeVars.of(props)
          .filtered(
            typeIn(const {VarType.string, VarType.number, VarType.secret, VarType.arrayString}),
          )
          .vars,
      nodesMap: NodeVars.of(props).nodesMap,
      formContent: jsStr(data['form_content']) ?? '',
      formInputs: formInputs,
    );
    final preview = OverlayPortal(
      controller: _preview,
      overlayChildBuilder: (context) => ValueListenableBuilder(
        valueListenable: store.panelWidth,
        builder: (context, width, _) => Positioned(
          top: 112,
          right: width + 8,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height - 116),
            child: Material(
              type: MaterialType.transparency,
              child: FormContentPreview(
                content: jsStr(props.data['form_content']) ?? '',
                formInputs: jsList(props.data['inputs']),
                userActions: jsList(props.data['user_actions']),
                nodeName: _nodeName,
                onClose: () => setState(() {
                  _isPreview = false;
                  _preview.hide();
                }),
              ),
            ),
          ),
        ),
      ),
      child: const SizedBox.shrink(),
    );
    final formContent = OverlayPortal(
      controller: _expanded,
      overlayChildBuilder: (context) => ValueListenableBuilder(
        valueListenable: store.nodePanelWidth,
        builder: (context, width, _) => Positioned(
          top: 244,
          right: 4,
          bottom: 8,
          width: width,
          child: Material(
            color: DifyColors.componentsPanelBg,
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
            child: _formContentSection(context, expanded: true),
          ),
        ),
      ),
      child: _isExpand ? const SizedBox.shrink() : _formContentSection(context, expanded: false),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DeliveryMethodForm(
            value: _maps(data['delivery_methods']),
            readonly: readOnly,
            isTriggerMode: isTriggerWorkflow([for (final n in doc.nodes.values) n.type]),
            email: emailCtx,
            onChange: _config.deliveryMethodChange,
          ),
          const HiDivider(),
          formContent,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                HiSectionHeader(
                  title: hi('userActions.title'),
                  tooltip: hi('userActions.tooltip'),
                  actions: readOnly
                      ? null
                      : HiAddButton(onPressed: () => _config.userActionAdd(newUserAction(actions.length))),
                ),
                if (actions.isEmpty)
                  HiEmptyTip(hi('userActions.emptyTip'))
                else
                  Column(
                    spacing: 8,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, a) in actions.indexed)
                        UserActionItem(
                          key: ValueKey('action-$i'),
                          data: a,
                          readonly: readOnly,
                          version: versionOf(props),
                          onChange: (next, base) => _config.userActionChange(i, next, base: base),
                          onDelete: _config.userActionDelete,
                        ),
                    ],
                  ),
              ],
            ),
          ),
          const HiDivider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: JustifyBetween(
              lead: DifyText(hi('timeout.title'), DifyType.systemSmSemiboldUppercase, color: DifyColors.textSecondary),
              trail: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: TimeoutInput(
                  timeout: data['timeout'] is num ? data['timeout']! as num : 3,
                  unit: jsStr(data['timeout_unit']) ?? 'day',
                  readonly: readOnly,
                  onChange: _config.timeoutChange,
                ),
              ),
            ),
          ),
          const PanelSplit(),
          OutputVars(
            collapsed: _outputCollapsed,
            onCollapse: (v) => setState(() => _outputCollapsed = v),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final input in formInputs)
                  VarItem(name: inputNameOf(input), type: formInputVarType(input), description: 'Form input value'),
                const VarItem(name: '__action_id', type: 'string', description: 'Action ID user triggered'),
                const VarItem(name: '__action_value', type: 'string', description: 'Selected action value'),
                const VarItem(name: '__rendered_content', type: 'string', description: 'Rendered content'),
              ],
            ),
          ),
          if (!readOnly) preview,
        ],
      ),
    );
  }
}
