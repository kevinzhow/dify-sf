/// Installed tools reuse the editor store, provider form and Dify controls.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../auth/auth_controller.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../settings/form/base_form.dart';
import '../workflow_editor/node_panel/bodies/data/tool/tool_host.dart';
import '../workflow_editor/store/store.dart';

String _t(String key) => DifyI18n.tr('common', key);

class WorkflowToolsBinding extends StatefulWidget {
  const WorkflowToolsBinding({super.key, required this.api, required this.store, required this.child});
  final ToolsApi? api;
  final WorkflowStore store;
  final Widget child;
  @override
  State<WorkflowToolsBinding> createState() => _WorkflowToolsBindingState();
}

class _WorkflowToolsBindingState extends State<WorkflowToolsBinding> {
  Object? _error;
  int _generation = 0;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  @override
  void didUpdateWidget(WorkflowToolsBinding old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api || old.store != widget.store) unawaited(reload());
  }

  Future<void> reload() async {
    final api = widget.api, generation = ++_generation;
    if (api == null) return;
    try {
      final providers = await api.providers();
      final workflows = await api.workflowProviders();
      if (!mounted || generation != _generation) return;
      widget.store.buildInTools.value = providers;
      widget.store.workflowTools.value = workflows;
      widget.store.customTools.value = const [];
      widget.store.mcpTools.value = const [];
      setState(() {
        _error = null;
        _revision++;
      });
    } on Object catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = widget.api;
    if (api == null) return widget.child;
    return WorkflowToolsScope(
      api: api,
      reload: reload,
      error: _error,
      revision: _revision,
      workflows: widget.store.workflowTools.value ?? const [],
      child: ToolPanelHost(
        fetchDynamicOptions: ({required pluginId, required provider, required tool, required parameter, extraParams}) =>
            api.dynamicOptions(
              provider.contains('/') ? provider : '$pluginId/$provider',
              tool,
              parameter,
              credentialId: extraParams?['credential_id'] as String?,
            ),
        child: widget.child,
      ),
    );
  }
}

class WorkflowToolsScope extends InheritedWidget {
  const WorkflowToolsScope({
    super.key,
    required this.api,
    required this.reload,
    this.error,
    this.revision = 0,
    this.workflows = const [],
    required super.child,
  });
  final ToolsApi api;
  final Future<void> Function() reload;
  final Object? error;
  final int revision;
  final List<ToolJson> workflows;
  static WorkflowToolsScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WorkflowToolsScope>();
  @override
  bool updateShouldNotify(WorkflowToolsScope old) => old.api != api || old.error != error || old.revision != revision;
}

/// Credential selection belongs to the node; creating authorization never writes secrets into node JSON.
class ToolCredentialControl extends StatefulWidget {
  const ToolCredentialControl({
    super.key,
    required this.provider,
    required this.providerId,
    required this.selectedId,
    required this.onSelected,
    this.readOnly = false,
  });
  final ToolJson? provider;
  final String providerId;
  final String? selectedId;
  final ValueChanged<String?> onSelected;
  final bool readOnly;
  @override
  State<ToolCredentialControl> createState() => _ToolCredentialControlState();
}

class _ToolCredentialControlState extends State<ToolCredentialControl> {
  List<ToolJson> _credentials = [];
  Object? _error;
  ToolsApi? _api;
  int _generation = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final api = WorkflowToolsScope.of(context)?.api;
    if (_api != api) {
      _api = api;
      unawaited(_load());
    }
  }

  @override
  void didUpdateWidget(ToolCredentialControl old) {
    super.didUpdateWidget(old);
    if (old.providerId != widget.providerId) unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    try {
      final values = await _api?.credentials(widget.providerId) ?? [];
      if (mounted && generation == _generation) {
        setState(() {
          _credentials = values;
          _error = null;
        });
      }
    } on Object catch (error) {
      if (mounted && generation == _generation) setState(() => _error = error);
    }
  }

  Future<void> _authorize([ToolJson? initial]) async {
    final api = _api;
    if (api == null) return;
    final parent = WorkflowToolsScope.of(context);
    await showDifyDialog<void>(
      context,
      builder: (context) => _ToolAuthorizationDialog(
        api: api,
        initial: initial,
        providerId: widget.providerId,
        schema: (widget.provider?['credentials_schema'] as Map?)?.cast<String, Object?>() ?? {},
        canShare: AuthScope.read(this.context)?.account?.isPrivileged ?? false,
      ),
    );
    await _load();
    await parent?.reload();
  }

  Future<void> _delete(ToolJson value) async {
    final host = WorkflowToolsScope.of(context);
    final confirmed = await showDifyDialog<bool>(
      context,
      builder: (context) => DifyDialogSurface(
        label: _t('operation.delete'),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DifyTextLine('${value['name']}'),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                DifyButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: DifyTextLine(_t('operation.cancel')),
                ),
                DifyButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: DifyTextLine(_t('operation.delete')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await _api?.deleteCredential(widget.providerId, '${value['id']}');
      // Keep an explicit missing identity: clearing it could silently select a
      // different default secret. Pin the resolved default before removing it.
      if (mounted && widget.selectedId == null) widget.onSelected('${value['id']}');
      await _load();
      await host?.reload();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = WorkflowToolsScope.of(context);
    if (host == null) return const SizedBox.shrink();
    final error = _error ?? host.error;
    final selected =
        _credentials.where((c) => c['id'] == widget.selectedId).firstOrNull ??
        (widget.selectedId == null ? _credentials.firstOrNull : null);
    final unavailable = widget.selectedId != null && selected == null;
    final canManage = !widget.readOnly && selected?['can_manage'] == true;
    final needsCredentials = (widget.provider?['credentials_schema'] as Map?)?.isNotEmpty ?? false;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) ...[
            DifyTextLine('$error', style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textDestructive)),
            DifyButton(
              onPressed: () async {
                await host.reload();
                await _load();
              },
              child: DifyTextLine(_t('operation.retry')),
            ),
          ],
          DifySelect<String>(
            value: widget.selectedId ?? '',
            semanticLabel: DifyI18n.tr('plugin', 'auth.authorization'),
            options: [
              (value: '', label: DifyI18n.tr('plugin', 'auth.default')),
              if (unavailable)
                (value: widget.selectedId!, label: DifyI18n.tr('plugin', 'auth.credentialUnavailableInButton')),
              for (final value in _credentials) (value: '${value['id']}', label: '${value['name']}'),
            ],
            disabled: widget.readOnly,
            disabledValues: {if (unavailable) widget.selectedId!},
            onChanged: (id) => widget.onSelected(id.isEmpty ? null : id),
          ),
          if (unavailable)
            DifyTextLine(
              DifyI18n.tr('plugin', 'auth.credentialUnavailable'),
              style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textDestructive),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!widget.readOnly && needsCredentials)
                DifyButton(onPressed: _authorize, child: DifyTextLine(_t('operation.add'))),
              if (canManage) ...[
                DifyButton(onPressed: () => _authorize(selected), child: DifyTextLine(_t('operation.edit'))),
                DifyButton(onPressed: () => _delete(selected!), child: DifyTextLine(_t('operation.delete'))),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ToolAuthorizationDialog extends StatefulWidget {
  const _ToolAuthorizationDialog({
    required this.api,
    required this.providerId,
    required this.schema,
    required this.canShare,
    this.initial,
  });
  final ToolsApi api;
  final String providerId;
  final ToolJson schema;
  final bool canShare;
  final ToolJson? initial;
  @override
  State<_ToolAuthorizationDialog> createState() => _ToolAuthorizationDialogState();
}

class _ToolAuthorizationDialogState extends State<_ToolAuthorizationDialog> {
  final _form = GlobalKey<BaseFormState>();
  bool _saving = false;
  Object? _error;
  Future<void> _save() async {
    final result = _form.currentState?.getFormValues();
    if (_saving || result == null || !result.isCheckValidated) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final values = {...result.values};
      final name = values.remove('__name') as String? ?? 'API KEY';
      final shared = values.remove('__shared') == true;
      await widget.api.saveCredential(
        widget.providerId,
        id: widget.initial?['id'] as String?,
        name: name,
        credentials: values,
        shared: shared,
      );
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => DifyDialogSurface(
    label: DifyI18n.tr('plugin', 'auth.authorization'),
    padding: const EdgeInsets.all(24),
    scrollable: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AuthForm(
          formKey: _form,
          defaultValues: widget.initial == null
              ? null
              : {
                  '__name': widget.initial!['name'],
                  '__shared': widget.initial!['is_team_authorization'] == true,
                  ...((widget.initial!['credentials'] as Map?)?.cast<String, Object?>() ?? {}),
                },
          disabled: _saving,
          formSchemas: [
            FormSchema(
              type: FormTypeEnum.textInput,
              name: '__name',
              label: DifyI18n.tr('plugin', 'auth.authorizationName'),
              required: true,
            ),
            for (final field in widget.schema.entries)
              FormSchema.fromCredentialSchema({
                ...((field.value as Map?)?.cast<String, Object?>() ?? {}),
                'variable': field.key,
              }),
            if (widget.canShare)
              FormSchema(
                type: FormTypeEnum.checkbox,
                name: '__shared',
                label: DifyI18n.tr('workflow', 'nodes.humanInput.deliveryMethod.emailConfigure.allMembers', {
                  'workspaceName': _t('userProfile.workspace'),
                }),
                defaultValue: false,
              ),
          ],
        ),
        if (_error != null)
          DifyTextLine('$_error', style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textDestructive)),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            DifyButton(
              disabled: _saving,
              onPressed: () => Navigator.of(context).pop(),
              child: DifyTextLine(_t('operation.cancel')),
            ),
            DifyButton(
              loading: _saving,
              onPressed: _save,
              variant: DifyButtonVariant.primary,
              child: DifyTextLine(_t('operation.save')),
            ),
          ],
        ),
      ],
    ),
  );
}
