/// The HTTP Request node's panel (nodes/http/panel.tsx, use-config.ts, components/api-input.tsx).
library;

import 'package:flutter/material.dart';

import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../../workflow/var_types.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor.dart';
import '../../../node_panel_bodies.dart';
import '../data_common.dart';
import 'edit_body.dart';
import 'http_dialogs.dart';
import 'http_model.dart';
import 'key_value.dart';
import 'timeout.dart';
import '../../../panel_edit.dart';

/// What the HTTP panel gets from the host: the server's block default (`nodesDefaultConfigs['http-request']`, from
/// `/workflows/default-workflow-block-configs`), merged under the node's data and read for the timeout maxima.
class HttpPanelHost extends InheritedWidget {
  const HttpPanelHost({super.key, this.defaultConfig, required super.child});

  final Map<String, Object?>? defaultConfig;

  static Map<String, Object?>? defaultConfigOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HttpPanelHost>()?.defaultConfig;

  @override
  bool updateShouldNotify(HttpPanelHost old) => defaultConfig != old.defaultConfig;
}

Widget httpRequestPanelBody(BuildContext context, NodePanelProps props) => HttpRequestPanel(props: props);

/// The panel: API (method and URL, the Authorization and "Import from cURL" pills), Headers, Params, Body, Verify
/// SSL Certificate, Timeout and the output variables. Legacy data (a string body, none) is normalised once, as Dify's
/// data-ready step does.
class HttpRequestPanel extends StatefulWidget {
  const HttpRequestPanel({super.key, required this.props});
  final NodePanelProps props;

  @override
  State<HttpRequestPanel> createState() => _HttpRequestPanelState();
}

class _HttpRequestPanelState extends State<HttpRequestPanel> {
  NodePanelProps get props => widget.props;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || props.readOnly) return;
      final data = props.data, body = data['body'];
      final hydrated = hydrateHttpInputs(data, HttpPanelHost.defaultConfigOf(context));
      if (body is! Map || !jsonEquals(body, hydrated['body'])) patchInputs(props, {'body': hydrated['body']});
    });
  }

  void _set(String key, Object? value, [int? base]) => patchInputs(props, {key: value}, base: base);

  Future<void> _openAuthorization(Map<String, Object?> inputs, KeyValueVars vars) => showAuthorizationModal(
    context,
    payload: switch (inputs['authorization']) {
      final Map m => m.cast<String, Object?>(),
      _ => const {'type': 'no-auth', 'config': null},
    },
    vars: vars.text,
    nodes: vars.nodes,
    onChange: (auth) => _set('authorization', auth),
  );

  Future<void> _openCurl() => showCurlPanel(
    context,
    // Dify reselects the node so the panel remounts (its data-ready step turns a string body into rows); the panel
    // re-renders from the document here, so the import is normalised as that step would.
    onImport: (node) {
      final patch = curlImportPatch(node);
      patchInputs(props, {
        ...patch,
        'body': hydrateHttpInputs({'body': patch['body']})['body'],
      });
    },
  );

  @override
  Widget build(BuildContext context) {
    final readOnly = props.readOnly;
    final defaults = HttpPanelHost.defaultConfigOf(context);
    final inputs = hydrateHttpInputs(props.data, defaults);
    final version = versionOf(props);
    final all = NodeVars.of(props).scope;
    final nodes = NodeVars.of(props).nodesMap;
    final vars = KeyValueVars(
      text: all.filtered(typeIn(httpTextVariableTypes)).vars,
      textWithFiles: all.filtered(typeIn({...httpTextVariableTypes, VarType.file, VarType.arrayFile})).vars,
      files: all.filtered(typeIn({VarType.file, VarType.arrayFile})),
      nodes: nodes,
    );
    final authType = jsStr(jsGet(inputs['authorization'], 'type')) ?? 'no-auth';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                Field(
                  title: wf('nodes.http.api'),
                  required: true,
                  operations: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _Pill(
                        readOnly: readOnly,
                        icon: 'vender/line/general/settings-01',
                        text: wf('nodes.http.authorization.authorization'),
                        value: wf('nodes.http.authorization.$authType'),
                        onTap: () => _openAuthorization(inputs, vars),
                      ),
                      _Pill(
                        readOnly: readOnly,
                        icon: 'vender/line/files/file-arrow-01',
                        text: wf('nodes.http.curl.title'),
                        onTap: _openCurl,
                      ),
                    ],
                  ),
                  child: ApiInput(
                    method: jsStr(inputs['method']) ?? 'get',
                    url: jsStr(inputs['url']) ?? '',
                    readonly: readOnly,
                    vars: vars.text,
                    nodes: nodes,
                    version: version,
                    onMethodChange: (m) => _set('method', m),
                    onUrlChange: (url, base) => _set('url', url, base),
                  ),
                ),
                Field(
                  title: wf('nodes.http.headers'),
                  child: KeyValueLines(
                    value: jsStr(inputs['headers']) ?? '',
                    readonly: readOnly,
                    vars: vars,
                    version: version,
                    onChange: (v, base) => _set('headers', v, base),
                  ),
                ),
                Field(
                  title: wf('nodes.http.params'),
                  child: KeyValueLines(
                    value: jsStr(inputs['params']) ?? '',
                    readonly: readOnly,
                    vars: vars,
                    version: version,
                    onChange: (v, base) => _set('params', v, base),
                  ),
                ),
                Field(
                  title: wf('nodes.http.body'),
                  required: true,
                  child: EditBody(
                    payload: switch (inputs['body']) {
                      final Map m => m.cast<String, Object?>(),
                      _ => const {'type': 'none', 'data': <Object?>[]},
                    },
                    readonly: readOnly,
                    vars: vars,
                    bodyVars: all.filtered((v, _) => isSupportedHttpBodyVariable(v.type)).vars,
                    version: version,
                    onChange: (body, base) => _set('body', body, base),
                  ),
                ),
                Field(
                  title: wf('nodes.http.verifySSL.title'),
                  tooltip: wf('nodes.http.verifySSL.warningTooltip'),
                  operations: DifySwitch(
                    checked: jsTruthy(inputs['ssl_verify']),
                    disabled: readOnly,
                    semanticLabel: wf('nodes.http.verifySSL.title'),
                    onCheckedChange: (v) => _set('ssl_verify', v),
                  ),
                ),
              ],
            ),
          ),
          const PanelSplit(),
          HttpTimeout(
            payload: timeoutOf(inputs),
            readonly: readOnly,
            defaultTimeout: timeoutOf(defaults),
            onChange: (t) => _set('timeout', t),
          ),
          const PanelSplit(),
          OutputVars(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                VarItem(name: 'body', type: 'string', description: wf('nodes.http.outputVars.body')),
                VarItem(name: 'status_code', type: 'number', description: wf('nodes.http.outputVars.statusCode')),
                VarItem(name: 'headers', type: 'object', description: wf('nodes.http.outputVars.headers')),
                VarItem(name: 'files', type: 'Array[File]', description: wf('nodes.http.outputVars.files')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A header operation of the API field: `flex h-6 items-center space-x-1 rounded-md px-2`, hover
/// `bg-state-base-hover` and a 12 px icon when editable; the text `text-xs font-medium text-text-tertiary` with
/// [value] after it in `text-text-secondary`.
class _Pill extends StatefulWidget {
  const _Pill({required this.readOnly, required this.icon, required this.text, required this.onTap, this.value});
  final bool readOnly;
  final String icon, text;
  final String? value;
  final VoidCallback onTap;

  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    const style = TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500, color: DifyColors.textTertiary);
    return Semantics(
      button: !w.readOnly,
      child: MouseRegion(
        cursor: w.readOnly ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: w.readOnly ? null : w.onTap,
          child: Container(
            height: 24,
            // Field's operations are not flexible: long translations are cut rather than overflowing the title row.
            constraints: const BoxConstraints(maxWidth: 160),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: _hovered && !w.readOnly ? DifyColors.stateBaseHover : null,
              borderRadius: BorderRadius.circular(DifyRadius.md),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 4,
              children: [
                if (!w.readOnly) DifyIcon(w.icon, size: 12, color: DifyColors.textTertiary),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      text: w.text,
                      children: [
                        if (w.value != null)
                          TextSpan(
                            text: ' ${w.value}',
                            style: const TextStyle(color: DifyColors.textSecondary),
                          ),
                      ],
                    ),
                    style: style,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

/// ApiInput: the method selector (`h-8 rounded-lg border` secondary button look, the method upper-cased, a chevron
/// when editable; a 108 px list with a check) and the URL input (`/` inserts a string / number / secret variable).
class ApiInput extends StatelessWidget {
  const ApiInput({
    super.key,
    required this.method,
    required this.url,
    required this.onMethodChange,
    required this.onUrlChange,
    this.readonly = false,
    this.vars = const [],
    this.nodes = const {},
    this.version,
  });

  final String method, url;
  final ValueChanged<String> onMethodChange;
  final TextCommit onUrlChange;
  final bool readonly;
  final List<VarGroup> vars;
  final Map<String, WorkflowNodeInfo> nodes;
  final int Function()? version;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 4,
    children: [
      TypeSelector<String>(
        value: method,
        options: [for (final m in httpMethods) (value: m, label: m.toUpperCase())],
        onChanged: onMethodChange,
        readonly: readonly,
        showChecked: true,
        popupWidth: 108,
        sideOffset: 2,
        trigger: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: DifyColors.componentsButtonSecondaryBg,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
            border: Border.all(color: DifyColors.componentsButtonSecondaryBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                padding: const EdgeInsets.only(left: 2),
                child: Text(
                  method.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 12,
                    height: 18 / 12,
                    fontWeight: FontWeight.w500,
                    color: DifyColors.textPrimary,
                  ),
                ),
              ),
              if (!readonly)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: RemixIcon('arrow-down-s-line', size: 14, color: DifyColors.textSecondary),
                ),
            ],
          ),
        ),
      ),
      Expanded(
        child: VarInput(
          value: url,
          onChange: onUrlChange,
          vars: vars,
          nodesMap: nodes,
          readOnly: readonly,
          version: version,
          placeholder: readonly ? '' : wf('nodes.http.apiPlaceholder'),
          semanticLabel: wf('nodes.http.api'),
        ),
      ),
    ],
  );
}
