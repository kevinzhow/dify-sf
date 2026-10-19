/// model-auth: the credential operations (hooks/use-auth.ts, use-auth-service.ts, use-credential-data.ts,
/// use-model-form-schemas.ts) and the credential widgets: CredentialItem and AuthorizedItem (authorized/), Authorized
/// (the credential popover), AddCustomModel, ManageCustomModelCredentials and CredentialSelector. Load balancing
/// (AddCredentialInLoadBalancing, SwitchCredentialInLoadBalancing, ConfigModel) is not part of dify-sf.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../cards/model_chip.dart' show ModelIcon;
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/model_catalog.dart';
import '../../workflow/workspace_models.dart';
import '../../workflow_editor/node_panel/bodies/llm/model_selector.dart' show StatusDot, StatusDotKind;
import '../../workflow_editor/panel_fields/controls.dart' show DifyBadge;
import '../form/base_form.dart';
import '../settings_kit.dart' show showSettingsAlert;
import 'model_modal.dart';
import 'model_provider_env.dart';
import 'provider_data.dart';

String _t(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

// ---- useAuth -------------------------------------------------------------------------------------------------------

/// useAuth: the credential operations of [provider] (provider credentials, or with [isModelCredential] a custom
/// model's), with Dify's toasts and refreshes. [onChanged] repaints the owner while an action runs.
class ModelAuth {
  ModelAuth({
    required this.env,
    required this.provider,
    required this.configurationMethod,
    this.fixedFields,
    this.isModelCredential = false,
    this.onUpdate,
    this.onRemove,
    this.mode,
    this.onChanged,
  });

  final ModelProviderEnv env;
  final Json provider;
  final String configurationMethod;
  final CustomModelFixedFields? fixedFields;
  final bool isModelCredential;

  /// `onUpdate(newPayload, formValues)`: after the credential modal saved.
  final void Function(Map<String, Object?>? formValues)? onUpdate;

  /// After a deletion, with the deleted credential's id ('' for a model).
  final void Function(String credentialId)? onRemove;
  final ModelModalModeEnum? mode;
  final VoidCallback? onChanged;

  String? _deleteCredentialId;
  CustomModel? _deleteModel;
  bool _doingAction = false;

  String? get deleteCredentialId => _deleteCredentialId;
  CustomModel? get deleteModel => _deleteModel;
  bool get doingAction => _doingAction;

  ModelProvidersApi get _api => env.models.credentials;
  String get _name => provider.providerName;

  void _setDoing(bool doing) {
    _doingAction = doing;
    onChanged?.call();
  }

  /// `resolveModelContext`: [model], else the fixed fields' model.
  CustomModel? resolveModelContext([CustomModel? model]) {
    if (model != null) return model;
    final f = fixedFields;
    return f == null ? null : (model: f.modelName, modelType: f.modelType);
  }

  void openConfirmDelete({Credential? credential, CustomModel? model}) {
    if (credential != null) _deleteCredentialId = credential.credentialId;
    if (model != null) _deleteModel = model;
    onChanged?.call();
  }

  void closeConfirmDelete() {
    _deleteCredentialId = null;
    _deleteModel = null;
    onChanged?.call();
  }

  /// Opens the confirmation (Dify's AlertDialog shown while a deletion is pending) for [credential] / [model];
  /// confirming runs [handleConfirmDelete]. [confirmLabel]: "Confirm" by default.
  Future<bool> confirmDelete(
    BuildContext context, {
    Credential? credential,
    CustomModel? model,
    String? confirmLabel,
    bool lockCancelWhileBusy = false,
  }) async {
    openConfirmDelete(credential: credential, model: model);
    final ok = await showSettingsAlert(
      context,
      title: _t('modelProvider.confirmDelete'),
      confirmLabel: confirmLabel,
      lockCancelWhileBusy: lockCancelWhileBusy,
      onConfirm: () async {
        if (!await handleConfirmDelete()) throw StateError('not deleted');
      },
    );
    if (!ok) closeConfirmDelete();
    return ok;
  }

  /// `handleActiveCredential`: makes [credential] current (for [model] or the fixed model when this is about model
  /// credentials, else for the provider).
  Future<bool> handleActiveCredential(Credential credential, [CustomModel? model]) async {
    if (_doingAction) return false;
    _setDoing(true);
    try {
      final context = model ?? (isModelCredential ? resolveModelContext() : null);
      await withRequestToast(
        () => context != null
            ? _api.switchModelCredential(
                _name,
                model: context.model,
                modelType: context.modelType,
                credentialId: credential.credentialId,
              )
            : _api.switchProviderCredential(_name, credentialId: credential.credentialId),
      );
      toast.success(_t('api.actionSuccess'));
      unawaited(env.models.refreshModel(provider, refreshModelList: true));
      return true;
    } on Object {
      return false;
    } finally {
      _setDoing(false);
    }
  }

  /// `handleConfirmDelete`: deletes the pending credential (or, without one, removes the pending custom model).
  Future<bool> handleConfirmDelete() async {
    if (_doingAction) return false;
    final credentialId = _deleteCredentialId;
    final model = _deleteModel;
    if (credentialId == null && model == null) {
      closeConfirmDelete();
      return false;
    }
    _setDoing(true);
    try {
      if (credentialId != null) {
        if (isModelCredential) {
          final context = resolveModelContext(model);
          if (context == null) return false;
          await withRequestToast(
            () => _api.deleteModelCredential(
              _name,
              model: context.model,
              modelType: context.modelType,
              credentialId: credentialId,
            ),
          );
        } else {
          await withRequestToast(() => _api.deleteProviderCredential(_name, credentialId: credentialId));
        }
      } else if (model != null) {
        await withRequestToast(() => _api.removeCustomModel(_name, model: model.model, modelType: model.modelType));
      }
      toast.success(_t('api.actionSuccess'));
      unawaited(env.models.refreshModel(provider, refreshModelList: true));
      onRemove?.call(credentialId ?? '');
      closeConfirmDelete();
      return true;
    } on Object {
      return false;
    } finally {
      _setDoing(false);
    }
  }

  /// `handleSaveCredential`: adds (no [credentialId]) or edits a credential; with [model] and [modelType], a custom
  /// model's.
  Future<bool> handleSaveCredential({
    String? credentialId,
    required Map<String, Object?> credentials,
    String? name,
    String? model,
    String? modelType,
  }) async {
    if (_doingAction) return false;
    _setDoing(true);
    try {
      final forModel = isModelCredential;
      final n = name == null || name.isEmpty ? null : name;
      await withRequestToast(() {
        if (forModel) {
          return credentialId != null
              ? _api.updateModelCredential(
                  _name,
                  model: model ?? '',
                  modelType: modelType ?? '',
                  credentialId: credentialId,
                  credentials: credentials,
                  name: n,
                )
              : _api.createModelCredential(
                  _name,
                  model: model ?? '',
                  modelType: modelType ?? '',
                  credentials: credentials,
                  name: n,
                );
        }
        return credentialId != null
            ? _api.updateProviderCredential(_name, credentialId: credentialId, credentials: credentials, name: n)
            : _api.createProviderCredential(_name, credentials: credentials, name: n);
      });
      toast.success(_t('actionMsg.modifiedSuccessfully'));
      unawaited(env.models.refreshModel(provider, refreshModelList: credentialId == null));
      return true;
    } on Object {
      return false;
    } finally {
      _setDoing(false);
    }
  }

  /// `handleOpenModal`: the credential modal for [credential] (none: a new one) of [model].
  void handleOpenModal(BuildContext context, {Credential? credential, CustomModel? model}) => unawaited(
    showModelModal(
      context,
      env: env,
      provider: provider,
      configurationMethod: configurationMethod,
      fixedFields: fixedFields,
      isModelCredential: isModelCredential,
      credential: credential,
      model: model,
      mode: mode,
      onSave: onUpdate,
    ),
  );
}

// ---- useModelFormSchemas / useCredentialData -----------------------------------------------------------------------

/// useModelFormSchemas: the credential form (the authorization name first, then the provider's or the custom
/// model's credential schemas), its values (defaults, then the credential's name and values, then the model), and
/// for custom models the model name and type form.
({
  List<FormSchema> formSchemas,
  Map<String, Object?> formValues,
  List<FormSchema> modelNameAndTypeFormSchemas,
  Map<String, Object?> modelNameAndTypeFormValues,
})
modelFormSchemas(
  Json provider, {
  required bool providerFormSchemaPredefined,
  Map<String, Object?>? credentials,
  Credential? credential,
  CustomModel? model,
}) {
  final raw = provider.credentialFormSchemas(predefined: providerFormSchemaPredefined);
  final schemas = [for (final s in raw) FormSchema.fromCredentialSchema(s)];
  final authorizationName = FormSchema(
    type: FormTypeEnum.textInput,
    name: '__authorization_name__',
    label: DifyI18n.tr('plugin', 'auth.authorizationName'),
  );
  var values = <String, Object?>{for (final s in raw) '${s['variable']}': s['default']};
  if (credential != null) {
    values = {...values, '__authorization_name__': credential.credentialName};
    if (credentials != null) values = {...values, ...credentials};
  }
  if (model != null) values = {...values, '__model_name': model.model, '__model_type': model.modelType};
  return (
    formSchemas: [authorizationName, ...schemas],
    formValues: values,
    modelNameAndTypeFormSchemas: providerFormSchemaPredefined
        ? const []
        : [genModelNameFormSchema(provider.modelCredentialModel), genModelTypeFormSchema(provider.supportedModelTypes)],
    modelNameAndTypeFormValues: providerFormSchemaPredefined || model == null
        ? const {}
        : {'__model_name': model.model, '__model_type': model.modelType},
  );
}

/// useCredentialData's request: the stored values of [credential] (provider credentials) or of the model's credential
/// (with the model's available credentials); null when there is nothing to load.
Future<Json>? loadCredentialData(
  ModelProviderEnv env,
  Json provider, {
  required bool providerFormSchemaPredefined,
  bool isModelCredential = false,
  Credential? credential,
  CustomModel? model,
}) {
  final api = env.models.credentials;
  if (!isModelCredential) {
    if (credential == null) return null;
    return api
        .providerCredentials(provider.providerName, credentialId: credential.credentialId)
        .then((c) => <String, Object?>{'credentials': c});
  }
  if (credential == null && model == null) return null;
  return api.modelCredentials(
    provider.providerName,
    model: model?.model ?? '',
    modelType: model?.modelType ?? '',
    configFrom: providerFormSchemaPredefined ? 'predefined-model' : 'custom-model',
    credentialId: credential?.credentialId,
  );
}

// ---- CredentialItem ------------------------------------------------------------------------------------------------

/// authorized/credential-item.tsx: `group flex h-8 items-center rounded-lg p-1 hover:bg-state-base-hover`, the
/// check (with [showSelectedIcon]), the status dot (error when not allowed), the name (`system-md-regular
/// text-text-secondary`), "Unavailable" when not allowed to use, and on hover the edit (`i-ri-equalizer-2-line`) and
/// delete (`i-ri-delete-bin-line`) icon buttons.
class CredentialItem extends StatefulWidget {
  const CredentialItem({
    super.key,
    required this.credential,
    this.disabled = false,
    this.onDelete,
    this.onEdit,
    this.onItemClick,
    this.disableRename = false,
    this.disableEdit = false,
    this.disableDelete = false,
    this.disableDeleteButShowAction = false,
    this.disableDeleteTip,
    this.showSelectedIcon = false,
    this.selectedCredentialId,
  });

  final Credential credential;
  final bool disabled;
  final ValueChanged<Credential>? onDelete, onEdit, onItemClick;
  final bool disableRename, disableEdit, disableDelete, disableDeleteButShowAction;
  final String? disableDeleteTip;
  final bool showSelectedIcon;
  final String? selectedCredentialId;

  @override
  State<CredentialItem> createState() => _CredentialItemState();
}

class _CredentialItemState extends State<CredentialItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final c = w.credential;
    final showAction = !(w.disableRename && w.disableEdit && w.disableDelete);
    final disableDeleteWhenSelected = w.disableDeleteButShowAction && w.selectedCredentialId == c.credentialId;
    final unavailable = c.notAllowedToUse ?? false;
    final clickable = !w.disabled && !unavailable && w.onItemClick != null;
    final name = c.credentialName ?? '';
    Widget item = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: clickable
          ? SystemMouseCursors.click
          : (w.disabled || unavailable ? SystemMouseCursors.forbidden : MouseCursor.defer),
      child: Semantics(
        button: w.onItemClick != null,
        enabled: !w.disabled && !unavailable,
        selected: w.showSelectedIcon && w.selectedCredentialId == c.credentialId,
        label: name,
        onTap: clickable ? () => w.onItemClick!(c) : null,
        child: GestureDetector(
          key: ValueKey('credential-item-${c.credentialId}'),
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: () {
            if (w.disabled || unavailable) return;
            w.onItemClick?.call(c);
          },
          child: Opacity(
            opacity: w.disabled ? 0.5 : 1,
            child: Container(
              height: 32,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: _hovered ? DifyColors.stateBaseHover : null,
                borderRadius: BorderRadius.circular(DifyRadius.lg),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        if (w.showSelectedIcon) ...[
                          SizedBox.square(
                            dimension: 16,
                            child: w.selectedCredentialId == c.credentialId
                                ? const RemixIcon('check-line', size: 16, color: DifyColors.textAccent)
                                : null,
                          ),
                          const SizedBox(width: 6),
                        ],
                        StatusDot(status: unavailable ? StatusDotKind.error : StatusDotKind.success),
                        const SizedBox(width: 6),
                        Flexible(
                          child: ExcludeSemantics(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (c.fromEnterprise) const DifyBadge('Enterprise', uppercase: false),
                  if (unavailable)
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8, right: 4),
                        child: Text(
                          _t('modelProvider.card.unavailable'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textDestructive),
                        ),
                      ),
                    ),
                  if (showAction && !c.fromEnterprise && !unavailable && _hovered) ...[
                    const SizedBox(width: 8),
                    if (!w.disableEdit)
                      DifyTooltip(
                        content: Text(_t('operation.edit')),
                        child: DifyIconButton(
                          key: ValueKey('credential-edit-${c.credentialId}'),
                          label: _t('operation.edit'),
                          disabled: w.disabled,
                          icon: const RemixIcon('equalizer-2-line', size: 16, color: DifyColors.textTertiary),
                          onPressed: () => w.onEdit?.call(c),
                        ),
                      ),
                    if (!w.disableDelete)
                      DifyTooltip(
                        content: Text(disableDeleteWhenSelected ? (w.disableDeleteTip ?? '') : _t('operation.delete')),
                        child: _DeleteIconButton(
                          key: ValueKey('credential-delete-${c.credentialId}'),
                          dimmed: disableDeleteWhenSelected,
                          onPressed: () {
                            if (w.disabled || disableDeleteWhenSelected) return;
                            w.onDelete?.call(c);
                          },
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (unavailable) {
      item = DifyTooltip(content: Text(DifyI18n.tr('plugin', 'auth.customCredentialUnavailable')), child: item);
    }
    return item;
  }
}

/// The delete icon button: `hover:bg-transparent`, the bin turning destructive on hover (half opacity when deleting
/// is blocked).
class _DeleteIconButton extends StatefulWidget {
  const _DeleteIconButton({super.key, required this.dimmed, required this.onPressed});
  final bool dimmed;
  final VoidCallback onPressed;

  @override
  State<_DeleteIconButton> createState() => _DeleteIconButtonState();
}

class _DeleteIconButtonState extends State<_DeleteIconButton> {
  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: _t('operation.delete'),
    onPressed: widget.onPressed,
    builder: (context, hovered, focused) => SizedBox.square(
      dimension: 24,
      child: Center(
        child: Opacity(
          opacity: widget.dimmed ? 0.5 : 1,
          child: RemixIcon(
            'delete-bin-line',
            size: 16,
            color: hovered && !widget.dimmed ? DifyColors.textDestructive : DifyColors.textTertiary,
          ),
        ),
      ),
    ),
  );
}

// ---- AuthorizedItem ------------------------------------------------------------------------------------------------

/// authorized/authorized-item.tsx: `p-1`, the model's title row (with [showModelTitle]: `h-9 px-2`, the model icon
/// and `system-md-medium text-text-primary`), then its credentials.
class AuthorizedItem extends StatelessWidget {
  const AuthorizedItem({
    super.key,
    required this.provider,
    required this.credentials,
    this.model,
    this.title,
    this.disabled = false,
    this.onDelete,
    this.onEdit,
    this.showItemSelectedIcon = false,
    this.selectedCredentialId,
    this.onItemClick,
    this.showModelTitle = false,
    this.disableDeleteButShowAction = false,
    this.disableDeleteTip,
    this.disableEdit = false,
    this.disableDelete = false,
    this.language = 'en_US',
  });

  final Json provider;
  final CustomModel? model;
  final String? title;
  final List<Credential> credentials;
  final bool disabled;
  final void Function(Credential? credential, CustomModel? model)? onDelete, onEdit;
  final bool showItemSelectedIcon;
  final String? selectedCredentialId;
  final void Function(Credential credential, CustomModel? model)? onItemClick;
  final bool showModelTitle, disableDeleteButShowAction, disableEdit, disableDelete;
  final String? disableDeleteTip;
  final String language;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showModelTitle)
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                if (model?.model.isNotEmpty ?? false)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ModelIcon(
                      provider: provider.providerName,
                      iconSmall: provider.iconSmall,
                      modelName: model!.model,
                      language: language,
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      title ?? model?.model ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(DifyType.systemMdMedium, DifyColors.textPrimary),
                    ),
                  ),
                ),
              ],
            ),
          ),
        for (final c in credentials)
          CredentialItem(
            key: ValueKey(c.credentialId),
            credential: c,
            disabled: disabled,
            onDelete: (c) => onDelete?.call(c, model),
            onEdit: (c) => onEdit?.call(c, model),
            disableEdit: disableEdit,
            disableDelete: disableDelete,
            showSelectedIcon: showItemSelectedIcon,
            selectedCredentialId: selectedCredentialId,
            onItemClick: onItemClick == null ? null : (c) => onItemClick!(c, model),
            disableDeleteButShowAction: disableDeleteButShowAction,
            disableDeleteTip: disableDeleteTip,
          ),
      ],
    ),
  );
}

// ---- Authorized ----------------------------------------------------------------------------------------------------

/// One group of [Authorized]: a model's (or the provider's) credentials.
typedef AuthorizedGroup = ({
  String? title,
  CustomModel? model,
  Credential? selectedCredential,
  List<Credential> credentials,
});

/// authorized/index.tsx: a trigger ([renderTrigger]) opening the credential popover (`w-90 rounded-xl
/// border-[0.5px] bg-components-panel-bg-blur shadow-lg backdrop-blur-[5px]`): the optional [popupTitle], the groups
/// (`max-h-76`, separated by dividers), and the add action ("Add model credential" for model credentials, else the
/// "Add API Key" button). Deleting asks for confirmation.
class Authorized extends StatefulWidget {
  const Authorized({
    super.key,
    required this.provider,
    required this.configurationMethod,
    required this.items,
    required this.renderTrigger,
    this.fixedFields,
    this.isModelCredential = false,
    this.onUpdate,
    this.onRemove,
    this.mode,
    this.disabled = false,
    this.isOpen,
    this.onOpenChange,
    this.placement = DifyPlacement.bottomEnd,
    this.sideOffset = 8,
    this.alignOffset = 0,
    this.popupWidth = 360,
    this.showItemSelectedIcon = false,
    this.onItemClick,
    this.triggerOnlyOpenModal = false,
    this.hideAddAction = false,
    this.disableItemClick = false,
    this.popupTitle,
    this.showModelTitle = false,
    this.disableDeleteButShowAction = false,
    this.disableDeleteTip,
  });

  final Json provider;
  final String configurationMethod;
  final CustomModelFixedFields? fixedFields;
  final List<AuthorizedGroup> items;

  /// The trigger for the popover's open state; [toggle] opens or closes it (the trigger's own press).
  final Widget Function(bool open, VoidCallback toggle) renderTrigger;

  /// `authParams`.
  final bool isModelCredential;
  final void Function(Map<String, Object?>? formValues)? onUpdate;
  final void Function(String credentialId)? onRemove;
  final ModelModalModeEnum? mode;

  final bool disabled;
  final bool? isOpen;
  final ValueChanged<bool>? onOpenChange;
  final DifyPlacement placement;
  final double sideOffset, alignOffset, popupWidth;
  final bool showItemSelectedIcon;
  final void Function(Credential credential, CustomModel? model)? onItemClick;
  final bool triggerOnlyOpenModal, hideAddAction, disableItemClick;
  final String? popupTitle;
  final bool showModelTitle, disableDeleteButShowAction;
  final String? disableDeleteTip;

  @override
  State<Authorized> createState() => _AuthorizedState();
}

class _AuthorizedState extends State<Authorized> {
  bool _localOpen = false;
  ModelAuth? _auth;

  bool get _open => widget.isOpen ?? _localOpen;

  void _setOpen(bool open) {
    widget.onOpenChange?.call(open);
    setState(() => _localOpen = open);
  }

  ModelAuth _authOf(ModelProviderEnv env) {
    final a = _auth;
    if (a != null && a.env == env && identical(a.provider, widget.provider)) return a;
    return _auth = ModelAuth(
      env: env,
      provider: widget.provider,
      configurationMethod: widget.configurationMethod,
      fixedFields: widget.fixedFields,
      isModelCredential: widget.isModelCredential,
      onUpdate: widget.onUpdate,
      onRemove: widget.onRemove,
      mode: widget.mode,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final auth = _authOf(env);
    final w = widget;
    final notAllowCustomCredential = !w.provider.allowCustomToken;

    void handleEdit(Credential? credential, CustomModel? model) {
      if (credential != null ? !env.canManageCredential : !env.canCreateCredential) return;
      _setOpen(false);
      auth.handleOpenModal(context, credential: credential, model: model);
    }

    void handleDelete(Credential? credential, CustomModel? model) {
      if (!env.canManageCredential) return;
      _setOpen(false);
      unawaited(auth.confirmDelete(context, credential: credential, model: model));
    }

    void handleItemClick(Credential credential, CustomModel? model) {
      if (!env.canUseCredential || w.disableItemClick) return;
      if (w.onItemClick != null) {
        w.onItemClick!(credential, model);
      } else {
        unawaited(auth.handleActiveCredential(credential, model));
      }
      _setOpen(false);
    }

    final fixed = w.fixedFields;
    final popup = SizedBox(
      width: w.popupWidth,
      child: DifyBlurredBox(
        blur: 5,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBgBlur,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          boxShadow: DifyShadows.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (w.popupTitle != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
                child: Text(w.popupTitle!, style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textTertiary)),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 304),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, item) in w.items.indexed) ...[
                      AuthorizedItem(
                        provider: w.provider,
                        title: item.title,
                        model: item.model,
                        credentials: item.credentials,
                        disabled: w.disabled,
                        disableEdit: !env.canManageCredential,
                        disableDelete: !env.canManageCredential,
                        onDelete: handleDelete,
                        disableDeleteButShowAction: w.disableDeleteButShowAction,
                        disableDeleteTip: w.disableDeleteTip,
                        onEdit: handleEdit,
                        showItemSelectedIcon: w.showItemSelectedIcon,
                        selectedCredentialId: item.selectedCredential?.credentialId,
                        onItemClick: env.canUseCredential ? handleItemClick : null,
                        showModelTitle: w.showModelTitle,
                        language: env.language,
                      ),
                      if (i != w.items.length - 1)
                        const SizedBox(height: 1, child: ColoredBox(color: DifyColors.dividerSubtle)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 1, child: ColoredBox(color: DifyColors.dividerSubtle)),
            if (w.isModelCredential && !notAllowCustomCredential && !w.hideAddAction && env.canCreateCredential)
              DifyPressable(
                key: const ValueKey('authorized-add-model-credential'),
                semanticLabel: _t('modelProvider.auth.addModelCredential'),
                onPressed: () =>
                    handleEdit(null, fixed == null ? null : (model: fixed.modelName, modelType: fixed.modelType)),
                builder: (context, hovered, focused) => Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      const RemixIcon('add-line', size: 16, color: DifyColors.textAccentLightModeOnly),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          _t('modelProvider.auth.addModelCredential'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textAccentLightModeOnly),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (!w.isModelCredential && !notAllowCustomCredential && !w.hideAddAction && env.canCreateCredential)
              Padding(
                padding: const EdgeInsets.all(8),
                child: DifyButton(
                  onPressed: () => handleEdit(null, null),
                  child: Text(_t('modelProvider.auth.addApiKey')),
                ),
              ),
          ],
        ),
      ),
    );

    return DifyFloating(
      open: _open,
      onOpenChange: (open) {
        if (open && w.triggerOnlyOpenModal) {
          if (env.canCreateCredential) auth.handleOpenModal(context);
          return;
        }
        _setOpen(open);
      },
      placement: w.placement,
      sideOffset: w.sideOffset,
      alignOffset: w.alignOffset,
      builder: (context, controller) => w.renderTrigger(_open, controller.toggle),
      popupBuilder: (context) => ModelProviderScope(env: env, child: popup),
    );
  }
}

// ---- AddCustomModel ------------------------------------------------------------------------------------------------

/// The ghost "Add Model" button (`i-ri-add-circle-fill size-3.5`), dimmed with the "credentials unavailable" tooltip
/// when [disabled].
class AddModelButton extends StatelessWidget {
  const AddModelButton({super.key, this.onPressed, this.open = false, this.disabled = false, this.loading = false});

  final VoidCallback? onPressed;
  final bool open, disabled, loading;

  @override
  Widget build(BuildContext context) {
    Widget button = Opacity(
      opacity: disabled ? 0.5 : 1,
      child: DifyButton(
        key: const ValueKey('add-model-button'),
        variant: DifyButtonVariant.ghost,
        size: DifyButtonSize.small,
        loading: loading,
        semanticLabel: _t('modelProvider.addModel'),
        onPressed: onPressed ?? () {},
        leading: const RemixIcon('add-circle-fill', size: 14),
        child: Text(_t('modelProvider.addModel'), style: const TextStyle(color: DifyColors.textTertiary)),
      ),
    );
    if (open) {
      button = DecoratedBox(
        decoration: BoxDecoration(
          color: DifyColors.componentsButtonGhostBgHover,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: button,
      );
    }
    if (disabled) {
      button = DifyTooltip(content: Text(DifyI18n.tr('plugin', 'auth.credentialUnavailable')), child: button);
    }
    return button;
  }
}

/// add-custom-model.tsx: "Add Model". Without models to add back, it opens the credential modal for a new custom
/// model; otherwise a popover lists the models that can be added back (`w-80`, each `h-8 px-2` with its icon) and
/// "Add new model" at the bottom.
class AddCustomModel extends StatefulWidget {
  const AddCustomModel({
    super.key,
    required this.provider,
    required this.configurationMethod,
    this.fixedFields,
    this.open,
    this.onOpenChange,
  });

  final Json provider;
  final String configurationMethod;
  final CustomModelFixedFields? fixedFields;
  final bool? open;
  final ValueChanged<bool>? onOpenChange;

  @override
  State<AddCustomModel> createState() => _AddCustomModelState();
}

class _AddCustomModelState extends State<AddCustomModel> {
  bool _localOpen = false;

  bool get _open => widget.open ?? _localOpen;

  void _setOpen(bool open) {
    setState(() => _localOpen = open);
    widget.onOpenChange?.call(open);
  }

  ModelAuth _auth(ModelProviderEnv env, ModelModalModeEnum mode) => ModelAuth(
    env: env,
    provider: widget.provider,
    configurationMethod: widget.configurationMethod,
    fixedFields: widget.fixedFields,
    isModelCredential: true,
    mode: mode,
  );

  @override
  Widget build(BuildContext context) {
    final env = ModelProviderScope.of(context);
    final canAddedModels = widget.provider.canAddedModels;
    final noModels = canAddedModels.isEmpty;
    final notAllowCustomCredential = !widget.provider.allowCustomToken;
    final disabled = noModels ? !env.canCreateCredential : !env.canUseCredential && !env.canCreateCredential;
    final addNew = _auth(env, ModelModalModeEnum.configCustomModel);
    final addBack = _auth(env, ModelModalModeEnum.addCustomModelToModelList);
    if (noModels) {
      return AddModelButton(
        disabled: (notAllowCustomCredential && noModels) || disabled,
        onPressed: notAllowCustomCredential || !env.canCreateCredential ? null : () => addNew.handleOpenModal(context),
      );
    }
    return DifyFloating(
      open: _open,
      onOpenChange: _setOpen,
      placement: DifyPlacement.bottomEnd,
      sideOffset: 4,
      builder: (context, controller) => AddModelButton(
        open: _open,
        disabled: disabled,
        onPressed: controller.toggle,
      ),
      popupBuilder: (context) => Container(
        width: 320,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBgBlur,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          boxShadow: DifyShadows.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 304),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final m in canAddedModels)
                      DifyPressable(
                        key: ValueKey('can-added-model-${m.model}'),
                        semanticLabel: m.model,
                        disabled: !env.canUseCredential,
                        onPressed: () {
                          if (!env.canUseCredential) return;
                          _setOpen(false);
                          addBack.handleOpenModal(context, model: m.asModel);
                        },
                        builder: (context, hovered, _) => Opacity(
                          opacity: env.canUseCredential ? 1 : 0.5,
                          child: Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: hovered && env.canUseCredential ? DifyColors.stateBaseHover : null,
                              borderRadius: BorderRadius.circular(DifyRadius.lg),
                            ),
                            child: Row(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: ModelIcon(
                                    provider: widget.provider.providerName,
                                    iconSmall: widget.provider.iconSmall,
                                    modelName: m.model,
                                    language: env.language,
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    m.model,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textPrimary),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (!notAllowCustomCredential && env.canCreateCredential)
              DifyPressable(
                key: const ValueKey('add-new-model'),
                semanticLabel: _t('modelProvider.auth.addNewModel'),
                onPressed: () {
                  _setOpen(false);
                  addNew.handleOpenModal(context);
                },
                builder: (context, hovered, _) => Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
                  ),
                  child: Row(
                    children: [
                      const RemixIcon('add-line', size: 16, color: DifyColors.textAccentLightModeOnly),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          _t('modelProvider.auth.addNewModel'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textAccentLightModeOnly),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---- ManageCustomModelCredentials ----------------------------------------------------------------------------------

/// The ghost "Manage Credentials" button.
class ManageCredentialsButton extends StatelessWidget {
  const ManageCredentialsButton({super.key, this.onPressed, this.open = false, this.loading = false});
  final VoidCallback? onPressed;
  final bool open, loading;

  @override
  Widget build(BuildContext context) {
    final button = DifyButton(
      key: const ValueKey('manage-credentials-button'),
      variant: DifyButtonVariant.ghost,
      size: DifyButtonSize.small,
      loading: loading,
      onPressed: onPressed ?? () {},
      child: Text(_t('modelProvider.auth.manageCredentials'), style: const TextStyle(color: DifyColors.textTertiary)),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: open
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: DifyColors.componentsButtonGhostBgHover,
                borderRadius: BorderRadius.circular(DifyRadius.md),
              ),
              child: button,
            )
          : button,
    );
  }
}

/// manage-custom-model-credentials.tsx: "Manage Credentials" opening [Authorized] over the custom models (each with
/// its credentials, the current one checked; clicking one does nothing, the current one cannot be deleted).
class ManageCustomModelCredentials extends StatelessWidget {
  const ManageCustomModelCredentials({
    super.key,
    required this.provider,
    this.fixedFields,
    this.isOpen,
    this.onOpenChange,
  });

  final Json provider;
  final CustomModelFixedFields? fixedFields;
  final bool? isOpen;
  final ValueChanged<bool>? onOpenChange;

  @override
  Widget build(BuildContext context) {
    final customModels = provider.customModels;
    if (customModels.isEmpty) return const SizedBox.shrink();
    return Authorized(
      provider: provider,
      configurationMethod: ConfigurationMethodEnum.customizableModel,
      fixedFields: fixedFields,
      items: [
        for (final m in customModels)
          (
            title: null,
            model: m.asModel,
            credentials: m.availableModelCredentials,
            selectedCredential: m.currentCredentialId != null && m.currentCredentialId!.isNotEmpty
                ? Credential(credentialId: m.currentCredentialId!, credentialName: m.currentCredentialName)
                : null,
          ),
      ],
      renderTrigger: (open, toggle) => ManageCredentialsButton(open: open, onPressed: toggle),
      isOpen: isOpen,
      onOpenChange: onOpenChange,
      isModelCredential: true,
      mode: ModelModalModeEnum.configModelCredential,
      hideAddAction: true,
      disableItemClick: true,
      popupTitle: _t('modelProvider.auth.customModelCredentials'),
      showModelTitle: true,
      disableDeleteButShowAction: true,
      disableDeleteTip: _t('modelProvider.auth.customModelCredentialsDeleteTip'),
    );
  }
}

// ---- CredentialSelector --------------------------------------------------------------------------------------------

/// The selector's "add a new credential" entry (`credential_id: __add_new_credential`).
class SelectedCredential {
  const SelectedCredential(this.credential, {this.addNewCredential = false});
  final Credential credential;
  final bool addNewCredential;
}

/// credential-selector.tsx: `h-8 rounded-lg bg-components-input-bg-normal px-2` showing the selected credential
/// (status dot, name) or "Select model credential", opening the credentials (`max-h-80`) and "Add new model
/// credential" at the bottom.
class CredentialSelector extends StatefulWidget {
  const CredentialSelector({
    super.key,
    required this.credentials,
    required this.onSelect,
    this.selectedCredential,
    this.disabled = false,
    this.notAllowAddNewCredential = false,
  });

  final SelectedCredential? selectedCredential;
  final List<Credential> credentials;
  final ValueChanged<SelectedCredential> onSelect;
  final bool disabled, notAllowAddNewCredential;

  @override
  State<CredentialSelector> createState() => _CredentialSelectorState();
}

class _CredentialSelectorState extends State<CredentialSelector> {
  final _floating = DifyFloatingController();

  void _select(SelectedCredential c) {
    _floating.close();
    widget.onSelect(c);
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.selectedCredential;
    return LayoutBuilder(
      builder: (context, constraints) => DifyFloating(
        controller: _floating,
        placement: DifyPlacement.bottom,
        sideOffset: 0,
        builder: (context, controller) => DifyPressable(
          key: const ValueKey('credential-selector-trigger'),
          disabled: widget.disabled,
          semanticLabel: selected?.credential.credentialName ?? _t('modelProvider.auth.selectModelCredential'),
          onPressed: widget.disabled ? null : controller.toggle,
          builder: (context, hovered, focused) => Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: Row(
              children: [
                if (selected != null)
                  Expanded(
                    child: Row(
                      children: [
                        if (!selected.addNewCredential)
                          const Padding(
                            padding: EdgeInsets.only(left: 4, right: 8),
                            child: _MediumSuccessDot(),
                          ),
                        Flexible(
                          child: Text(
                            selected.credential.credentialName ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: difyTextStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Expanded(
                    child: Text(
                      _t('modelProvider.auth.selectModelCredential'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: difyTextStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextPlaceholder),
                    ),
                  ),
                const RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textQuaternary),
              ],
            ),
          ),
        ),
        popupBuilder: (context) => Container(
          width: constraints.maxWidth.isFinite ? constraints.maxWidth : 400,
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBgBlur,
            borderRadius: BorderRadius.circular(DifyRadius.xl),
            border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
            boxShadow: DifyShadows.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final c in widget.credentials)
                        CredentialItem(
                          key: ValueKey(c.credentialId),
                          credential: c,
                          disableDelete: true,
                          disableEdit: true,
                          disableRename: true,
                          onItemClick: (c) => _select(SelectedCredential(c)),
                          showSelectedIcon: true,
                          selectedCredentialId: selected?.credential.credentialId,
                        ),
                    ],
                  ),
                ),
              ),
              if (!widget.notAllowAddNewCredential)
                DifyPressable(
                  key: const ValueKey('credential-selector-add-new'),
                  semanticLabel: _t('modelProvider.auth.addNewModelCredential'),
                  onPressed: () => _select(
                    SelectedCredential(
                      Credential(
                        credentialId: '__add_new_credential',
                        credentialName: _t('modelProvider.auth.addNewModelCredential'),
                      ),
                      addNewCredential: true,
                    ),
                  ),
                  builder: (context, hovered, _) => Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
                    ),
                    child: Row(
                      children: [
                        const RemixIcon('add-line', size: 16, color: DifyColors.textAccentLightModeOnly),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            _t('modelProvider.auth.addNewModelCredential'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textAccentLightModeOnly),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// StatusDot success, medium (`size-2 rounded-[3px] border`).
class _MediumSuccessDot extends StatelessWidget {
  const _MediumSuccessDot();

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: DifyColors.componentsBadgeStatusLightSuccessBg,
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: DifyColors.componentsBadgeStatusLightSuccessBorderInner),
    ),
  );
}
