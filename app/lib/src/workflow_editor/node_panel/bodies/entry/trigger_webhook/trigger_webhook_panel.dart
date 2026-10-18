/// The Webhook Trigger's panel body (nodes/trigger-webhook/panel.tsx, utils/render-output-vars.tsx): the webhook
/// URL with its method and debug URL, the content type, the query / header / body parameter tables, the response,
/// and the output variables.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../header/header_data.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../node_panel_bodies.dart';
import '../../../panel_edit.dart';
import 'webhook_config.dart';
import 'webhook_default.dart';
import 'webhook_tables.dart';

String _tw(String key) => DifyI18n.tr('workflow', key);

/// What the webhook panel needs from the host: `fetchWebhookUrl` (GET `apps/{appId}/workflows/triggers/webhook`;
/// null when there is no app, then no URL is generated), the clipboard and the toasts (by default the system
/// clipboard and the header's toast).
class WebhookTriggerHost extends InheritedWidget {
  const WebhookTriggerHost({super.key, this.fetchWebhookUrl, this.copy, this.toast, required super.child});

  final Future<({String url, String? debugUrl})> Function(String nodeId)? fetchWebhookUrl;
  final void Function(String text)? copy;
  final HeaderToast? toast;

  static WebhookTriggerHost? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WebhookTriggerHost>();

  @override
  bool updateShouldNotify(WebhookTriggerHost old) =>
      fetchWebhookUrl != old.fetchWebhookUrl || copy != old.copy || toast != old.toast;
}

/// The trigger-webhook entry of the node panel bodies.
Widget triggerWebhookPanelBody(BuildContext context, NodePanelProps props) => TriggerWebhookPanel(props: props);

/// Panel (panel.tsx) over use-config.ts.
class TriggerWebhookPanel extends StatefulWidget {
  const TriggerWebhookPanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<TriggerWebhookPanel> createState() => _TriggerWebhookPanelState();
}

class _TriggerWebhookPanelState extends State<TriggerWebhookPanel> {
  bool _requestedUrl = false;
  bool _outputCollapsed = false;

  /// The document version the current typing draft began on.
  int? _base;

  NodePanelProps get _p => widget.props;
  String get _id => _p.id;
  Json get _inputs => _p.data;

  WebhookTriggerHost? get _host => WebhookTriggerHost.maybeOf(context);

  void _toast(HeaderToastType type, String message) =>
      (_host?.toast ?? WorkflowHeaderScope.of(context).toast)?.call(type, message);

  void _copy(String text) {
    final copy = _host?.copy;
    if (copy != null) {
      copy(text);
    } else {
      unawaited(Clipboard.setData(ClipboardData(text: text)));
    }
  }

  @override
  void initState() {
    super.initState();
    _maybeGenerateUrl();
  }

  @override
  void didUpdateWidget(TriggerWebhookPanel old) {
    super.didUpdateWidget(old);
    _maybeGenerateUrl();
  }

  /// Once per mount, a writable node without a URL asks for one.
  void _maybeGenerateUrl() {
    final url = _inputs['webhook_url'];
    if (_p.readOnly || (url is String && url.isNotEmpty) || _requestedUrl) return;
    _requestedUrl = true;
    // The host scope is read after the first frame (inherited widgets cannot be read in initState).
    scheduleMicrotask(() {
      if (mounted) unawaited(_config.generateWebhookUrl());
    });
  }

  /// The node as the document has it now (an answer may come after other edits).
  NodePanelProps get _live {
    final node = _p.controller.doc.nodes[_id];
    return node == null ? _p : NodePanelProps(node: node, controller: _p.controller, actions: _p.actions);
  }

  WebhookTriggerConfig get _config => WebhookTriggerConfig(
    id: _id,
    inputs: () => _live.data,
    setInputs: _write,
    readOnly: _p.readOnly,
    isVarUsedInNodes: (s) => isVarUsedInNodes(_p.controller, s),
    removeUsedVarInNodes: (s) => removeUsedVarInNodes(_p.controller, s),
    notifyError: (m) => _toast(HeaderToastType.error, m),
    fetchWebhookUrl: _host?.fetchWebhookUrl,
  );

  /// `setInputs`, with the typing draft's base for typed text.
  void _write(Json next, {bool typed = false}) =>
      setInputs(_live, next, base: typed ? _base ??= _live.controller.seenVersion : null);

  void _typing(bool focused) {
    if (!focused) _base = null;
  }

  List<Json> _rows(String key) => [
    for (final e in jsList(_inputs[key]))
      if (e is Map) e.cast<String, Object?>(),
  ];

  @override
  Widget build(BuildContext context) {
    final readOnly = _p.readOnly;
    final inputs = _inputs;
    final config = _config;
    final debugUrl = jsStr(inputs['webhook_debug_url']) ?? '';
    final method = jsStr(inputs['method']);
    final contentType = jsStr(inputs['content_type']);
    final status = inputs['status_code'];
    final selectText = difyTextStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled).copyWith(
      fontSize: 14,
      height: 20 / 14,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                Field(
                  title: _tw('nodes.triggerWebhook.webhookUrl'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 4,
                    children: [
                      SizedBox(
                        height: 32,
                        child: Row(
                          spacing: 4,
                          children: [
                            SizedBox(
                              width: 104,
                              child: Semantics(
                                label: _tw('nodes.triggerWebhook.method'),
                                child: DifySelect<String>(
                                  value: webhookHttpMethods.contains(method) ? method : null,
                                  options: [for (final m in webhookHttpMethods) (value: m, label: m)],
                                  disabled: readOnly,
                                  popupWidth: 104,
                                  textStyle: selectText,
                                  onChanged: config.handleMethodChange,
                                ),
                              ),
                            ),
                            Expanded(
                              child: _InputWithCopy(
                                value: jsStr(inputs['webhook_url']) ?? '',
                                placeholder: _tw('nodes.triggerWebhook.webhookUrlPlaceholder'),
                                onCopy: (v) {
                                  _copy(v);
                                  _toast(HeaderToastType.success, _tw('nodes.triggerWebhook.urlCopied'));
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (debugUrl.isNotEmpty)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _DebugUrl(url: debugUrl, onCopy: _copy),
                            if (isPrivateOrLocalAddress(debugUrl))
                              Padding(
                                // `space-y-2` wins over the warning's own `mt-1`.
                                padding: const EdgeInsets.only(top: 8),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 2),
                                  child: Text(
                                    _tw('nodes.triggerWebhook.debugUrlPrivateAddressWarning'),
                                    style: difyStyle(DifyType.systemXsRegular, DifyColors.textWarning),
                                  ),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
                Field(
                  title: _tw('nodes.triggerWebhook.contentType'),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 392),
                      child: Semantics(
                        label: _tw('nodes.triggerWebhook.contentType'),
                        child: DifySelect<String>(
                          value: webhookContentTypes.contains(contentType) ? contentType : null,
                          options: [for (final c in webhookContentTypes) (value: c, label: c)],
                          disabled: readOnly,
                          textStyle: selectText,
                          onChanged: config.handleContentTypeChange,
                        ),
                      ),
                    ),
                  ),
                ),
                ParameterTable(
                  readonly: readOnly,
                  title: 'Query Parameters',
                  parameters: _rows('params'),
                  onChange: config.handleParamsChange,
                  placeholder: _tw('nodes.triggerWebhook.noQueryParameters'),
                  onTextFocus: _typing,
                ),
                HeaderTable(
                  readonly: readOnly,
                  headers: _rows('headers'),
                  onChange: config.handleHeadersChange,
                  onTextFocus: _typing,
                ),
                ParameterTable(
                  readonly: readOnly,
                  title: 'Request Body Parameters',
                  parameters: _rows('body'),
                  onChange: config.handleBodyChange,
                  placeholder: _tw('nodes.triggerWebhook.noBodyParameters'),
                  contentType: contentType,
                  onTextFocus: _typing,
                ),
                const PanelSplit(),
                Field(
                  title: _tw('nodes.triggerWebhook.responseConfiguration'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 12,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: DifyText(
                              _tw('nodes.triggerWebhook.statusCode'),
                              DifyType.systemSmMedium,
                              color: DifyColors.textTertiary,
                            ),
                          ),
                          SizedBox(
                            width: 120,
                            child: StatusCodeField(
                              value: status is num ? status : defaultStatusCode,
                              disabled: readOnly,
                              onChanged: config.handleStatusCodeChange,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: DifyText(
                              _tw('nodes.triggerWebhook.responseBody'),
                              DifyType.systemSmMedium,
                              color: DifyColors.textTertiary,
                            ),
                          ),
                          ParagraphInput(
                            value: jsStr(inputs['response_body']) ?? '',
                            placeholder: _tw('nodes.triggerWebhook.responseBodyPlaceholder'),
                            disabled: readOnly,
                            onFocus: _typing,
                            onChange: config.handleResponseBodyChange,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const PanelSplit(),
          OutputVars(
            collapsed: _outputCollapsed,
            onCollapse: (v) => setState(() => _outputCollapsed = v),
            child: OutputVariablesContent(variables: _rows('variables')),
          ),
        ],
      ),
    );
  }
}

/// InputWithCopy (base/input-with-copy): a read-only input with a ghost `xs` copy button at the right (`pr-8`); its
/// tooltip says "Copy", then "Copied" until the pointer leaves.
class _InputWithCopy extends StatefulWidget {
  const _InputWithCopy({required this.value, required this.placeholder, required this.onCopy});
  final String value, placeholder;
  final ValueChanged<String> onCopy;

  @override
  State<_InputWithCopy> createState() => _InputWithCopyState();
}

class _InputWithCopyState extends State<_InputWithCopy> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final tip = DifyI18n.tr('common', _copied ? 'operation.copied' : 'operation.copy');
    return DifyInput(
      value: widget.value,
      readOnly: true,
      placeholder: widget.placeholder,
      height: 32,
      trailing: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: MouseRegion(
          onExit: (_) => setState(() => _copied = false),
          child: DifyTooltip(
            content: Text(tip),
            child: DifyIconButton(
              label: tip,
              size: DifyIconButtonSize.xs,
              variant: DifyButtonVariant.ghost,
              onPressed: () {
                setState(() => _copied = true);
                widget.onCopy(widget.value);
              },
              icon: RemixIcon(
                _copied ? 'clipboard-fill' : 'clipboard-line',
                size: 14,
                color: DifyColors.textTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The debug URL card: a 2 px bar beside "For test runs, always use this URL" and the URL (`text-xs/4`); a click
/// copies it, the tooltip above saying "Click to copy", then "Copied!" for 2 s.
class _DebugUrl extends StatefulWidget {
  const _DebugUrl({required this.url, required this.onCopy});
  final String url;
  final ValueChanged<String> onCopy;

  @override
  State<_DebugUrl> createState() => _DebugUrlState();
}

class _DebugUrlState extends State<_DebugUrl> {
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = _tw('nodes.triggerWebhook.debugUrlCopy');
    final small = difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary).copyWith(height: 16 / 12);
    return DifyTooltip(
      surface: false,
      content: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: DifyColors.componentsTooltipBg,
          border: Border.all(color: DifyColors.componentsPanelBorder),
          borderRadius: BorderRadius.circular(DifyRadius.md),
          boxShadow: DifyShadows.lg,
        ),
        child: Text(
          _copied ? _tw('nodes.triggerWebhook.debugUrlCopied') : label,
          style: difyStyle(DifyType.systemXsRegular, DifyColors.textPrimary),
        ),
      ),
      child: DifyPressable(
        semanticLabel: label,
        onPressed: () {
          widget.onCopy(widget.url);
          setState(() => _copied = true);
          _reset?.cancel();
          _reset = Timer(const Duration(seconds: 2), () {
            if (mounted) setState(() => _copied = false);
          });
        },
        // 38 px high with `py-1.5`: Dify's two 16 px lines run over the bottom padding.
        builder: (context, _, _) => SizedBox(
          height: 38,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  width: 2,
                  height: 28,
                  color: DifyColors.dividerRegular,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_tw('nodes.triggerWebhook.debugUrlTitle'), style: small, maxLines: 1),
                      Text(
                        widget.url,
                        style: small.copyWith(color: DifyColors.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
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

/// The status code NumberField (`w-30`, 200 to 399) with its increment / decrement controls (a `w-6 border-l
/// border-divider-subtle` column of chevrons); a cleared input commits 200.
class StatusCodeField extends StatelessWidget {
  const StatusCodeField({super.key, required this.value, required this.onChanged, this.disabled = false});
  final num value;
  final ValueChanged<num> onChanged;
  final bool disabled;

  void _step(int by) {
    final next = (value + by).clamp(defaultStatusCode, maxStatusCode);
    if (next != value) onChanged(next);
  }

  Widget _button(String icon, String label, int by, EdgeInsets padding) => Expanded(
    child: DifyPressable(
      disabled: disabled || (by > 0 ? value >= maxStatusCode : value <= defaultStatusCode),
      semanticLabel: label,
      onPressed: () => _step(by),
      builder: (context, hovered, _) => Container(
        color: hovered && !disabled ? DifyColors.componentsInputBgHover : null,
        padding: padding,
        alignment: Alignment.center,
        child: RemixIcon(icon, size: 12, color: DifyColors.textTertiary),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      DifyNumberField(
        value: value,
        min: defaultStatusCode,
        max: maxStatusCode,
        disabled: disabled,
        semanticLabel: _tw('nodes.triggerWebhook.statusCode'),
        inputPaddingRight: 36,
        onChanged: (v) => onChanged(v ?? defaultStatusCode),
      ),
      Positioned(
        top: 1,
        bottom: 1,
        right: 1,
        width: 24,
        child: Container(
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: DifyColors.dividerSubtle)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _button('arrow-up-s-line', 'Increment value', 1, const EdgeInsets.only(top: 3)),
              _button('arrow-down-s-line', 'Decrement value', -1, const EdgeInsets.only(bottom: 3)),
            ],
          ),
        ),
      ),
    ],
  );
}

/// `LABEL_ORDER` with Dify's `|| 999`: `raw` (0) sorts with the unknown labels, last.
int _labelOrder(Object? label) => switch (label) {
  'param' => 1,
  'header' => 2,
  'body' => 3,
  _ => 999,
};

const _labelPrefix = {'raw': 'payload', 'param': 'query_params', 'header': 'header_params', 'body': 'req_body_params'};

/// OutputVariablesContent: "No output variables", or a `<prefix>.<name> <type>` row per variable, query, header and
/// body variables first.
class OutputVariablesContent extends StatelessWidget {
  const OutputVariablesContent({super.key, required this.variables});
  final List<Json> variables;

  @override
  Widget build(BuildContext context) {
    if (variables.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: DifyText('No output variables', DifyType.systemSmRegular, color: DifyColors.textTertiary),
      );
    }
    final sorted = [for (final (i, v) in variables.indexed) (i, v)]
      ..sort((a, b) {
        final c = _labelOrder(a.$2['label']) - _labelOrder(b.$2['label']);
        return c != 0 ? c : a.$1 - b.$1;
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (_, v) in sorted) _row(v),
      ],
    );
  }

  Widget _row(Json v) {
    final label = v['label'] is String ? v['label']! as String : '';
    final name = v['variable'] is String ? v['variable']! as String : '';
    final type = v['value_type'] is String && (v['value_type']! as String).isNotEmpty
        ? v['value_type']! as String
        : 'string';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SizedBox(
        height: 18,
        child: Row(
          children: [
            DifyText('${_labelPrefix[label] ?? label}.', DifyType.codeSmRegular, color: DifyColors.textTertiary),
            Flexible(child: DifyText(name, DifyType.codeSmSemibold, color: DifyColors.textSecondary)),
            const SizedBox(width: 8),
            DifyText(type, DifyType.systemXsRegular, color: DifyColors.textTertiary),
          ],
        ),
      ),
    );
  }
}
