/// The Environment Variables panel (panel/env-panel: index.tsx, env-item.tsx, variable-trigger.tsx) on the
/// collaborative document.
///
/// Dify persists each change through its API (with a queue, a draft-sync fallback and rollbacks); here a change is
/// item ops on the document's `environment_variables` list, and an edit carries the version its modal opened on, so
/// a variable someone else changed meanwhile is refused with the editor's conflict notice instead of overwritten.
/// A secret's plaintext never goes into an op: it is stored server-side first ([StoreSecret]) and the item holds
/// Dify's mask and the `secret_ref`; a secret the modal did not change keeps both.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../editor/editor_controller.dart';
import '../../workflow/dify_json.dart';
import '../node_panel/bodies/core/core_kit.dart' show showRemoveEffectVarConfirm;
import '../node_panel/bodies/llm/group_host.dart';
import '../node_panel/bodies/llm/llm_config.dart' show mergeValidCompletionParams;
import '../node_panel/bodies/llm/model_parameter_modal.dart' show ModelParameterRule;
import '../node_panel/panel_edit.dart' show writeInputs;
import '../store/store.dart';
import 'app_variables.dart';
import 'env_variable_modal.dart';
import 'panel_kit.dart';
import '../../design/widgets/widgets.dart';

/// EnvPanel: the description, "Add Variable" (the modal opens beside the panel) and the variables of
/// [WorkflowStore.environmentVariables], each with edit and delete. Deleting one that nodes use asks first, and
/// clears those uses; renaming one renames its uses.
class EnvPanel extends StatefulWidget {
  const EnvPanel({super.key, required this.controller, this.storeSecret});
  final EditorController controller;

  /// Stores a secret's plaintext server-side ([EditorController.storeSecret] by default).
  final StoreSecret? storeSecret;

  @override
  State<EnvPanel> createState() => _EnvPanelState();
}

class _EnvPanelState extends State<EnvPanel> {
  bool _showVariableModal = false;
  DifyVariable? _currentVar;

  /// The version the edited variable was seen at when its modal opened.
  int _base = 0;

  EditorController get _c => widget.controller;
  WorkflowStore get _store => WorkflowStoreScope.of(context);
  AppVariableList get _list => AppVariableList(_c, AppVariableList.environment);

  void _handleEdit(DifyVariable env) => setState(() {
    _currentVar = env;
    _base = _c.seenVersion;
    _showVariableModal = true;
  });

  List<String> _selector(DifyVariable env) => ['env', '${env['name']}'];

  void _deleteCheck(DifyVariable env) {
    if (findUsedVarNodes(_selector(env), _c.doc.nodes.values).isNotEmpty) {
      showRemoveEffectVarConfirm(context, onConfirm: () => _handleDelete(env));
    } else {
      _handleDelete(env);
    }
  }

  void _handleDelete(DifyVariable env) {
    _list.remove('${env['id']}');
    updateAffectedNodes(_c, _store, _selector(env), const []);
  }

  /// The masked value a secret's modal showed (Dify's `envSecrets[id]`; here the item's mask).
  Object? _shownSecret(DifyVariable env) => _store.envSecrets.value[env['id']] ?? env['value'];

  /// [env] as it goes into the document: a secret's plaintext replaced by its mask and reference (stored first),
  /// unless it is the unchanged value of the secret [current]. Null (after an error toast) when storing failed.
  Future<DifyVariable?> _secured(DifyVariable env, DifyVariable? current) async {
    final out = {...env}..remove(AppRegisters.secretRef);
    if (env['value_type'] != 'secret') return out;
    if (current != null && current['value_type'] == 'secret' && env['value'] == _shownSecret(current)) {
      return {...out, 'value': current['value'], AppRegisters.secretRef: ?current[AppRegisters.secretRef]};
    }
    final store = widget.storeSecret ?? _c.storeSecret;
    try {
      final r = await store('${env['value']}');
      return {...out, 'value': r.masked, AppRegisters.secretRef: r.ref};
    } on Object {
      if (mounted) toastError(context, tc('error'));
      return null;
    }
  }

  Future<void> _handleSave(DifyVariable env) async {
    final current = _currentVar, base = _base;
    final next = await _secured(env, current);
    if (next == null || !mounted) return;
    if (current == null) return _list.add(next);

    void Function()? reconcile;
    try {
      reconcile = await _prepareAffectedLLMNodeReconciliation(current, next);
    } on Object {
      if (mounted) toastError(context, tc('error'));
      return;
    }
    if (!mounted) return;
    // Someone changed or removed the variable since the modal opened: the protocol refuses this update (the
    // editor shows the conflict), and the nodes stay as they are.
    final live = variableById(_c.appLists.environmentVariables, current['id']);
    final seen = live != null && jsonEquals(live, current);
    _list.update(next, base: base);
    if (!seen) return;
    reconcile?.call();
    if (current['name'] != next['name']) updateAffectedNodes(_c, _store, _selector(current), _selector(next));
  }

  static Map<String, Object?>? _llmValue(DifyVariable env) =>
      env['value_type'] == 'llm' && isLLMEnvironmentVariableValue(env['value'])
      ? (env['value']! as Map).cast<String, Object?>()
      : null;

  /// `prepareAffectedLLMNodeReconciliation`: when an `llm` variable's model changes, the LLM nodes whose model is
  /// that variable take the new model, keep the completion parameters its rules allow (fetched first; a failure
  /// throws and nothing is saved) and turn vision off when the model has none. The returned function writes them,
  /// from the nodes as they are then.
  Future<void Function()?> _prepareAffectedLLMNodeReconciliation(DifyVariable current, DifyVariable next) async {
    final from = _llmValue(current), to = _llmValue(next);
    if (from == null || to == null) return null;
    if (from['provider'] == to['provider'] && from['name'] == to['name'] && from['mode'] == to['mode']) return null;
    final selector = 'env.${current['name']}';
    bool usesVariable(Node n) => n.type == 'llm' && jsList(plainOf(n.config['model_selector'])).join('.') == selector;
    if (!findUsedVarNodes(_selector(current), _c.doc.nodes.values).any(usesVariable)) return null;
    final services = LlmGroupScope.of(context);
    final target = services.models.activeTextGenerationModelList
        .where((p) => p.provider == to['provider'])
        .firstOrNull
        ?.models
        .where((m) => m.model == to['name'])
        .firstOrNull;
    final supportsVision = target?.features?.contains('vision') ?? false;
    final loader = services.parameterRules;
    // Without a backend the rules are unknown: the parameters stay.
    final rules = loader == null
        ? null
        : [for (final r in await loader('${to['provider']}', '${to['name']}')) ModelParameterRule.fromJson(r)];
    return () {
      for (final n in [..._c.doc.nodes.values.where(usesVariable)]) {
        final data = difyDataOf(n);
        final model = {...?(data['model'] as Map?)?.cast<String, Object?>()};
        final params = (model['completion_params'] as Map?)?.cast<String, Object?>();
        final vision = data['vision'];
        writeInputs(_c, n.id, {
          ...data,
          'model': {
            ...model,
            'provider': to['provider'],
            'name': to['name'],
            'completion_params': rules == null
                ? params
                : mergeValidCompletionParams(params, rules, isAdvancedMode: true).params,
          },
          'vision': !supportsVision
              ? {'enabled': false}
              : jsTruthy(jsGet(vision, 'enabled'))
              ? {
                  'enabled': true,
                  'configs': {'detail': 'high', 'variable_selector': <Object?>[]},
                }
              : vision,
        });
      }
    };
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return VariablePanelShell(
      title: tw('env.envPanelTitle'),
      actions: [PanelCloseButton(onPressed: () => store.setShowEnvPanel(false))],
      children: [
        PanelDescription(tw('env.envDescription')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: EnvVariableTrigger(
            open: _showVariableModal,
            setOpen: (v) => setState(() => _showVariableModal = v),
            env: _currentVar,
            onSave: _handleSave,
            onClose: () => setState(() => _currentVar = null),
          ),
        ),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: store.environmentVariables,
            builder: (context, envList, _) => ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final env in envList)
                  EnvItem(
                    key: ValueKey(env['id']),
                    env: env,
                    onEdit: _handleEdit,
                    onDelete: _deleteCheck,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// VariableTrigger: "Add Variable" with the [EnvVariableModal] (for [env], or a new variable) in a popover beside
/// it. Closing it any way ([setOpen] false) calls [onClose].
class EnvVariableTrigger extends StatelessWidget {
  const EnvVariableTrigger({
    super.key,
    required this.open,
    required this.setOpen,
    this.env,
    required this.onClose,
    required this.onSave,
  });
  final bool open;
  final ValueChanged<bool> setOpen;
  final DifyVariable? env;
  final VoidCallback onClose;
  final ValueChanged<DifyVariable> onSave;

  @override
  Widget build(BuildContext context) => VariableModalTrigger(
    open: open,
    onOpenChange: (next) {
      setOpen(next);
      if (!next) onClose();
    },
    label: tw('env.envPanelButton'),
    alignOffset: -104,
    modalKey: env?['id'],
    modalBuilder: (context) => EnvVariableModal(
      env: env,
      onSave: onSave,
      onClose: () {
        onClose();
        setOpen(false);
      },
    ),
  );
}

/// EnvItem: the variable's card (violet env icon, name, type, a lock for secrets) with its value (a secret's mask,
/// an `llm` variable's model name) and its description in a strip below.
class EnvItem extends StatelessWidget {
  const EnvItem({super.key, required this.env, required this.onEdit, required this.onDelete});
  final DifyVariable env;
  final ValueChanged<DifyVariable> onEdit, onDelete;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: WorkflowStoreScope.of(context).envSecrets,
    builder: (context, envSecrets, _) {
      final type = '${env['value_type'] ?? ''}';
      final value = env['value'];
      final display = type == 'secret'
          ? envSecrets[env['id']] ?? value
          : value is Map
          ? value['name']
          : value;
      final text = display == null ? '' : jsKey(display);
      final description = '${env['description'] ?? ''}';
      return VariableItemCard(
        icon: DifyIcon('vender/line/others/env', size: 16, color: DifyColors.utilColorsVioletViolet600),
        name: DifyText('${env['name']}', DifyType.systemSmMedium),
        type: type == 'llm' ? tw('blocks.llm') : capitalize(type),
        badge: type == 'secret' ? RemixIcon('lock-2-line', size: 12, color: DifyColors.textTertiary) : null,
        onEdit: () => onEdit(env),
        onDelete: () => onDelete(env),
        body: text.isEmpty ? null : DifyText(text, DifyType.systemXsRegular, color: DifyColors.textTertiary),
        footerBuilder: description.isEmpty
            ? null
            : (hovered, destructive) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: destructive
                      ? DifyColors.stateDestructiveHover
                      : hovered
                      ? null
                      : DifyColors.backgroundDefaultSubtle,
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(DifyRadius.lg - 1)),
                ),
                child: DifyText(description, DifyType.systemXsRegular, color: DifyColors.textTertiary),
              ),
      );
    },
  );
}
