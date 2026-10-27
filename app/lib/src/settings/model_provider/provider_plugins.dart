/// Model-provider runtime management, using the existing Dify dialog, button and text families.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/model_catalog.dart' show renderI18nObject;
import '../../workflow/workspace_models.dart' show apiErrorMessage;
import '../settings_kit.dart' show showSettingsAlert;
import 'model_provider_env.dart';
import 'provider_data.dart' show ProviderJson;

String _t(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

Future<void> showProviderPlugins(BuildContext context, ModelProviderEnv env) async {
  final api = env.models.api;
  if (api is! ModelProviderPluginsApi) return;
  await showDifyDialog<void>(
    context,
    builder: (_) => ModelProviderScope(
      env: env,
      child: ProviderPluginsDialog(api: api as ModelProviderPluginsApi),
    ),
  );
}

class ProviderPluginsDialog extends StatefulWidget {
  const ProviderPluginsDialog({super.key, required this.api});
  final ModelProviderPluginsApi api;
  @override
  State<ProviderPluginsDialog> createState() => _ProviderPluginsDialogState();
}

class _ProviderPluginsDialogState extends State<ProviderPluginsDialog> {
  List<Map<String, Object?>>? _rows;
  String? _error;
  bool _loading = true;
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final rows = await widget.api.providerPlugins();
      if (mounted) setState(() => _rows = rows);
    } on Object catch (e) {
      if (mounted) setState(() => _error = apiErrorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _install(Map<String, Object?> row) async {
    final id = row['plugin_id'] as String;
    if (!_busy.add(id)) return;
    setState(() => _error = null);
    final env = ModelProviderScope.of(context);
    try {
      final result = await widget.api.installProviderPlugin(id);
      final task = result['task_id'];
      if (result['all_installed'] != true) {
        if (task is! String || task.isEmpty) throw StateError(_t('modelProvider.plugins.operationUnconfirmed'));
        final deadline = DateTime.now().add(const Duration(minutes: 16));
        while (true) {
          if (!mounted) return;
          final taskResult = await widget.api.providerPluginTask(task);
          if (taskResult['status'] == 'success') break;
          if (taskResult['status'] == 'failed') {
            throw StateError('${taskResult['error'] ?? _t('modelProvider.plugins.failed')}');
          }
          if (DateTime.now().isAfter(deadline)) throw StateError(_t('modelProvider.plugins.operationUnconfirmed'));
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      if (!mounted) return;
      await _load();
      await env.models.reload();
    } on Object catch (e) {
      if (mounted) setState(() => _error = apiErrorMessage(e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _remove(Map<String, Object?> row) async {
    final id = row['plugin_id'] as String;
    final installation = row['installation_id'];
    if (installation is! String || _busy.contains(id)) return;
    final env = ModelProviderScope.of(context);
    await showSettingsAlert(
      context,
      title: _t('modelProvider.plugins.removeTitle', {'plugin': _label(row, env)}),
      description: _t('modelProvider.plugins.removeDescription'),
      confirmLabel: _t('modelProvider.plugins.remove'),
      lockCancelWhileBusy: true,
      onConfirm: () async {
        setState(() {
          _busy.add(id);
          _error = null;
        });
        try {
          await widget.api.uninstallProviderPlugin(id, installationId: installation);
          if (!mounted) return;
          await _load();
          await env.models.reload();
        } finally {
          if (mounted) setState(() => _busy.remove(id));
        }
      },
    );
  }

  String _label(Map<String, Object?> row, ModelProviderEnv env) {
    final summary = env.models.summaryOf('${row['provider']}');
    final label = renderI18nObject(summary?.label, env.language);
    return label.isEmpty ? '${row['plugin_id']}' : label;
  }

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final canManage = env.canManageCredential;
    final title = _t('modelProvider.plugins.title');
    return DifyDialogSurface(
      label: title,
      width: 640,
      bordered: true,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Row(
              children: [
                Expanded(
                  child: DifyTextLine(title, style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary)),
                ),
                DifyIconButton(
                  label: _t('operation.close'),
                  icon: const RemixIcon('close-line'),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            DifyTextLine(
              _t('modelProvider.plugins.description'),
              style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
              maxLines: null,
            ),
            if (_error != null)
              DifyTextLine(
                _error!,
                style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textWarning),
                maxLines: null,
              ),
            if (_rows == null && _loading)
              DifyTextLine(_t('loading'), style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary)),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [for (final row in _rows ?? const <Map<String, Object?>>[]) _row(row, env, canManage)],
                ),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: DifyButton(
                loading: _loading,
                onPressed: _load,
                child: DifyTextLine(_t('modelProvider.plugins.refresh')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(Map<String, Object?> row, ModelProviderEnv env, bool canManage) {
    final status = '${row['status']}';
    final id = '${row['plugin_id']}';
    final busy = _busy.contains(id);
    final installed = status == 'installed';
    final update = installed && row['installed_identifier'] != row['available_identifier'];
    final label = _label(row, env);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          DifyTextLine(label, style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textPrimary)),
          DifyTextLine(
            _t('modelProvider.plugins.$status'),
            style: difyTextStyle(
              DifyType.systemSmRegular,
              installed ? DifyColors.textSecondary : DifyColors.textWarning,
            ),
          ),
          DifyTextLine(
            installed
                ? '${row['installed_version'] ?? row['installed_identifier']}'
                : '${row['available_version'] ?? ''}',
            style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
          ),
          if (canManage && (installed || status == 'missing'))
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!installed || update)
                  DifyButton(
                    key: ValueKey('plugin-install-$id'),
                    loading: busy,
                    semanticLabel:
                        '${_t(update ? 'modelProvider.plugins.update' : 'modelProvider.plugins.install')} $label',
                    onPressed: () => _install(row),
                    child: DifyTextLine(_t(update ? 'modelProvider.plugins.update' : 'modelProvider.plugins.install')),
                  ),
                if (installed)
                  DifyButton(
                    key: ValueKey('plugin-remove-$id'),
                    disabled: busy,
                    semanticLabel: '${_t('modelProvider.plugins.remove')} $label',
                    onPressed: () => _remove(row),
                    child: DifyTextLine(_t('modelProvider.plugins.remove')),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
