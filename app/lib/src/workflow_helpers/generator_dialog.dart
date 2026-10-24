import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../workflow/model_catalog.dart';
import '../cards/provider_icon_image.dart';
import '../workflow_editor/node_panel/bodies/llm/model_selector.dart';

String _w(String key) => DifyI18n.tr('workflow', key);

Future<HelperJson?> showHelperGenerator(
  BuildContext context, {
  required HelpersApi api,
  required String kind,
  required HelperJson parameters,
  String? modelLabel,
  List<ProviderWithModels> models = const [],
  bool Function()? unchanged,
  String? warning,
  Future<void> Function(HelperJson proposal)? apply,
}) => showDifyDialog<HelperJson>(
  context,
  builder: (_) => ProviderIconScope(
    source: ProviderIconScope.of(context),
    child: HelperGeneratorDialog(
      api: api,
      kind: kind,
      parameters: parameters,
      modelLabel: modelLabel,
      models: models,
      unchanged: unchanged,
      warning: warning,
      apply: apply,
    ),
  ),
);

/// Shared proposal dialog: instructions and failures survive retries, a proposal never edits until Apply.
class HelperGeneratorDialog extends StatefulWidget {
  const HelperGeneratorDialog({
    super.key,
    required this.api,
    required this.kind,
    required this.parameters,
    this.modelLabel,
    this.models = const [],
    this.unchanged,
    this.warning,
    this.apply,
  });
  final HelpersApi api;
  final String kind;
  final HelperJson parameters;
  final String? modelLabel, warning;
  final List<ProviderWithModels> models;
  final bool Function()? unchanged;
  final Future<void> Function(HelperJson proposal)? apply;
  @override
  State<HelperGeneratorDialog> createState() => _HelperGeneratorDialogState();
}

class _HelperGeneratorDialogState extends State<HelperGeneratorDialog> {
  String _instruction = '', _error = '';
  late Map<String, Object?>? _model = widget.parameters['model_config'] as Map<String, Object?>?;
  HelperJson? _proposal;
  HelperCancellation? _cancellation;
  bool _busy = false;
  DefaultModel? get _choice {
    final provider = _model?['provider'], name = _model?['name'];
    return provider is String && provider.isNotEmpty && name is String && name.isNotEmpty
        ? (provider: provider, model: name)
        : null;
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_busy || _instruction.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = '';
      _proposal = null;
    });
    final cancellation = _cancellation = HelperCancellation();
    try {
      final result = await widget.api.generate(widget.kind, {
        ...widget.parameters,
        'instruction': _instruction,
        'model_config': ?_model,
      }, cancellation: cancellation);
      if (mounted && _cancellation == cancellation) setState(() => _proposal = result);
    } on Object catch (e) {
      if (mounted && _cancellation == cancellation) setState(() => _error = '$e');
    } finally {
      if (mounted && _cancellation == cancellation) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    if (_proposal == null || _busy) return;
    if (widget.unchanged?.call() == false) {
      setState(
        () => _error = "${_w('workflowGenerator.reload')}: ${_w('workflowGenerator.refineDescription')}",
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await widget.apply?.call(_proposal!);
      if (mounted) Navigator.of(context).pop(_proposal);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _proposal;
    final preview = p == null
        ? ''
        : p['prompt'] ??
              p['code'] ??
              p['modified'] ??
              p['output'] ??
              const JsonEncoder.withIndent('  ').convert(p['graph'] ?? p);
    return DifyContentDialog(
      title: DifyTextLine(_w('workflowGenerator.generate')),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .65),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              if (widget.models.isNotEmpty)
                ModelSelector(
                  models: widget.models,
                  disabled: _busy,
                  value: _choice,
                  onChange: (choice) => setState(() {
                    _model = {'provider': choice.provider, 'name': choice.model, 'mode': 'chat'};
                    _proposal = null;
                  }),
                )
              else if (widget.modelLabel case final model?)
                DifyTextLine(model),
              DifyTextarea(
                key: const Key('helper-instruction'),
                value: _instruction,
                disabled: _busy,
                maxLength: 10000,
                semanticLabel: _w('workflowGenerator.instruction'),
                onChanged: (s) => setState(() => _instruction = s),
              ),
              if (widget.warning case final warning?) DifyTextLine(warning),
              if (_error.isNotEmpty)
                DifyText(
                  _error,
                  DifyType.systemSmRegular,
                  color: DifyColors.textDestructive,
                  key: const Key('helper-error'),
                ),
              if (p != null) DifySelectableText('$preview', key: const Key('helper-proposal')),
            ],
          ),
        ),
      ),
      actions: [
        DifyButton(
          variant: DifyButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: DifyTextLine(_w('workflowGenerator.cancel')),
        ),
        DifyButton(
          key: const Key('helper-generate'),
          disabled: _busy || _instruction.trim().isEmpty,
          loading: _busy && p == null,
          onPressed: _generate,
          child: DifyTextLine(_w('workflowGenerator.generate')),
        ),
        DifyButton(
          key: const Key('helper-apply'),
          variant: DifyButtonVariant.primary,
          disabled: _busy || p == null,
          onPressed: _apply,
          child: DifyTextLine(_w('workflowGenerator.studioApply')),
        ),
      ],
    );
  }
}
