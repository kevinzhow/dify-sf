/// The Test Email Sender dialog (components/delivery-method/test-email-sender.tsx) with the before-run form items it
/// fills (text, number, JSON, checkbox).
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/var_types.dart';
import '../../../../code_editor/code_editor.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor.dart' show getInputVars;
import '../data_common.dart';
import 'delivery_method.dart' show EmailContext;
import 'email_config.dart';
import 'human_input_kit.dart';
import 'human_input_model.dart';

/// One variable the test sender asks for: its `#a.b#` key, input type (`text-input`, `number`, `json`, `checkbox`,
/// `file`, `file-list`), and its label (node title, variable name).
typedef SenderInput = ({String variable, String type, String nodeName, String label, List<String> selector});

/// `getOriginVar`: the variable [selector] names in [groups] (through object and file members), or null.
PickerVar? originVar(List<String> selector, List<VarGroup> groups) {
  final group = groups.where((g) => g.nodeId == selector.first).firstOrNull;
  if (group == null) return null;
  var curr = group.vars;
  for (var i = 1; i < selector.length; i++) {
    final v = curr.where((v) => v.variable.replaceFirst('conversation.', '') == selector[i]).firstOrNull;
    if (v == null) return null;
    if (i == selector.length - 1) return v;
    if ((v.type == VarType.object || v.type == VarType.file) && v.children is List) {
      curr = v.childVars;
    } else {
      return null;
    }
  }
  return null;
}

/// `varTypeToInputVarType`.
String varTypeToInputVarType(String? type) => switch (type) {
  VarType.number => 'number',
  VarType.boolean => 'checkbox',
  VarType.object || VarType.array || VarType.arrayNumber || VarType.arrayString || VarType.arrayObject => 'json',
  VarType.file => 'file',
  VarType.arrayFile => 'file-list',
  _ => 'text-input',
};

/// `generatedInputs`: the variables of the form content, the email body and the form inputs' sources (unique, not
/// env and not `$output`), typed from [EmailContext.vars] (`text-input` when unknown).
List<SenderInput> senderInputs(EmailContext email, String body) {
  final seen = <String>{};
  final selectors = [
    for (final s in [
      ...getInputVars(email.formContent + body),
      ...humanInputFormDependencySelectors(email.formInputs),
    ])
      if (seen.add(s.join('.'))) s,
  ];
  return [
    for (final s in selectors)
      if (s.first != 'env' && !isOutputSelector(s))
        (
          variable: '#${s.join('.')}#',
          type: varTypeToInputVarType(originVar(s, email.vars)?.type),
          nodeName: email.nodesMap[s.first]?.title ?? '',
          label: isSystemVar(s) ? s.join('.') : s.last,
          selector: s,
        ),
  ];
}

/// `formatValue` of the before-run form (throws [FormatException] for invalid JSON).
Object? formatSenderValue(Object? value, String type) {
  if (type == 'checkbox') return jsTruthy(value);
  if (value == null) return null;
  if (type == 'number') return num.tryParse('$value') ?? double.nan;
  if (type == 'json') return jsonDecode('$value');
  return value;
}

/// Shows the Test Email Sender for delivery [deliveryId]; true when the user follows the tip's link to the email
/// configuration.
Future<bool> showTestEmailSender(
  BuildContext context, {
  required String deliveryId,
  required Map<String, Object?>? config,
  required EmailContext email,
}) async {
  final toast = DataPanelHost.of(context).toast;
  final host = HumanInputHost.of(context);
  final r = await showDifyDialog<bool>(
    context,
    dismissible: false,
    builder: (context) => DataPanelHost(
      toast: toast,
      child: HumanInputHost(
        members: host.members,
        userEmail: host.userEmail,
        workspaceName: host.workspaceName,
        sendTestEmail: host.sendTestEmail,
        child: TestEmailSender(deliveryId: deliveryId, config: config, email: email),
      ),
    ),
  );
  return r ?? false;
}

/// EmailSenderContent: who the test goes to (debug mode: the account email; the workspace; the listed addresses
/// with the "enable Debug Mode" tip), the form's variables to fill in (collapsible), Send Email (enabled once all
/// are filled) and Cancel; after sending, the Email Sent view with OK.
class TestEmailSender extends StatefulWidget {
  const TestEmailSender({super.key, required this.deliveryId, required this.config, required this.email});
  final String deliveryId;
  final Map<String, Object?>? config;
  final EmailContext email;

  @override
  State<TestEmailSender> createState() => _TestEmailSenderState();
}

class _TestEmailSenderState extends State<TestEmailSender> {
  late final List<SenderInput> _vars = senderInputs(widget.email, jsStr(widget.config?['body']) ?? '');
  final _values = <String, Object?>{};
  late bool _collapsed = _vars.isEmpty;
  bool _sending = false, _done = false;

  String _t(String key, [Map<String, Object?> p = const {}]) => hi('deliveryMethod.emailSender.$key', p);

  bool get _filled => _vars.every((v) {
    final x = _values[v.variable];
    return x != null && x != '';
  });

  Future<void> _send() async {
    if (!_filled) return;
    final formatted = <String, Object?>{};
    String? badField;
    for (final v in _vars) {
      try {
        formatted[v.variable] = formatSenderValue(_values[v.variable], v.type);
      } on FormatException {
        badField = v.label;
      }
    }
    if (badField != null) {
      showDataToast(context, DataToastType.error, wf('errorMsg.invalidJson', {'field': badField}));
      return;
    }
    final send = HumanInputHost.of(context).sendTestEmail;
    if (send == null) return;
    setState(() => _sending = true);
    try {
      await send(nodeId: widget.email.nodeId, deliveryId: widget.deliveryId, inputs: formatted);
      if (mounted) setState(() => _done = true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  TextSpan _rich(String text, Map<String, Object?> params, DifyTextStyle strong, String tag) => TextSpan(
    children: transSpans(text, {
      tag: (inner) => TextSpan(text: inner, style: difyStyle(strong, DifyColors.textPrimary)),
    }),
  );

  @override
  Widget build(BuildContext context) {
    final host = HumanInputHost.of(context);
    final config = widget.config;
    final recipients = recipientsOf(config);
    final items = jsList(recipients['items']);
    final whole = jsTruthy(recipients['whole_workspace']);
    final debug = jsTruthy(config?['debug_mode']);
    final onlyWholeTeam = whole && items.isEmpty, onlySpecific = !whole && items.isNotEmpty;
    final combined = whole && items.isNotEmpty;
    final team = host.workspaceName.replaceAll("'", '’');
    final body = difyStyle(_done ? DifyType.systemMdRegular : DifyType.systemSmRegular, DifyColors.textSecondary);
    final strong = _done ? DifyType.systemMdSemibold : DifyType.systemSmSemibold;
    String? summaryKey(bool done) {
      if (debug) return done ? 'debugDone' : 'debugModeTip2';
      if (onlyWholeTeam) return done ? 'wholeTeamDone2' : 'wholeTeamTip2';
      if (onlySpecific) return done ? 'wholeTeamDone3' : 'wholeTeamTip3';
      if (combined) return done ? 'wholeTeamDone1' : 'wholeTeamTip1';
      return null;
    }

    final key = summaryKey(_done);
    final list = (onlySpecific || combined) && !debug
        ? Padding(
            padding: const EdgeInsets.only(top: 16),
            child: EmailInput(
              disabled: true,
              email: host.userEmail,
              value: items,
              list: host.members,
              onDelete: (_) {},
              onSelect: (_) {},
              onAdd: (_) {},
            ),
          )
        : null;
    final summary = key == null
        ? null
        : Text.rich(
            _rich(
              _t(key, {'email': host.userEmail, 'team': team}),
              const {},
              strong,
              key.startsWith('debug') ? 'email' : 'team',
            ),
            style: body,
          );
    if (_done) {
      return DifyDialogSurface(
        padding: const EdgeInsets.all(24),
        scrollable: true,
        label: _t('done'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            DifyText(_t('done'), DifyType.title2xlSemiBold, maxLines: null),
            const SizedBox(height: 8),
            ?summary,
            ?list,
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 72,
                child: DifyButton(
                  variant: DifyButtonVariant.primary,
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(cm('operation.ok')),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return DifyDialogSurface(
      padding: const EdgeInsets.all(24),
      scrollable: true,
      label: _t('title'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    DifyText(_t('title'), DifyType.title2xlSemiBold, maxLines: null),
                    if (debug) Text(_t('debugModeTip'), style: body),
                    ?summary,
                  ],
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: DifyIconButton(
                  label: cm('operation.close'),
                  size: DifyIconButtonSize.lg,
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: const RemixIcon('close-line', size: 16),
                ),
              ),
            ],
          ),
          if (list != null) ...[
            list,
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text.rich(
                TextSpan(
                  children: transSpans(_t('tip'), {
                    'strong': (inner) => WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: DifyPressable(
                        semanticLabel: inner,
                        onPressed: () => Navigator.of(context).pop(true),
                        builder: (context, _, _) => Text(
                          inner,
                          style: difyStyle(DifyType.systemXsRegular, DifyColors.textAccent),
                        ),
                      ),
                    ),
                  }),
                ),
                style: difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
              ),
            ),
          ],
          if (_vars.isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 48,
                height: 1,
                margin: const EdgeInsets.only(top: 16, bottom: 8),
                color: DifyColors.dividerRegular,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DifyPressable(
                    semanticLabel: _t('vars'),
                    onPressed: () => setState(() => _collapsed = !_collapsed),
                    builder: (context, hovered, _) => SizedBox(
                      height: 24,
                      child: Row(
                        children: [
                          Flexible(
                            child: DifyText(
                              _t('vars'),
                              DifyType.systemSmSemiboldUppercase,
                              color: DifyColors.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          AnimatedRotation(
                            turns: _collapsed ? 0 : 0.25,
                            duration: difyTransitionDuration,
                            child: RemixIcon(
                              'arrow-right-s-fill',
                              size: 16,
                              color: hovered ? DifyColors.textPrimary : DifyColors.textQuaternary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  DifyText(_t('varsTip'), DifyType.systemXsRegular, color: DifyColors.textTertiary, maxLines: null),
                  if (!_collapsed)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 16,
                        children: [
                          for (final (i, v) in _vars.indexed)
                            SenderFormItem(
                              input: v,
                              autofocus: i == 0,
                              value: _values[v.variable],
                              onChange: (x) => setState(() => _values[v.variable] = x),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          HiFooter(
            children: [
              SizedBox(
                width: 72,
                child: DifyButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(cm('operation.cancel')),
                ),
              ),
              DifyButton(
                variant: DifyButtonVariant.primary,
                disabled: !_filled || host.sendTestEmail == null,
                loading: _sending,
                onPressed: _send,
                child: Text(_t('send')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The before-run FormItem for one sender variable: its label (node, variable) over a text or number input, a JSON
/// editor or a checkbox; files can't be picked here (dify-sf has no uploader), so they show a note.
class SenderFormItem extends StatelessWidget {
  const SenderFormItem({
    super.key,
    required this.input,
    required this.value,
    required this.onChange,
    this.autofocus = false,
  });
  final SenderInput input;
  final Object? value;
  final ValueChanged<Object?> onChange;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final label = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        spacing: 4,
        children: [
          if (input.nodeName.isNotEmpty)
            Flexible(child: DifyText(input.nodeName, DifyType.systemSmSemibold, color: DifyColors.textSecondary)),
          if (input.nodeName.isNotEmpty)
            const DifyText('/', DifyType.systemSmRegular, color: DifyColors.textQuaternary),
          Flexible(child: DifyText(input.label, DifyType.systemSmSemibold, color: DifyColors.textAccent)),
        ],
      ),
    );
    final Widget field = switch (input.type) {
      'json' => DifyCodeEditor(
        value: value is String ? value as String : '',
        language: CodeLanguage.json,
        titleWidget: const Text('JSON'),
        onChange: onChange,
      ),
      'checkbox' => Align(
        alignment: Alignment.centerLeft,
        child: DifySwitch(checked: jsTruthy(value), semanticLabel: input.label, onCheckedChange: onChange),
      ),
      'file' || 'file-list' => DifyText(input.type, DifyType.systemXsRegular, color: DifyColors.textTertiary),
      _ => DifyInput(
        value: value is String ? value as String : '',
        placeholder: input.label,
        semanticLabel: input.label,
        keyboardType: input.type == 'number' ? TextInputType.number : null,
        onChanged: onChange,
      ),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [label, field]);
  }
}
