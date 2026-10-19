/// The HTTP node's dialogs: Authorization (components/authorization) and Import from cURL
/// (components/curl-panel.tsx), on dify-ui's Dialog ([showDifyDialog]).
library;

import 'package:flutter/material.dart';

import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor.dart';
import '../data_common.dart';
import 'http_model.dart';

Widget _title(String text) => Text(text, style: difyStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary));

// ---- Authorization ----------------------------------------------------------------------------------------------

/// The Authorization dialog: edits a copy of [payload]; Save hands it to [onChange].
Future<void> showAuthorizationModal(
  BuildContext context, {
  required Map<String, Object?> payload,
  required ValueChanged<Map<String, Object?>> onChange,
  List<VarGroup> vars = const [],
  Map<String, WorkflowNodeInfo> nodes = const {},
}) => showDifyDialog<void>(
  context,
  builder: (context) => DifyDialogSurface(
    label: wf('nodes.http.authorization.authorization'),
    padding: const EdgeInsets.all(24),
    scrollable: true,
    child: AuthorizationModal(payload: payload, onChange: onChange, vars: vars, nodes: nodes),
  ),
);

/// The Authorization dialog's content: "Authorization Type" (None / API-Key), then for API keys "Auth Type" (Basic
/// / Bearer / Custom), the custom header and the API key (variables allowed); Cancel / Save.
class AuthorizationModal extends StatefulWidget {
  const AuthorizationModal({
    super.key,
    required this.payload,
    required this.onChange,
    this.vars = const [],
    this.nodes = const {},
  });

  final Map<String, Object?> payload;
  final ValueChanged<Map<String, Object?>> onChange;
  final List<VarGroup> vars;
  final Map<String, WorkflowNodeInfo> nodes;

  @override
  State<AuthorizationModal> createState() => _AuthorizationModalState();
}

class _AuthorizationModalState extends State<AuthorizationModal> {
  late Map<String, Object?> _temp = widget.payload;

  String _t(String key) => wf('nodes.http.authorization.$key');

  Widget _field(String title, Widget child, {bool required = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        height: 32,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              text: title,
              children: [
                if (required)
                  TextSpan(
                    text: ' *',
                    style: TextStyle(color: DifyColors.textDestructive),
                  ),
              ],
            ),
            style: difyTextStyle(DifyTw.text13Medium, DifyColors.textSecondary),
          ),
        ),
      ),
      child,
    ],
  );

  Widget _radios(List<(String, String)> options, String value, ValueChanged<String> onSelect) => Row(
    spacing: 8,
    children: [
      for (final (v, label) in options)
        Expanded(
          child: _RadioItem(title: label, selected: v == value, onTap: () => onSelect(v)),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final type = jsStr(_temp['type']) ?? 'no-auth';
    final config = _temp['config'];
    final apiType = jsStr(jsGet(config, 'type')) ?? 'basic';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(_t('authorization')),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            _field(
              _t('authorizationType'),
              _radios(
                [('no-auth', _t('no-auth')), ('api-key', _t('api-key'))],
                type,
                (v) => setState(() => _temp = authorizationWithType(_temp, v)),
              ),
            ),
            if (type == 'api-key') ...[
              _field(
                _t('auth-type'),
                _radios(
                  [('basic', _t('basic')), ('bearer', _t('bearer')), ('custom', _t('custom'))],
                  apiType,
                  (v) => setState(() => _temp = authorizationWithConfig(_temp, 'type', v)),
                ),
              ),
              if (jsGet(config, 'type') == 'custom')
                _field(
                  _t('header'),
                  required: true,
                  DifyInput(
                    value: jsStr(jsGet(config, 'header')) ?? '',
                    semanticLabel: _t('header'),
                    onChanged: (v) => setState(() => _temp = authorizationWithConfig(_temp, 'header', v)),
                  ),
                ),
              _field(
                _t('api-key-title'),
                required: true,
                VarInput(
                  value: jsStr(jsGet(config, 'api_key')) ?? '',
                  placeholder: ' ',
                  vars: widget.vars,
                  nodesMap: widget.nodes,
                  semanticLabel: _t('api-key-title'),
                  onEdit: (v) => _temp = authorizationWithConfig(_temp, 'api_key', v),
                  onChange: (v, _) => _temp = authorizationWithConfig(_temp, 'api_key', v),
                ),
              ),
            ],
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 24),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              DifyButton(onPressed: () => Navigator.of(context).pop(), child: Text(cm('operation.cancel'))),
              DifyButton(
                variant: DifyButtonVariant.primary,
                onPressed: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  widget.onChange(_temp);
                  Navigator.of(context).pop();
                },
                child: Text(cm('operation.save')),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// radio-group.tsx's Item: `flex h-8 grow rounded-md border px-2 text-left system-sm-regular text-text-secondary` in
/// the option-card colours (hover: border, background and shadow-xs); selected `border-[1.5px]` selected colours with
/// `system-sm-medium`.
class _RadioItem extends StatefulWidget {
  const _RadioItem({required this.title, required this.selected, required this.onTap});
  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_RadioItem> createState() => _RadioItemState();
}

class _RadioItemState extends State<_RadioItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final hovered = _hovered && !w.selected;
    return Semantics(
      button: true,
      selected: w.selected,
      child: MouseRegion(
        cursor: w.selected ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: w.onTap,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: w.selected
                  ? DifyColors.componentsOptionCardOptionSelectedBg
                  : hovered
                  ? DifyColors.componentsOptionCardOptionBgHover
                  : DifyColors.componentsOptionCardOptionBg,
              borderRadius: BorderRadius.circular(DifyRadius.md),
              border: Border.all(
                color: w.selected
                    ? DifyColors.componentsOptionCardOptionSelectedBorder
                    : hovered
                    ? DifyColors.componentsOptionCardOptionBorderHover
                    : DifyColors.componentsOptionCardOptionBorder,
                width: w.selected ? 1.5 : 1,
              ),
              boxShadow: w.selected || hovered ? DifyShadows.xs : null,
            ),
            child: DifyText(
              w.title,
              w.selected ? DifyType.systemSmMedium : DifyType.systemSmRegular,
              color: DifyColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

// ---- Import from cURL -------------------------------------------------------------------------------------------

/// The "Import from cURL" dialog: Save parses the pasted command; an error is toasted and the dialog stays, a node
/// closes it and goes to [onImport]. [parse] stands for the parser (tests replace it).
Future<void> showCurlPanel(
  BuildContext context, {
  required ValueChanged<Map<String, Object?>> onImport,
  ({Map<String, Object?>? node, String? error}) Function(String) parse = parseCurl,
}) {
  final toast = DataPanelHost.of(context).toast;
  return showDifyDialog<void>(
    context,
    builder: (context) => DifyDialogSurface(
      label: wf('nodes.http.curl.title'),
      width: 400,
      padding: const EdgeInsets.all(16),
      scrollable: true,
      child: CurlPanel(onImport: onImport, parse: parse, toast: toast),
    ),
  );
}

/// The cURL dialog's content: the title, a 160 px textarea ("Paste cURL string here") and Cancel / Save (95 px).
class CurlPanel extends StatefulWidget {
  const CurlPanel({super.key, required this.onImport, this.parse = parseCurl, this.toast});

  final ValueChanged<Map<String, Object?>> onImport;
  final ({Map<String, Object?>? node, String? error}) Function(String) parse;
  final DataToast? toast;

  @override
  State<CurlPanel> createState() => _CurlPanelState();
}

class _CurlPanelState extends State<CurlPanel> {
  final _text = TextEditingController();
  final _focus = FocusNode(debugLabel: 'curl');

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save() {
    final (:node, :error) = widget.parse(_text.text);
    if (error != null) {
      widget.toast?.call(DataToastType.error, error);
      return;
    }
    if (node == null) return;
    Navigator.of(context).pop();
    widget.onImport(node);
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    final style = difyStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(wf('nodes.http.curl.title')),
        Container(
          height: 160,
          margin: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: focused ? DifyColors.componentsInputBgActive : DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(color: focused ? DifyColors.componentsInputBorderActive : Colors.transparent),
            boxShadow: focused ? DifyShadows.xs : null,
          ),
          child: Semantics(
            label: wf('nodes.http.curl.title'),
            child: TextField(
              controller: _text,
              focusNode: _focus,
              maxLines: null,
              expands: true,
              style: style,
              cursorColor: DifyColors.primary600, // dify-ui Textarea: caret-primary-600
              cursorWidth: 1,
              textAlignVertical: TextAlignVertical.top,
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                hintText: wf('nodes.http.curl.placeholder'),
                hintStyle: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              SizedBox(
                width: 95,
                child: DifyButton(onPressed: () => Navigator.of(context).pop(), child: Text(cm('operation.cancel'))),
              ),
              SizedBox(
                width: 95,
                child: DifyButton(
                  variant: DifyButtonVariant.primary,
                  onPressed: _save,
                  child: Text(cm('operation.save')),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
