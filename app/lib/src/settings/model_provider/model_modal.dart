/// model-modal/index.tsx: the credential modal (the modal context's `setShowModelModal`, useModelModalHandler):
/// adding or editing a provider's API key, adding a custom model with its credential, adding a model back to the
/// list with an existing or a new credential, and editing a custom model's credential. The forms are base/form's
/// AuthForm over the provider's credential form schemas; untouched secrets are sent as `[__HIDDEN__]`.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../cards/model_chip.dart' show ModelIcon;
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../open_url.dart';
import '../../workflow/model_catalog.dart';
import '../../workflow/workspace_models.dart' show Json;
import '../../workflow_editor/panel_fields/controls.dart' show DifyBadge;
import '../../workflow_editor/panel_fields/dialog.dart';
import '../form/base_form.dart';
import 'model_auth.dart';
import 'model_provider_env.dart';
import 'provider_data.dart';

String _t(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

/// useModelModalHandler: opens the credential modal; [onSave] gets the form's values once it saved.
Future<void> showModelModal(
  BuildContext context, {
  required ModelProviderEnv env,
  required Json provider,
  required String configurationMethod,
  CustomModelFixedFields? fixedFields,
  bool isModelCredential = false,
  Credential? credential,
  CustomModel? model,
  ModelModalModeEnum? mode,
  void Function(Map<String, Object?>? formValues)? onSave,
}) => showDifyDialog<void>(
  context,
  builder: (dialogContext) => ModelProviderScope(
    env: env,
    child: ModelModal(
      provider: provider,
      configurateMethod: configurationMethod,
      fixedFields: fixedFields,
      isModelCredential: isModelCredential,
      credential: credential,
      model: model,
      mode: mode ?? ModelModalModeEnum.configProviderCredential,
      onCancel: () => Navigator.of(dialogContext).pop(),
      onSave: (values) {
        onSave?.call(values);
        Navigator.of(dialogContext).pop();
      },
    ),
  ),
);

/// ModelModal: `w-160 overflow-hidden p-0`: the close button (`top-5 right-5`), the header (`p-6 pb-3`: the title, the
/// description for provider API keys, the provider or model), the forms (`px-6 py-3`, scrolling), the footer (`p-6
/// pt-5`: the provider's help link; Remove for an existing credential, Cancel, Save / Add) and, for new credentials,
/// the "encrypted" note.
class ModelModal extends StatefulWidget {
  const ModelModal({
    super.key,
    required this.provider,
    required this.configurateMethod,
    required this.onCancel,
    required this.onSave,
    this.fixedFields,
    this.model,
    this.credential,
    this.isModelCredential = false,
    this.mode = ModelModalModeEnum.configProviderCredential,
  });

  final Json provider;
  final String configurateMethod;
  final CustomModelFixedFields? fixedFields;
  final VoidCallback onCancel;
  final void Function(Map<String, Object?> formValues) onSave;
  final CustomModel? model;
  final Credential? credential;
  final bool isModelCredential;
  final ModelModalModeEnum mode;

  @override
  State<ModelModal> createState() => _ModelModalState();
}

class _ModelModalState extends State<ModelModal> {
  final _form1 = GlobalKey<BaseFormState>();
  final _form2 = GlobalKey<BaseFormState>();
  SelectedCredential? _selectedCredential;
  ModelAuth? _auth;

  Future<Json>? _loading;
  bool _isLoading = false;
  Json _credentialData = const {};

  bool get _predefined => widget.configurateMethod == ConfigurationMethodEnum.predefinedModel;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loading ??= _load();
  }

  Future<Json> _load() async {
    final request = loadCredentialData(
      ModelProviderScope.of(context),
      widget.provider,
      providerFormSchemaPredefined: _predefined,
      isModelCredential: widget.isModelCredential,
      credential: widget.credential,
      model: widget.model,
    );
    if (request == null) return const {};
    setState(() => _isLoading = true);
    try {
      final data = await request;
      if (mounted) setState(() => _credentialData = data);
      return data;
    } on Object {
      return const {};
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  ModelAuth _authOf(ModelProviderEnv env) => _auth ??= ModelAuth(
    env: env,
    provider: widget.provider,
    configurationMethod: widget.configurateMethod,
    fixedFields: widget.fixedFields,
    isModelCredential: widget.isModelCredential,
    mode: widget.mode,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  Map<String, Object?>? get _storedCredentials {
    final c = _credentialData['credentials'];
    return c is Map ? {for (final e in c.entries) '${e.key}': e.value} : null;
  }

  List<Credential> get _availableCredentials => [
    for (final c in (_credentialData['available_credentials'] as List? ?? const [])) Credential.fromJson(c),
  ];

  Future<void> _save(ModelProviderEnv env, ModelAuth auth) async {
    final w = widget;
    final selected = _selectedCredential;
    if (w.mode == ModelModalModeEnum.addCustomModelToModelList && selected != null && !selected.addNewCredential) {
      if (!env.canUseCredential) return;
      unawaited(auth.handleActiveCredential(selected.credential, w.model));
      w.onCancel();
      return;
    }
    final canSubmit = w.credential != null ? env.canManageCredential : env.canCreateCredential;
    if (!canSubmit) return;

    var nameAndTypeOk = true;
    var nameAndType = <String, Object?>{};
    if (w.mode == ModelModalModeEnum.configCustomModel) {
      final r = _form1.currentState?.getFormValues() ?? (values: const <String, Object?>{}, isCheckValidated: false);
      nameAndTypeOk = r.isCheckValidated;
      nameAndType = r.values;
    }
    if (w.mode == ModelModalModeEnum.configModelCredential ||
        (w.mode == ModelModalModeEnum.addCustomModelToModelList && (selected?.addNewCredential ?? false))) {
      final context =
          w.model ??
          (w.fixedFields == null ? null : (model: w.fixedFields!.modelName, modelType: w.fixedFields!.modelType));
      if (context == null) return;
      nameAndType = {'__model_name': context.model, '__model_type': context.modelType};
    }
    final r =
        _form2.currentState?.getFormValues(needTransformWhenSecretFieldIsPristine: true) ??
        (values: const <String, Object?>{}, isCheckValidated: false);
    if (!r.isCheckValidated || !nameAndTypeOk) return;
    final values = r.values;
    final modelName = nameAndType['__model_name'];
    final modelType = nameAndType['__model_type'];
    final rest = {...values}..remove('__authorization_name__');
    final name = values['__authorization_name__'] as String?;
    final saveModelCredential =
        w.mode == ModelModalModeEnum.configCustomModel ||
        w.mode == ModelModalModeEnum.configModelCredential ||
        (w.mode == ModelModalModeEnum.addCustomModelToModelList && (selected?.addNewCredential ?? false));
    final bool ok;
    if (saveModelCredential) {
      if (modelName is! String || modelName.isEmpty || modelType is! String || modelType.isEmpty) return;
      ok = await auth.handleSaveCredential(
        credentialId: w.credential?.credentialId,
        credentials: rest,
        name: name,
        model: modelName,
        modelType: modelType,
      );
    } else {
      ok = await auth.handleSaveCredential(credentialId: w.credential?.credentialId, credentials: rest, name: name);
    }
    if (ok) w.onSave(values);
  }

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final auth = _authOf(env);
    final w = widget;
    final provider = w.provider;
    final language = env.language;
    final forms = modelFormSchemas(
      provider,
      providerFormSchemaPredefined: _predefined,
      credentials: _storedCredentials,
      credential: w.credential,
      model: w.model,
    );
    final stored = _storedCredentials ?? const {};
    final isEditMode =
        w.credential != null &&
        stored.keys.any((k) {
          if (k == '__model_name' || k == '__model_type') return false;
          final v = forms.formValues[k];
          return v != null && v != '' && v != false && v != 0;
        }) &&
        env.canManageCredential;
    final selected = _selectedCredential;
    final isOfficialOpenAI = provider.providerName == 'langgenius/openai/openai' || provider.providerName == 'openai';

    final title = switch (w.mode) {
      ModelModalModeEnum.configCustomModel || ModelModalModeEnum.addCustomModelToModelList => _t(
        'modelProvider.auth.addModel',
      ),
      ModelModalModeEnum.configModelCredential =>
        w.credential != null
            ? _t('modelProvider.auth.editModelCredential')
            : _t('modelProvider.auth.addModelCredential'),
      _ => _t('modelProvider.auth.apiKeyModal.title'),
    };
    Widget? modelRow;
    if (w.mode == ModelModalModeEnum.configCustomModel) {
      modelRow = Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SizedBox.square(
              dimension: 16,
              child: FittedBox(
                child: ModelIcon(provider: provider.providerName, iconSmall: provider.iconSmall, language: language),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              renderI18nObject(provider.label, language),
              style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary),
            ),
          ),
        ],
      );
    } else if (w.model != null &&
        (w.mode == ModelModalModeEnum.configModelCredential ||
            w.mode == ModelModalModeEnum.addCustomModelToModelList)) {
      modelRow = Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: SizedBox.square(
              dimension: 16,
              child: FittedBox(
                child: ModelIcon(
                  provider: provider.providerName,
                  iconSmall: provider.iconSmall,
                  modelName: w.model!.model,
                  language: language,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(w.model!.model, style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary)),
          ),
          DifyBadge(w.model!.modelType, uppercase: false),
        ],
      );
    }
    final showCredentialLabel =
        w.mode == ModelModalModeEnum.configCustomModel ||
        (w.mode == ModelModalModeEnum.addCustomModelToModelList && (selected?.addNewCredential ?? false));
    final showCredentialForm =
        w.mode != ModelModalModeEnum.addCustomModelToModelList || (selected?.addNewCredential ?? false);
    final saveText =
        w.mode == ModelModalModeEnum.addCustomModelToModelList || w.mode == ModelModalModeEnum.configCustomModel
        ? _t('operation.add')
        : _t('operation.save');
    final canSave =
        w.mode == ModelModalModeEnum.addCustomModelToModelList && selected != null && !selected.addNewCredential
        ? env.canUseCredential
        : w.credential != null
        ? env.canManageCredential
        : env.canCreateCredential;
    final notAllowCustomCredential = !provider.allowCustomToken;

    final help = provider.help;
    final helpTitle = help?['title'] is Map ? help!['title']! as Map : null;
    final helpUrl = help?['url'] is Map ? help!['url']! as Map : null;
    final hasHelp = help != null && (helpTitle != null || helpUrl != null);
    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    final helpHref = str(helpUrl?[language]) ?? str(helpUrl?['en_US']);
    final helpText =
        str(helpTitle?[language]) ??
        str(helpUrl?[language]) ??
        str(helpTitle?['en_US']) ??
        str(helpUrl?['en_US']) ??
        '';

    final credentialSchemas = [
      for (final s in forms.formSchemas)
        s.copyWith(
          showRadioUI: s.type == FormTypeEnum.radio,
          description: isOfficialOpenAI && s.name == 'api_protocol'
              ? _t('modelProvider.auth.openAIResponsesAPITip')
              : null,
        ),
    ];

    return DifyDialogSurface(
      label: title,
      width: 640,
      bordered: true,
      child: Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary)),
                    if (_predefined)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _t('modelProvider.auth.apiKeyModal.desc'),
                          style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                        ),
                      ),
                    if (modelRow != null) Padding(padding: const EdgeInsets.only(top: 8), child: modelRow),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (w.mode == ModelModalModeEnum.configCustomModel)
                        AuthForm(
                          formKey: _form1,
                          formSchemas: forms.modelNameAndTypeFormSchemas,
                          defaultValues: forms.modelNameAndTypeFormValues,
                          onChange: (field, value) => _form2.currentState?.getForm().setFieldValue(field, value),
                        ),
                      if (w.mode == ModelModalModeEnum.addCustomModelToModelList)
                        CredentialSelector(
                          credentials: _availableCredentials,
                          onSelect: (c) => setState(() => _selectedCredential = c),
                          selectedCredential: selected,
                          disabled: _isLoading,
                          notAllowAddNewCredential: notAllowCustomCredential || !env.canCreateCredential,
                        ),
                      if (showCredentialLabel)
                        Padding(
                          padding: const EdgeInsets.only(top: 24, bottom: 12),
                          child: Row(
                            children: [
                              Text(
                                difyTransform(
                                  DifyType.systemXsMediumUppercase,
                                  _t('modelProvider.auth.modelCredential'),
                                ),
                                style: difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary),
                              ),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: SizedBox(
                                  height: 1,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          DifyColors.dividerRegular,
                                          DifyColors.backgroundGradientMaskTransparent,
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_isLoading)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Center(
                            child: Semantics(
                              container: true,
                              liveRegion: true,
                              label: _t('loading'),
                              child: const DifySpinner(size: 16, color: DifyColors.textTertiary),
                            ),
                          ),
                        ),
                      if (!_isLoading && showCredentialForm)
                        AuthForm(
                          formKey: _form2,
                          formSchemas: credentialSchemas,
                          defaultValues: forms.formValues,
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(
                      child: hasHelp
                          ? Align(
                              alignment: AlignmentDirectional.topStart,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: _HelpLink(text: helpText, url: helpHref),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (isEditMode)
                              DifyButton(
                                key: const ValueKey('model-modal-remove'),
                                variant: DifyButtonVariant.primary,
                                tone: DifyButtonTone.destructive,
                                onPressed: () => unawaited(_remove(context, auth)),
                                child: Text(_t('operation.remove')),
                              ),
                            DifyButton(
                              key: const ValueKey('model-modal-cancel'),
                              onPressed: w.onCancel,
                              child: Text(_t('operation.cancel')),
                            ),
                            DifyButton(
                              key: const ValueKey('model-modal-save'),
                              variant: DifyButtonVariant.primary,
                              disabled: _isLoading || auth.doingAction || !canSave,
                              onPressed: () => unawaited(_save(env, auth)),
                              child: Text(saveText),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (w.mode == ModelModalModeEnum.configCustomModel ||
                  w.mode == ModelModalModeEnum.configProviderCredential)
                const _EncryptedNote(),
            ],
          ),
          Positioned(
            top: 20,
            right: 20,
            child: DifyIconButton(
              key: const ValueKey('model-modal-close'),
              label: _t('operation.close'),
              size: DifyIconButtonSize.lg,
              icon: const RemixIcon('close-line', size: 16),
              onPressed: w.onCancel,
            ),
          ),
        ],
      ),
    );
  }

  /// Remove: confirms, deletes, and closes the modal.
  Future<void> _remove(BuildContext context, ModelAuth auth) async {
    final ok = await auth.confirmDelete(context, credential: widget.credential, model: widget.model);
    if (ok && mounted) widget.onCancel();
  }
}

/// The provider's help link: `mt-2 inline-block system-xs-regular text-text-accent` and `LinkExternal02` (12 px);
/// nothing happens without a URL.
class _HelpLink extends StatelessWidget {
  const _HelpLink({required this.text, this.url});
  final String text;
  final String? url;

  @override
  Widget build(BuildContext context) => Semantics(
    link: url != null,
    label: text,
    linkUrl: url == null ? null : Uri.tryParse(url!),
    excludeSemantics: true,
    child: GestureDetector(
      key: const ValueKey('model-modal-help'),
      onTap: url == null ? null : () => openExternalUrl(url!),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Text.rich(
          TextSpan(
            text: text,
            style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textAccent),
            children: const [
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: DifyIcon('vender/line/general/link-external-02', size: 12, color: DifyColors.textAccent),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The note under new credentials: `border-t-[0.5px] border-t-divider-regular`, `rounded-b-2xl
/// bg-background-section-burn py-3 text-xs text-text-tertiary`, the lock (`Lock01 size-3`) and "encrypted and stored
/// using …". dify-sf's server encrypts with AES-256-GCM (Dify names its PKCS1_OAEP).
class _EncryptedNote extends StatelessWidget {
  const _EncryptedNote();

  @override
  Widget build(BuildContext context) {
    final style = difyTextStyle(
      DifyType.systemXsRegular,
      DifyColors.textTertiary,
    ).copyWith(fontSize: 12, height: 16 / 12);
    return Container(
      decoration: BoxDecoration(
        color: DifyColors.backgroundSectionBurn,
        border: Border(
          top: BorderSide(color: DifyColors.dividerRegular, width: Css.hairline),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: DifyIcon('vender/solid/security/lock-01', size: 12, color: DifyColors.textTertiary),
          ),
          Flexible(
            child: Text.rich(
              TextSpan(
                style: style,
                children: [
                  TextSpan(text: _t('modelProvider.encrypted.front')),
                  TextSpan(
                    text: ' AES-256-GCM',
                    style: style.copyWith(color: DifyColors.textAccent),
                  ),
                  TextSpan(text: _t('modelProvider.encrypted.back')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
