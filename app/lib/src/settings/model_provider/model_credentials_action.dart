import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/widgets/widgets.dart';
import '../../workflow/model_catalog.dart';
import '../../workflow/workspace_models.dart' show Json;
import 'model_auth.dart';
import 'model_provider_env.dart';
import 'provider_data.dart';

/// Basic credential management stays available independently of load balancing.
/// Reuses the same permission checks, masked edit form and credential operations
/// as the provider's existing authorization menu.
class ModelCredentialsAction extends StatefulWidget {
  const ModelCredentialsAction({super.key, required this.provider, required this.model});

  final Json provider;
  final ModelItem model;

  @override
  State<ModelCredentialsAction> createState() => _ModelCredentialsActionState();
}

class _ModelCredentialsActionState extends State<ModelCredentialsAction> {
  bool _loading = false, _open = false;
  Json? _detail;
  List<Credential> _credentials = const [];
  Credential? _selected;

  bool get _custom => widget.model.fetchFrom == ConfigurationMethodEnum.customizableModel;

  Future<void> _load(ModelProviderEnv env) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final detail = await env.models.loadProviderDetail(widget.provider.providerName);
      if (!mounted) return;
      if (detail == null) {
        toast.error(env.language.startsWith('zh') ? '无法读取供应商配置，请重试。' : 'Could not load provider settings. Try again.');
        return;
      }
      List<Credential> credentials;
      Credential? selected;
      if (_custom) {
        final data = await withRequestToast(
          () => env.models.credentials.modelCredentials(
            widget.provider.providerName,
            model: widget.model.model,
            modelType: widget.model.modelType,
          ),
        );
        credentials = [for (final c in data['available_credentials'] as List? ?? const []) Credential.fromJson(c)];
        final current = data['current_credential_id'];
        selected = credentials.where((c) => c.credentialId == current).firstOrNull;
      } else {
        credentials = detail.availableCredentials;
        selected = credentials.where((c) => c.credentialId == detail.currentCredentialId).firstOrNull;
      }
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _credentials = credentials;
        _selected = selected;
        _open = true;
      });
    } on Object {
      // withRequestToast already presents a failed credential read. Keep the
      // trigger available so a fresh click can retry.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final label = env.language.startsWith('zh') ? '配置模型' : 'Configure model';
    Widget trigger(bool open, VoidCallback close) => DifyTooltip(
      content: DifyTextLine(label),
      child: DifyIconButton(
        key: ValueKey('model-configure-${widget.model.model}'),
        label: '$label ${widget.model.model}',
        icon: const RemixIcon('equalizer-2-line', size: 16),
        disabled: _loading,
        onPressed: open ? close : () => unawaited(_load(env)),
      ),
    );
    if (_detail == null) return trigger(false, () {});
    return Authorized(
      provider: _detail!,
      configurationMethod: _custom
          ? ConfigurationMethodEnum.customizableModel
          : ConfigurationMethodEnum.predefinedModel,
      fixedFields: _custom ? (modelName: widget.model.model, modelType: widget.model.modelType) : null,
      isModelCredential: _custom,
      mode: _custom ? ModelModalModeEnum.configModelCredential : ModelModalModeEnum.configProviderCredential,
      items: [
        (
          title: null,
          model: _custom ? (model: widget.model.model, modelType: widget.model.modelType) : null,
          credentials: _credentials,
          selectedCredential: _selected,
        ),
      ],
      popupTitle: widget.model.model,
      popupWidth: (MediaQuery.sizeOf(context).width - 32).clamp(200, 320).toDouble(),
      placement: DifyPlacement.bottomEnd,
      disableDeleteButShowAction: _custom,
      isOpen: _open,
      onOpenChange: (open) => setState(() => _open = open),
      renderTrigger: trigger,
    );
  }
}
