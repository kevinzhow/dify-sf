/// Dify workflow-tool drawer: configure the immutable published version, then refresh the catalog.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../settings/form/base_form.dart';

String _t(String key) => DifyI18n.tr('tools', 'createTool.$key');
String _c(String key) => DifyI18n.tr('common', 'operation.$key');

Future<bool?> showWorkflowToolPublisher(
  BuildContext context, {
  required ToolsApi api,
  required String appId,
  required String appName,
  ToolJson? existing,
}) => showDifyDrawer<bool>(
  context,
  insets: const EdgeInsets.all(8),
  maxWidth: 640,
  dismissible: false,
  builder: (context, close) => WorkflowToolPublisher(
    api: api,
    appId: appId,
    appName: appName,
    existing: existing,
    close: close,
  ),
);

class WorkflowToolPublisher extends StatefulWidget {
  const WorkflowToolPublisher({
    super.key,
    required this.api,
    required this.appId,
    required this.appName,
    this.existing,
    required this.close,
  });
  final ToolsApi api;
  final String appId, appName;
  final ToolJson? existing;
  final VoidCallback close;
  @override
  State<WorkflowToolPublisher> createState() => _WorkflowToolPublisherState();
}

class _WorkflowToolPublisherState extends State<WorkflowToolPublisher> {
  final _form = GlobalKey<BaseFormState>();
  ToolJson? _preview;
  Object? _loadError, _saveError;
  bool _saving = false, _confirmDelete = false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final preview = await widget.api.workflowToolPreview(widget.appId);
      if (mounted) setState(() => _preview = preview);
    } on Object catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  String _label(Object? value, String fallback) =>
      value is Map ? '${value['en_US'] ?? fallback}' : '${value ?? fallback}';
  List<ToolJson> get _parameters => [
    for (final p in (_preview?['parameters'] as List? ?? [])) (p as Map).cast<String, Object?>(),
  ];
  ToolJson get _definition {
    final tools = widget.existing?['tools'] as List?;
    return tools?.isNotEmpty == true ? (tools!.first as Map).cast<String, Object?>() : {};
  }

  Future<void> _save({bool delete = false}) async {
    final values = _form.currentState?.getFormValues();
    if (_saving || (!delete && (values == null || !values.isCheckValidated))) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final id = widget.existing?['id'] as String?;
      if (delete) {
        await widget.api.deleteWorkflowTool(id!);
      } else {
        final fields = values!.values;
        await widget.api.saveWorkflowTool({
          'workflow_app_id': widget.appId,
          'name': fields['name'],
          'label': fields['label'],
          'description': fields['description'],
          'icon': _definition['icon'],
          'privacy_policy': _definition['privacy_policy'] ?? '',
          'parameters': [
            for (final p in _parameters)
              {
                'name': p['name'],
                'description': fields['description:${p['name']}'],
                'form': fields['form:${p['name']}'],
              },
          ],
        }, id: id);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (mounted) setState(() => _saveError = error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final old = _definition;
    final oldParams = {for (final p in (old['parameters'] as List? ?? [])) (p as Map)['name']: p};
    final title = DifyI18n.tr('workflow', 'common.workflowAsTool');
    return DifyDrawerPopup(
      label: title,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 20, 16),
            child: Row(
              children: [
                Expanded(
                  child: DifyTextLine(title, style: difyTextStyle(DifyType.systemXlSemibold, DifyColors.textPrimary)),
                ),
                DifyDrawerCloseButton(onPressed: _saving ? null : widget.close, label: _c('close')),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_loadError != null) ...[
                    DifyTextLine('$_loadError'),
                    DifyButton(onPressed: _load, child: DifyTextLine(_c('retry'))),
                  ] else if (_preview == null)
                    const Center(child: DifySpinner())
                  else ...[
                    AuthForm(
                      formKey: _form,
                      disabled: _saving,
                      defaultValues: {
                        'name': old['name'] ?? '',
                        'label': _label(old['label'], widget.appName),
                        'description': _label(old['description'], ''),
                        for (final p in _parameters)
                          'description:${p['name']}': oldParams[p['name']]?['llm_description'] ?? '',
                        for (final p in _parameters) 'form:${p['name']}': oldParams[p['name']]?['form'] ?? 'llm',
                      },
                      formSchemas: [
                        FormSchema(type: FormTypeEnum.textInput, name: 'label', label: _t('name'), required: true),
                        FormSchema(
                          type: FormTypeEnum.textInput,
                          name: 'name',
                          label: _t('nameForToolCall'),
                          required: true,
                          description: _t('nameForToolCallTip'),
                          validators: FieldValidators(
                            onChange: (v) => v is String && v.length <= 64 && RegExp(r'^[A-Za-z0-9_]+$').hasMatch(v)
                                ? null
                                : _t('nameForToolCallTip'),
                          ),
                        ),
                        FormSchema(
                          type: FormTypeEnum.textInput,
                          name: 'description',
                          label: _t('description'),
                          required: true,
                        ),
                        for (final p in _parameters) ...[
                          FormSchema(
                            type: FormTypeEnum.textInput,
                            name: 'description:${p['name']}',
                            label: '${p['name']} — ${_t('toolInput.description')}',
                          ),
                          FormSchema(
                            type: FormTypeEnum.select,
                            name: 'form:${p['name']}',
                            label: _t('toolInput.method'),
                            options: [
                              FormOption(value: 'llm', label: _t('toolInput.methodParameter')),
                              FormOption(value: 'form', label: _t('toolInput.methodSetting')),
                            ],
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 24),
                    DifyTextLine(
                      _t('toolOutput.title'),
                      style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textPrimary),
                    ),
                    for (final output in (_preview!['outputs'] as List? ?? []))
                      DifyTextLine('${(output as Map)['name']} · ${output['type']}'),
                  ],
                  if (_saveError != null)
                    DifyTextLine(
                      '$_saveError',
                      style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textDestructive),
                    ),
                  if (_confirmDelete) DifyTextLine(_t('deleteToolConfirmContent')),
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
                if (widget.existing != null)
                  DifyButton(
                    disabled: _saving,
                    onPressed: () {
                      if (_confirmDelete) {
                        unawaited(_save(delete: true));
                      } else {
                        setState(() => _confirmDelete = true);
                      }
                    },
                    child: DifyTextLine(_confirmDelete ? _t('deleteToolConfirmTitle') : _c('delete')),
                  ),
                DifyButton(disabled: _saving, onPressed: widget.close, child: DifyTextLine(_c('cancel'))),
                DifyButton(
                  disabled: _preview == null,
                  loading: _saving,
                  variant: DifyButtonVariant.primary,
                  onPressed: _save,
                  child: DifyTextLine(_c('save')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
