import 'dart:async';

import 'package:collab_client/collab_client.dart' show ModelDiscoveryApi;
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../workflow/workspace_models.dart';
import '../form/base_form.dart';
import 'model_auth.dart';
import 'model_provider_env.dart';
import 'provider_data.dart';

const compatibleDiscoveryProvider = 'langgenius/openai_api_compatible/openai_api_compatible';

Future<void> showModelAutofill(BuildContext context, {required ModelProviderEnv env, required Json provider}) =>
    showDifyDialog<void>(
      context,
      builder: (dialog) => ModelAutofillDialog(
        env: env,
        provider: provider,
        onClose: () => Navigator.of(dialog).pop(),
        onManual: () {
          Navigator.of(dialog).pop();
          ModelAuth(
            env: env,
            provider: provider,
            configurationMethod: ConfigurationMethodEnum.customizableModel,
            isModelCredential: true,
            mode: ModelModalModeEnum.configCustomModel,
          ).handleOpenModal(context);
        },
      ),
    );

/// The new-model path only. Existing credential editing keeps the complete
/// original plugin form and its hidden-secret round trip.
class ModelAutofillDialog extends StatefulWidget {
  const ModelAutofillDialog({
    super.key,
    required this.env,
    required this.provider,
    required this.onClose,
    this.onManual,
  });
  final ModelProviderEnv env;
  final Json provider;
  final VoidCallback onClose;
  final VoidCallback? onManual;
  @override
  State<ModelAutofillDialog> createState() => _ModelAutofillDialogState();
}

class _ModelAutofillDialogState extends State<ModelAutofillDialog> {
  String _url = '', _key = '', _selected = '', _query = '';
  String? _discoveryId, _error;
  List<Json> _models = [];
  final Map<String, Json> _overrides = {}, _probes = {};
  bool _connected = false, _manual = false, _busy = false, _probing = false;
  bool _advanced = false, _confirmProbe = false, _showKey = false, _saved = false, _incomplete = false;
  int _epoch = 0, _formVersion = 0;
  var _advancedKey = GlobalKey<BaseFormState>();
  void _resetForm() {
    ++_formVersion;
    _advancedKey = GlobalKey<BaseFormState>();
  }

  ModelDiscoveryApi get _api => widget.env.models.api! as ModelDiscoveryApi;
  String t(String zh, String en) => widget.env.language.startsWith('zh') ? zh : en;
  Json get _connection => {'endpoint_url': _url.trim(), 'api_key': _key};
  String get _effectiveModel {
    final name = '${_overrides[_selected]?['endpoint_model_name'] ?? ''}'.trim();
    return name.isEmpty ? _selected : name;
  }

  bool get _verifiedConnection =>
      _discoveryId != null || map(map(_probe?['fields'])['api_type'])['source'] == 'observed';
  Json get _listed => _models.where((m) => m['id'] == _effectiveModel).firstOrNull ?? const {};
  Json map(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value} : const {};
  Json get _declaredFields {
    final fields = map(_listed['fields']);
    if (_listed['tool_api_type'] != null &&
        _listed['tool_api_type'] != _protocol &&
        map(fields['tools'])['source'] == 'reference') {
      return {
        ...fields,
        'tools': {'value': null, 'source': 'unknown'},
      };
    }
    return fields;
  }

  Json? get _probe {
    final p = _probes[_selected];
    return p?['protocol'] == _protocol && p?['id'] == _effectiveModel ? p : null;
  }

  String get _protocol =>
      (_overrides[_selected]?['api_type'] ?? map(map(_listed['fields'])['api_type'])['value'] ?? 'chat_completions') as String;
  Json get _fields => {
    ..._declaredFields,
    for (final entry in map(_probe?['fields']).entries)
      if (map(entry.value)['source'] == 'observed') entry.key: entry.value,
  };
  Object? value(String name) => map(_fields[name])['value'];
  Json get _settings {
    final raw = modelFormSchemas(widget.provider, providerFormSchemaPredefined: false).formValues;
    final fields = _fields;
    Object? val(String name) => map(fields[name])['value'];
    return {
      ...raw,
      '__model_type': 'llm',
      'display_name': val('display_name') ?? _selected,
      'api_type': _protocol,
      'context_size': '${val('context_capacity') ?? 4096}',
      'max_tokens_to_sample': '${val('output_capacity') ?? 1024}',
      'vision_support': val('vision') == true ? 'support' : 'no_support',
      'function_calling_type': val('tools') == true ? 'tool_call' : 'no_call',
      'structured_output_support': val('json_schema') == true ? 'supported' : 'not_supported',
      'agent_thought_support':
          val('reasoning') == true || (val('reasoning_levels') is List && (val('reasoning_levels') as List).isNotEmpty)
          ? 'only_thinking_supported'
          : 'not_supported',
      ...?_overrides[_selected],
    };
  }

  String source(String name) => switch (map(_fields[name])['source']) {
    'provider' => t('服务商提供', 'Provider declared'),
    'observed' => t('实际检测', 'Observed'),
    'reference' => t('官方说明', 'Official documentation'),
    'catalog' => t('内置模型目录', 'Bundled model catalog'),
    _ => t('未知', 'Unknown'),
  };
  String diagnostic(String name) {
    final d = map(map(_probe?['diagnostics'])[name]);
    if (d.isEmpty) return '';
    final reason = switch (d['reason']) {
      'http_error' => t('接口拒绝请求', 'The endpoint rejected the request'),
      'output_budget_exhausted' => t(
        '生成预算已用尽，未得到完整结果',
        'The generation budget ended before a complete result',
      ),
      'transport_error' => t('连接失败或超时', 'Connection failed or timed out'),
      'invalid_response' => t(
        '接口返回格式无法识别',
        'The response format could not be read',
      ),
      _ => t('返回结果未能证明此能力', 'The result did not establish this capability'),
    };
    final status = d['http_status'] is int ? ' · HTTP ${d['http_status']}' : '';
    final code = d['code'] is String ? ' · ${d['code']}' : '';
    return '$reason$status$code';
  }

  bool get _validConnection {
    final uri = Uri.tryParse(_url.trim());
    return uri != null &&
        const ['http', 'https'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  }

  void _changeConnection({String? url, String? key}) => setState(() {
    if (url != null) _url = url;
    if (key != null) _key = key;
    ++_epoch;
    _connected = false;
    _discoveryId = null;
    _probes.clear();
    _overrides.clear();
    _models = [];
    _busy = _probing = false;
    _error = null;
  });

  Future<void> _discover() async {
    if (!_validConnection || _busy || !widget.env.canCreateCredential) return;
    final epoch = ++_epoch;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final answer = await _api.discoverModels(compatibleDiscoveryProvider, credentials: _connection);
      if (!mounted || epoch != _epoch) return;
      final models = [for (final item in answer['models'] as List? ?? const []) map(item)];
      setState(() {
        _models = models;
        _discoveryId = answer['discovery_id'] as String?;
        _incomplete = answer['incomplete'] == true;
        if (_selected.isEmpty && models.isNotEmpty) _selected = '${models.first['id']}';
        _manual = !models.any((m) => m['id'] == _selected);
        _connected = true;
        _resetForm();
      });
    } on Object catch (e) {
      if (mounted && epoch == _epoch) setState(() => _error = apiErrorMessage(e));
    } finally {
      if (mounted && epoch == _epoch) setState(() => _busy = false);
    }
  }

  Future<void> _runProbe() async {
    if (_probing || _selected.trim().isEmpty || !widget.env.canCreateCredential) return;
    final epoch = ++_epoch, model = _effectiveModel, selected = _selected, protocol = _protocol;
    setState(() {
      _probing = true;
      _error = null;
    });
    try {
      final answer = await _api.probeModel(
        compatibleDiscoveryProvider,
        credentials: _connection,
        model: model,
        apiType: protocol,
        consent: true,
      );
      if (!mounted || epoch != _epoch || model != _effectiveModel || selected != _selected || protocol != _protocol) {
        return;
      }
      setState(() {
        _probes[selected] = answer;
        _confirmProbe = false;
        _resetForm();
      });
    } on Object catch (e) {
      if (mounted && epoch == _epoch) setState(() => _error = apiErrorMessage(e));
    } finally {
      if (mounted && epoch == _epoch) setState(() => _probing = false);
    }
  }

  void _select(String id, {required bool manual}) => setState(() {
    ++_epoch;
    _probing = false;
    _selected = id;
    _manual = manual;
    _saved = false;
    _confirmProbe = false;
    _error = null;
    _resetForm();
  });

  Future<void> _save() async {
    if (_busy || _probing || !widget.env.canCreateCredential || _selected.trim().isEmpty || !_verifiedConnection) {
      return;
    }
    final form = _advancedKey.currentState?.getFormValues();
    if (form != null && !form.isCheckValidated) return;
    final settings = {..._settings, ...?form?.values}..remove('__authorization_name__');
    for (final field in ['context_size', 'max_tokens_to_sample']) {
      final n = int.tryParse('${settings[field]}');
      if (n == null || n <= 0 || n > 1000000000) {
        setState(() => _error = t('使用预算必须是正整数。', 'Usage budgets must be positive integers.'));
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.createAutofilledModel(
        compatibleDiscoveryProvider,
        model: _selected,
        credentials: {...settings, ..._connection},
        discoveryId: _discoveryId,
        probeId: _probe?['probe_id'] as String?,
      );
      if (!mounted) return;
      setState(() => _saved = true);
      unawaited(widget.env.models.refreshModel(widget.provider, refreshModelList: true));
    } on Object catch (e) {
      if (mounted) setState(() => _error = apiErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget text(String s, {bool muted = false}) => DifyTextLine(
    s,
    style: difyTextStyle(DifyType.systemSmRegular, muted ? DifyColors.textTertiary : DifyColors.textPrimary),
    maxLines: null,
  );
  Widget button(String label, VoidCallback? action, {bool primary = false, bool loading = false}) => DifyButton(
    onPressed: action,
    disabled: action == null,
    loading: loading,
    variant: primary ? DifyButtonVariant.primary : DifyButtonVariant.secondary,
    child: DifyTextLine(label),
  );
  Widget notice(String message, {bool error = false}) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DifyColors.backgroundSectionBurn,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: DifyTextLine(
        message,
        maxLines: null,
        style: difyTextStyle(DifyType.systemSmRegular, error ? DifyColors.textDestructive : DifyColors.textSecondary),
      ),
    ),
  );
  Widget field(String label, Widget control) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [text(label), const SizedBox(height: 6), control],
    ),
  );

  Widget _connectionBody() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      text(t('连接兼容 OpenAI 的模型服务', 'Connect an OpenAI-compatible model service')),
      const SizedBox(height: 20),
      field(
        'Base URL',
        DifyInput(
          key: const ValueKey('autofill-url'),
          value: _url,
          semanticLabel: 'Base URL',
          autofocus: true,
          placeholder: 'https://api.example.com/v1',
          onChanged: (v) => _changeConnection(url: v),
        ),
      ),
      field(
        'API Key',
        DifyInput(
          key: const ValueKey('autofill-key'),
          value: _key,
          semanticLabel: 'API Key',
          obscureText: !_showKey,
          onChanged: (v) => _changeConnection(key: v),
          trailing: DifyIconButton(
            label: t('显示或隐藏密钥', 'Show or hide key'),
            onPressed: () => setState(() => _showKey = !_showKey),
            icon: RemixIcon(_showKey ? 'eye-off-line' : 'eye-line', size: 16),
          ),
        ),
      ),
      text(
        t(
          '地址和密钥仅用于连接此服务，添加后加密保存。获取列表不会调用模型。',
          'The connection is encrypted when saved. Fetching the list does not invoke a model.',
        ),
        muted: true,
      ),
      const SizedBox(height: 12),
      button(
        t('手动输入列表外模型', 'Enter a model manually'),
        _validConnection && !_busy
            ? () => setState(() {
                _connected = true;
                _manual = true;
                _models = [];
                _selected = '';
                _error = null;
              })
            : null,
      ),
    ],
  );

  Widget _capacity(String title, String key) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      border: Border.all(color: DifyColors.dividerSubtle),
      borderRadius: BorderRadius.circular(DifyRadius.lg),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        text(title, muted: true),
        const SizedBox(height: 6),
        text('${value(key) ?? t('未知', 'Unknown')}'),
        const SizedBox(height: 4),
        text(source(key), muted: true),
      ],
    ),
  );

  Widget _modelBody() {
    final selected = _selected;
    final schemas = widget.provider
        .credentialFormSchemas(predefined: false)
        .where((s) => !const ['endpoint_url', 'api_key'].contains(s['variable']))
        .map(
          (s) => FormSchema.fromCredentialSchema({
            ...s,
            if (s['variable'] == 'context_size') 'label': t('上下文使用预算', 'Context usage budget'),
            if (s['variable'] == 'max_tokens_to_sample') 'label': t('输出使用预算', 'Output usage budget'),
          }),
        )
        .toList();
    final filtered = _models.where((m) => '${m['id']}'.toLowerCase().contains(_query.toLowerCase())).toList();
    final options = [for (final m in filtered) (value: '${m['id']}', label: '${m['id']}')];
    if (!_manual && !options.any((m) => m.value == selected)) options.insert(0, (value: selected, label: selected));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            text(Uri.tryParse(_url)?.host ?? _url, muted: true),
            button(
              t('更换连接', 'Change connection'),
              _busy || _probing
                  ? null
                  : () => setState(() {
                      _connected = false;
                      _error = null;
                    }),
            ),
            button(t('刷新列表', 'Refresh list'), _busy || _probing ? null : _discover),
          ],
        ),
        const SizedBox(height: 20),
        if (!_manual) ...[
          field(
            t('搜索模型', 'Search models'),
            DifyInput(
              value: _query,
              semanticLabel: t('搜索模型', 'Search models'),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          field(
            t('选择模型', 'Select model'),
            DifySelect<String>(
              value: selected,
              options: options,
              semanticLabel: t('选择模型', 'Select model'),
              disabled: _busy || _probing,
              onChanged: (v) => _select(v, manual: false),
            ),
          ),
          button(
            t('找不到？输入完整模型名', 'Not listed? Enter the complete name'),
            _busy || _probing ? null : () => _select('', manual: true),
          ),
        ] else ...[
          field(
            t('完整模型名', 'Complete model name'),
            DifyInput(
              key: const ValueKey('autofill-model'),
              value: selected,
              disabled: _busy,
              semanticLabel: t('完整模型名', 'Complete model name'),
              placeholder: 'provider/model-name',
              onChanged: (v) => _select(v.trim(), manual: true),
            ),
          ),
          if (_models.isNotEmpty)
            button(
              t('返回模型列表', 'Back to model list'),
              _busy || _probing ? null : () => _select('${_models.first['id']}', manual: false),
            ),
        ],
        if (_incomplete)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: notice(
              t(
                '服务商返回的列表不完整。可以输入完整模型名。',
                'The service returned an incomplete list. You can enter a complete model name.',
              ),
            ),
          ),
        if (selected.isNotEmpty) ...[
          const SizedBox(height: 20),
          if (!_verifiedConnection)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: notice(
                t(
                  '服务未提供可验证的模型列表。添加前请主动检测此连接，或使用完整手动表单。',
                  'The service did not provide a verifiable model list. Explicitly probe this connection before adding, or use the full manual form.',
                ),
              ),
            ),
          text(t('自动填写的信息', 'Automatically filled information')),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth < 360
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _capacity(t('上下文容量', 'Context capacity'), 'context_capacity'),
                      const SizedBox(height: 8),
                      _capacity(t('输出容量', 'Output capacity'), 'output_capacity'),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _capacity(t('上下文容量', 'Context capacity'), 'context_capacity')),
                      const SizedBox(width: 8),
                      Expanded(child: _capacity(t('输出容量', 'Output capacity'), 'output_capacity')),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          for (final item in [
            ('vision', t('看图', 'Vision')),
            ('reasoning', t('推理', 'Reasoning')),
            ('tools', t('工具调用', 'Tool calls')),
            ('json_schema', 'JSON Schema'),
            ('streaming', t('流式输出', 'Streaming')),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  text(
                    '${item.$2} · ${value(item.$1) == true
                        ? t('支持', 'Supported')
                        : value(item.$1) == false
                        ? t('声明不支持', 'Declared unsupported')
                        : t('未确认', 'Unknown')} · ${source(item.$1)}',
                    muted: true,
                  ),
                  if (diagnostic(item.$1).isNotEmpty) text(diagnostic(item.$1), muted: true),
                ],
              ),
            ),
          if (_listed['tool_api_type'] != null && _listed['tool_api_type'] != _protocol)
            notice(
              t(
                '此模型的工具调用需要 Responses API，请在高级设置中切换接口。',
                'Tool calls for this model require the Responses API. Change the API type in advanced settings.',
              ),
            ),
          if ([
            'vision',
            'tools',
            'json_schema',
            'reasoning',
          ].any((name) => value(name) == null))
            notice(
              t(
                '未确认不代表不支持。未确认的能力暂不开启，可继续检测或在高级设置中手动设置。',
                'Unknown does not mean unsupported. Unconfirmed capabilities stay off until verified or set manually in advanced settings.',
              ),
            ),
          const SizedBox(height: 8),
          text(
            value('reasoning_levels') is List && (value('reasoning_levels') as List).isNotEmpty
                ? '${t('推理档位', 'Reasoning levels')} · ${(value('reasoning_levels') as List).join(', ')} · ${source('reasoning_levels')}'
                : t(
                    '推理档位 · 服务未声明，运行参数中可自定义，由服务校验。',
                    'Reasoning levels · Not declared. Enter a custom value in model parameters; the service validates it.',
                  ),
            muted: true,
          ),
          if (value('context_capacity') == null || value('output_capacity') == null)
            notice(
              t(
                '容量未知时，先使用 4,096 上下文 / 1,024 输出的应用预算。预算不代表模型真实容量，也不保证服务端会执行输出上限。',
                'Unknown capacity uses application budgets of 4,096 context / 1,024 output. These are not measured capacities or a guaranteed output limit.',
              ),
            ),
          if (value('output_limit') == false)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: notice(
                t('本次检测中，服务没有执行请求的输出上限。', 'The service did not enforce the requested output limit in this probe.'),
              ),
            ),
          const SizedBox(height: 12),
          button(
            t('检测常用能力', 'Probe common capabilities'),
            _busy || _probing ? null : () => setState(() => _confirmProbe = !_confirmProbe),
          ),
          if (_confirmProbe)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  notice(
                    t(
                      '最多发送 7 次请求，每次请求的生成上限设为 1,024 token，检测看图、工具往返、JSON、流式输出和上限行为，可能产生费用。不能据此测出最大容量；未知结果仍显示未知。',
                      'Sends up to 7 requests, requesting up to 1,024 generated tokens each, for vision, tool round trips, JSON, streaming and output-limit behavior. Provider charges may apply. It cannot measure maximum capacity. Ambiguous results stay unknown.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  button(
                    t('确认检测，可能产生费用', 'Confirm probe; charges may apply'),
                    _probing ? null : _runProbe,
                    loading: _probing,
                  ),
                ],
              ),
            ),
          if (_probing)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: notice(
                t('正在检测，请稍候。关闭窗口不会撤销已发送的请求。', 'Probing. Closing this dialog does not undo requests already sent.'),
              ),
            ),
          const SizedBox(height: 20),
          button(t('高级设置', 'Advanced settings'), () => setState(() => _advanced = !_advanced)),
          if (_advanced)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  text(
                    t(
                      '手动修改优先，刷新列表会保留。使用预算与上方真实容量分开展示。',
                      'Manual overrides take priority and survive refresh. Usage budgets are separate from the capacities above.',
                    ),
                    muted: true,
                  ),
                  const SizedBox(height: 12),
                  AuthForm(
                    key: ValueKey('$_selected-$_formVersion'),
                    formKey: _advancedKey,
                    formSchemas: schemas,
                    defaultValues: _settings,
                    disabled: _busy || _probing,
                    onChange: (field, value) => setState(() {
                      _overrides.putIfAbsent(selected, () => {})[field] = value;
                      if (field == 'api_type' || field == 'endpoint_model_name') {
                        ++_epoch;
                        _probes.remove(selected);
                      }
                    }),
                  ),
                  button(
                    t('恢复自动设置', 'Restore automatic settings'),
                    _busy || _probing
                        ? null
                        : () => setState(() {
                            _overrides.remove(selected);
                            _resetForm();
                          }),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => DifyDialogSurface(
    label: t('添加模型', 'Add model'),
    width: 640,
    bordered: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DifyTextLine(
                t('添加模型', 'Add model'),
                style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
              ),
              const SizedBox(height: 12),
              text(
                _connected
                    ? t('✓ 连接服务　—　② 选择模型', '✓ Connect service  —  ② Select model')
                    : t('① 连接服务　—　② 选择模型', '① Connect service  —  ② Select model'),
                muted: true,
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null)
                  Padding(padding: const EdgeInsets.only(bottom: 12), child: notice(_error!, error: true)),
                if (_saved) ...[
                  notice(t('模型已添加，可以在工作流中选择。', 'Model added. It is now available in workflows.')),
                  const SizedBox(height: 16),
                  text(_selected),
                  const SizedBox(height: 16),
                  button(
                    t('继续添加其他模型', 'Add another model'),
                    () => setState(() {
                      _saved = false;
                      _selected = '';
                      _manual = _models.isEmpty;
                    }),
                  ),
                ] else if (_connected)
                  _modelBody()
                else
                  _connectionBody(),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(24),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              button(
                t('完整手动表单', 'Full manual form'),
                _busy || _probing
                    ? null
                    : widget.onManual ??
                          () {
                            widget.onClose();
                            ModelAuth(
                              env: widget.env,
                              provider: widget.provider,
                              configurationMethod: ConfigurationMethodEnum.customizableModel,
                              isModelCredential: true,
                              mode: ModelModalModeEnum.configCustomModel,
                            ).handleOpenModal(context);
                          },
              ),
              button(t('关闭', 'Close'), widget.onClose),
              if (!_saved)
                button(
                  _connected ? t('添加模型', 'Add model') : t('获取模型', 'Fetch models'),
                  _busy ||
                          _probing ||
                          !widget.env.canCreateCredential ||
                          (_connected ? _selected.isEmpty || !_verifiedConnection : !_validConnection)
                      ? null
                      : _connected
                      ? _save
                      : _discover,
                  primary: true,
                  loading: _busy,
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
