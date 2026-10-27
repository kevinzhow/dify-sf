import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:collab_client/collab_client.dart' show TransportException, AgentExecutorContext, AgentExecutorProfile;

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../ids.dart';
import '../workflow_editor/node_panel/bodies/llm/group_host.dart';
import '../workflow_editor/node_panel/bodies/llm/model_parameter_modal.dart';
import '../workflow_editor/prompt_editor/prompt_editor_types.dart' show extractPluginId;
import '../workflow_editor/run/ui/before_run_form.dart' show RunFilePicker;
import 'inline_composer.dart';
import 'inline_checks.dart';

typedef AgentJson = Map<String, Object?>;
AgentJson _map(Object? value) => value is Map ? value.cast<String, Object?>() : {};
List<AgentJson> _rows(Object? value) => value is List
    ? [
        for (final item in value) {..._map(item)},
      ]
    : [];
String _a(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('agent-v-2', key, params);
String _label(String key) => _a('agentDetail.configure.$key');

/// The inline workflow configuration subset. Uses the same model parameters, uploader and Dify design controls as
/// the rest of the editor; the shared Task/output fields stay in the node panel, outside this private form.
class InlineAgentConfigure extends StatefulWidget {
  const InlineAgentConfigure({
    super.key,
    required this.composer,
    required this.args,
    this.readOnly = false,
    this.pickFile,
  });
  final InlineAgentComposer composer;
  final InlineAgentWorkspaceArgs args;
  final bool readOnly;
  final RunFilePicker? pickFile;
  @override
  State<InlineAgentConfigure> createState() => _InlineAgentConfigureState();
}

class _InlineAgentConfigureState extends State<InlineAgentConfigure> {
  AgentJson? _loaded, _soul, _payload;
  String? _error;
  bool _busy = false, _uploading = false;
  int _loadGeneration = 0;
  String _note = '';
  final _editedSections = <String>{};
  final _editedEnvironment = <String>{};
  bool _editedJobFiles = false;
  AgentExecutorContext? _executors;
  Timer? _executorRefresh;
  bool _loadingExecutors = false;

  @override
  void initState() {
    super.initState();
    _reload();
    _refreshExecutors();
    _executorRefresh = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _refreshExecutors(),
    );
  }

  @override
  void dispose() {
    _executorRefresh?.cancel();
    super.dispose();
  }

  Future<void> _refreshExecutors() async {
    if (_loadingExecutors) return;
    _loadingExecutors = true;
    final context = await AgentExecutorContext.load(
      widget.composer.api,
      widget.composer.appId,
    );
    if (mounted) setState(() => _executors = context);
    _loadingExecutors = false;
  }

  bool get _locked => widget.readOnly || _busy || _payload != null;

  Future<void> _reload() async {
    final generation = ++_loadGeneration;
    final draft = _soul;
    final draftFiles = _jobFiles;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final loaded = await widget.composer.load(widget.args.nodeId);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loaded = (jsonDecode(jsonEncode(loaded)) as Map).cast<String, Object?>();
        _soul = (jsonDecode(jsonEncode(loaded['agent_soul'])) as Map).cast<String, Object?>();
        for (final key in _editedSections) {
          if (draft?.containsKey(key) == true) {
            _soul![key] = draft![key];
          } else {
            _soul!.remove(key);
          }
        }
        for (final key in _editedEnvironment) {
          final env = _map(_soul!['env']);
          _soul!['env'] = {...env, key: _map(draft?['env'])[key]};
        }
        if (_editedJobFiles) {
          final job = _map(_loaded!['node_job']);
          _loaded!['node_job'] = {
            ...job,
            'metadata': {..._map(job['metadata']), 'file_refs': draftFiles},
          };
        }
        _payload = null;
        if (draft == null) _note = '';
      });
    } on Object {
      if (mounted && generation == _loadGeneration) setState(() => _error = 'inline.loadFailed');
    } finally {
      if (mounted && generation == _loadGeneration) setState(() => _busy = false);
    }
  }

  Future<void> _save(String strategy) async {
    if (_busy || _loaded == null || _soul == null || widget.readOnly) return;
    if (!InlineAgentChecks.validTurnLimit({
      ..._soul!,
      if (_executors?.named(InlineAgentChecks.executorName(_soul)) case final profile?)
        '_max_turns_max': profile.maxTurnsMax,
    })) {
      setState(() => _error = 'inline.invalidMaxTurns');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _payload ??= await widget.composer.prepare(
        widget.args.nodeId,
        _loaded!,
        _soul!,
        strategy: strategy,
        versionNote: _note,
      );
      final saved = await widget.composer.save(widget.args.nodeId, _payload!);
      if (!mounted) return;
      setState(() {
        _loaded = saved;
        _soul = (jsonDecode(jsonEncode(saved['agent_soul'])) as Map).cast<String, Object?>();
        _payload = null;
        _editedSections.clear();
        _editedEnvironment.clear();
        _editedJobFiles = false;
        _note = '';
      });
      widget.args.onSaved(_map(saved['binding']));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        if (agentSaveUncertain(error) && !(error is TransportException && error.code == 'secrets_key_missing')) {
          _error = 'inline.saveUncertain';
        } else {
          _payload = null;
          _error = error is AgentComposerConflict || (error is TransportException && error.statusCode == 409)
              ? 'inline.changed'
              : agentSaveErrorKey(error);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _section(String key, Object? value) => setState(() {
    _soul![key] = value;
    _editedSections.add(key);
  });
  AgentJson get _model => _map(_soul?['model']);
  AgentJson get _env => _map(_soul?['env']);

  List<AgentJson> get _jobFiles => _rows(_map(_map(_loaded?['node_job'])['metadata'])['file_refs']);
  void _setJobFiles(List<AgentJson> files) => setState(() {
    _editedJobFiles = true;
    final job = _map(_loaded?['node_job']);
    _loaded = {
      ...?_loaded,
      'node_job': {
        ...job,
        'metadata': {..._map(job['metadata']), 'file_refs': files},
      },
    };
  });

  Future<void> _upload({bool task = false}) async {
    if (_locked || _uploading || widget.pickFile == null) return;
    setState(() => _uploading = true);
    try {
      final file = await widget.pickFile!('local_file');
      if (!mounted || file == null) return;
      final id = file['upload_file_id'] ?? file['id'];
      final name = file['name'] ?? file['filename'];
      if (id is! String || name is! String) throw const FormatException('file_upload_receipt');
      if (task) {
        _setJobFiles([
          ..._jobFiles,
          {...file, 'name': name, 'is_missing': false},
        ]);
        return;
      }
      _section('config_files', [
        ..._rows(_soul!['config_files']),
        {
          'name': name,
          'file_kind': 'upload_file',
          'file_id': id,
          'is_missing': false,
          if (file['size'] != null) 'size': file['size'],
          if (file['mime_type'] != null) 'mime_type': file['mime_type'],
        },
      ]);
    } on Object {
      if (mounted) setState(() => _error = 'agentDetail.configure.files.upload.failed');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Widget _text(String text, {bool error = false}) => DifyTextLine(
    text,
    style: difyTextStyle(
      DifyType.systemSmRegular,
      error ? DifyColors.textDestructive : DifyColors.textPrimary,
    ),
  );
  Widget _field(String title, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [_text(title), child],
  );
  Widget _remove(VoidCallback action) => DifyButton(
    size: DifyButtonSize.small,
    disabled: _locked,
    onPressed: action,
    child: DifyTextLine(DifyI18n.tr('common', 'operation.delete')),
  );

  Widget _environment(bool secret) {
    final key = secret ? 'secret_refs' : 'variables';
    final rows = _rows(_env[key]);
    void update() => setState(() {
      _soul!['env'] = {..._env, key: rows};
      _editedEnvironment.add(key);
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (final (index, row) in rows.indexed)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              Expanded(
                child: DifyInput(
                  value: '${row['name'] ?? row['key'] ?? ''}',
                  readOnly: _locked,
                  semanticLabel: '${_label('advancedSettings.envEditor.keyColumn')} ${index + 1}',
                  onChanged: (value) {
                    row['name'] = value;
                    update();
                  },
                ),
              ),
              Expanded(
                child: DifyInput(
                  value: secret && row['value'] == '********' ? '' : '${row['value'] ?? ''}',
                  readOnly: _locked,
                  obscureText: secret,
                  semanticLabel: '${_label('advancedSettings.envEditor.valueColumn')} ${index + 1}',
                  onChanged: (value) {
                    row['value'] = value;
                    update();
                  },
                ),
              ),
              _remove(() {
                rows.removeAt(index);
                update();
              }),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: DifyButton(
            disabled: _locked,
            onPressed: () {
              rows.add({'name': '', 'value': ''});
              update();
            },
            child: DifyTextLine(
              '${_label('advancedSettings.envEditor.add')} · ${_label('advancedSettings.envEditor.${secret ? 'scopeSecret' : 'scopePlain'}')}',
            ),
          ),
        ),
      ],
    );
  }

  Widget _contacts() {
    final human = _map(_soul!['human']);
    final rows = _rows(human['contacts']);
    void update() => _section('human', {...human, 'contacts': rows});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (final (index, row) in rows.indexed)
          Row(
            spacing: 8,
            children: [
              Expanded(
                child: DifySelect<String>(
                  value: '${row['method'] ?? row['channel'] ?? 'web_app'}',
                  disabled: _locked,
                  options: [
                    (value: 'web_app', label: _a('inline.webContact')),
                    (value: 'email', label: _a('inline.emailContact')),
                  ],
                  onChanged: (value) {
                    row.remove('channel');
                    row['method'] = value;
                    if (value == 'email') {
                      row['email'] = row['name'] ?? '';
                    } else {
                      row.remove('email');
                    }
                    update();
                  },
                ),
              ),
              Expanded(
                child: DifyInput(
                  value: '${row['email'] ?? row['name'] ?? ''}',
                  readOnly: _locked,
                  semanticLabel: '${_a('inline.contact')} ${index + 1}',
                  onChanged: (value) {
                    row['name'] = value;
                    if ((row['method'] ?? row['channel']) == 'email') row['email'] = value;
                    update();
                  },
                ),
              ),
              _remove(() {
                rows.removeAt(index);
                update();
              }),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: DifyButton(
            disabled: _locked,
            onPressed: () {
              rows.add({'id': newUuid(), 'name': '', 'method': 'web_app'});
              update();
            },
            child: DifyTextLine(_a('inline.addContact')),
          ),
        ),
      ],
    );
  }

  Widget _executorPicker(AgentJson soul) {
    final selected = InlineAgentChecks.executorName(soul);
    final context = _executors!;
    final profiles = context.profiles ?? const <AgentExecutorProfile>[];
    final missing = context.profiles != null && context.named(selected) == null;
    final unavailable = missing || (context.named(selected)?.status != null && context.named(selected)?.status != 'ok');
    String label(AgentExecutorProfile profile) =>
        '${profile.name}${profile.description.isEmpty ? '' : ' · ${profile.description}'}'
        '${profile.status == 'ok' ? '' : ' · ${_a('inline.executorStatus.${profile.status}')}'}';
    return _field(
      _a('inline.executorProfile'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          DifySelect<String>(
            key: const ValueKey('inline-agent-executor-profile'),
            value: selected,
            disabled: _locked,
            semanticLabel: _a('inline.executorProfile'),
            options: [
              for (final profile in profiles) (value: profile.name, label: label(profile)),
              if (context.named(selected) == null)
                (
                  value: selected,
                  label:
                      '$selected · ${_a(context.unknown ? 'inline.executorAvailabilityUnknown' : 'inline.executorStatus.unavailable')}',
                ),
            ],
            disabledValues: {
              for (final profile in profiles)
                if (profile.status != 'ok') profile.name,
              if (context.named(selected) == null) selected,
            },
            onChanged: (name) => _section('executor_profile', name),
          ),
          if (unavailable)
            _text(
              _a('inline.executorUnavailable', {'name': selected}),
              error: true,
            ),
          if (context.unknown) _text(_a('inline.executorUnknown')),
          Align(
            alignment: Alignment.centerLeft,
            child: DifyButton(
              size: DifyButtonSize.small,
              onPressed: _refreshExecutors,
              child: DifyTextLine(_a('inline.refreshProfiles')),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final soul = _soul;
    final model = _model;
    final plugin = '${model['plugin_id'] ?? ''}', name = '${model['model_provider'] ?? ''}';
    final provider = plugin.isEmpty || name.isEmpty ? '' : (name.startsWith('$plugin/') ? name : '$plugin/$name');
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          if (_error case final error?) Semantics(liveRegion: true, child: _text(_a(error), error: true)),
          if (_error != null)
            Wrap(
              spacing: 8,
              children: [
                if (_payload != null)
                  DifyButton(
                    key: const ValueKey('inline-agent-retry'),
                    loading: _busy,
                    onPressed: () => _save('save_to_current_version'),
                    child: DifyTextLine(
                      DifyI18n.tr('common', 'operation.retry'),
                    ),
                  ),
                if (_payload == null)
                  DifyButton(
                    disabled: _busy,
                    onPressed: _reload,
                    child: DifyTextLine(_a('inline.reload')),
                  ),
              ],
            ),
          if (soul != null)
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 20,
                  children: [
                    _field(
                      _a('inline.harnessStyle'),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 8,
                        children: [
                          DifySelect<String>(
                            key: const ValueKey('inline-agent-harness-style'),
                            value: '${soul['harness_style'] ?? 'dify'}',
                            disabled: _locked,
                            semanticLabel: _a('inline.harnessStyle'),
                            options: const [(value: 'dify', label: 'Dify'), (value: 'codex', label: 'Codex')],
                            onChanged: (style) {
                              _section('harness_style', style);
                              if (style == 'dify' && _map(soul['tools']).containsKey('update_plan')) {
                                _section('tools', {..._map(soul['tools'])}..remove('update_plan'));
                              }
                            },
                          ),
                          _text(_a('inline.harnessHint')),
                        ],
                      ),
                    ),
                    if (soul['harness_style'] == 'codex')
                      _field(
                        _a('inline.updatePlan'),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: DifySwitch(
                            key: const ValueKey('inline-agent-update-plan'),
                            checked: _map(soul['tools'])['update_plan'] == true,
                            disabled: _locked,
                            semanticLabel: _a('inline.updatePlan'),
                            onCheckedChange: (enabled) => _section('tools', {..._map(soul['tools']), 'update_plan': enabled}),
                          ),
                        ),
                      ),
                    if (_executors?.shellEnabled == true) _executorPicker(soul),
                    _field(
                      _a('inline.maxTurns'),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 8,
                        children: [
                          DifyInput(
                            key: const ValueKey('inline-agent-max-turns'),
                            value: '${_map(soul['limits'])['max_turns'] ?? 50}',
                            semanticLabel: _a('inline.maxTurns'),
                            disabled: _locked,
                            invalid: !InlineAgentChecks.validTurnLimit({
                              ...soul,
                              if (_executors?.named(InlineAgentChecks.executorName(soul)) case final profile?)
                                '_max_turns_max': profile.maxTurnsMax,
                            }),
                            onChanged: (value) => _section('limits', {'max_turns': int.tryParse(value) ?? value}),
                          ),
                          if (_executors?.unknown != true)
                            _text(
                              _a('inline.maxTurnsHint', {
                                'max': _executors?.named(InlineAgentChecks.executorName(soul))?.maxTurnsMax ?? 50,
                              }),
                            ),
                        ],
                      ),
                    ),
                    _field(
                      _a('inline.model'),
                      ModelParameterModal(
                        provider: provider,
                        modelId: '${model['model'] ?? ''}',
                        completionParams: _map(model['model_settings']),
                        readonly: _locked,
                        modelPredicate: (_, item) =>
                            inlineAgentModelCompatible(
                              item.label['en_US'] ?? item.model,
                            ) &&
                            (item.features ?? const []).any(
                              (v) => v == 'tool-call' || v == 'multi-tool-call',
                            ),
                        onModelChange: (choice) {
                          final id = extractPluginId(choice.provider);
                          _section('model', {
                            'plugin_id': id,
                            'model_provider': choice.provider.substring(
                              id.length + 1,
                            ),
                            'model': choice.modelId,
                            'model_settings': <String, Object?>{},
                          });
                        },
                        onCompletionParamsChange: (value) => _section('model', {
                          ...model,
                          'model_settings': value,
                        }),
                      ),
                    ),
                    _field(
                      _label('prompt.label'),
                      DifyTextarea(
                        key: const ValueKey('inline-agent-prompt'),
                        value: '${_map(soul['prompt'])['system_prompt'] ?? ''}',
                        readOnly: _locked,
                        semanticLabel: _label('prompt.label'),
                        onChanged: (value) => _section('prompt', {'system_prompt': value}),
                      ),
                    ),
                    _field(
                      _label('files.label'),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 8,
                        children: [
                          for (final (index, file) in _rows(
                            soul['config_files'],
                          ).indexed)
                            Row(
                              spacing: 8,
                              children: [
                                Expanded(
                                  child: _text(
                                    '${file['name'] ?? ''}${file['is_missing'] == true ? ' · ${_label('files.missing')}' : ''}',
                                    error: file['is_missing'] == true,
                                  ),
                                ),
                                _remove(() {
                                  final files = _rows(soul['config_files'])..removeAt(index);
                                  _section('config_files', files);
                                }),
                              ],
                            ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: DifyButton(
                              disabled: _locked || widget.pickFile == null,
                              loading: _uploading,
                              onPressed: _upload,
                              child: DifyTextLine(_label('files.add')),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _field(
                      _a('inline.taskFiles'),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 8,
                        children: [
                          for (final (index, file) in _jobFiles.indexed)
                            Row(
                              spacing: 8,
                              children: [
                                Expanded(
                                  child: _text(
                                    '${file['name'] ?? file['filename'] ?? ''}${file['is_missing'] == true ? ' · ${_label('files.missing')}' : ''}',
                                    error: file['is_missing'] == true,
                                  ),
                                ),
                                _remove(
                                  () => _setJobFiles(_jobFiles..removeAt(index)),
                                ),
                              ],
                            ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: DifyButton(
                              disabled: _locked || widget.pickFile == null,
                              loading: _uploading,
                              onPressed: () => _upload(task: true),
                              child: DifyTextLine(_label('files.add')),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _field(
                      _label('advancedSettings.envEditor.label'),
                      _environment(false),
                    ),
                    _field(
                      _label('advancedSettings.envEditor.scopeSecret'),
                      _environment(true),
                    ),
                    _field(_a('inline.contacts'), _contacts()),
                    _field(
                      _a('inline.versionNote'),
                      DifyInput(
                        value: _note,
                        readOnly: _locked,
                        onChanged: (value) => setState(() => _note = value),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (soul == null)
            Expanded(
              child: Center(
                child: _busy ? _text(_a('inline.loading')) : const SizedBox.shrink(),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              DifyButton(
                key: const ValueKey('inline-agent-save'),
                variant: DifyButtonVariant.primary,
                disabled: _locked || _uploading || soul == null,
                loading: _busy,
                onPressed: () => _save('save_to_current_version'),
                child: DifyTextLine(DifyI18n.tr('common', 'operation.save')),
              ),
              DifyButton(
                disabled: _locked || _uploading || soul == null,
                onPressed: () => _save('save_as_new_version'),
                child: DifyTextLine(_a('inline.saveNewVersion')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
