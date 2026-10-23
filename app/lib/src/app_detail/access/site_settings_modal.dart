/// The Web App's settings (Dify 1.17.1 app/overview/settings: "Branding"): name and icon, description, answer icon,
/// language, chat colour theme, workflow details, input placeholder, copyright, privacy policy and disclaimer, saved
/// with `POST /apps/{id}/site` (Dify's `ConfigParams`).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../auth/auth_controller.dart';
import '../../files/upload_service.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../i18n/dify_locales.g.dart';
import '../../open_url.dart';
import '../../studio/app_modals.dart' show AppIconSelection, appIconSelectionOf, pickAppIcon;

String _t(String key, [Map<String, Object?> params = const {}]) =>
    DifyI18n.tr('appOverview', 'overview.appInfo.settings.$key', params);
String _c(String ns, String key) => DifyI18n.tr(ns, key);

/// `INPUT_PLACEHOLDER_MAX_LENGTH`.
const inputPlaceholderMaxLength = 64;

/// `INPUT_PLACEHOLDER_SUPPORTED_MODES`.
const _placeholderModes = {'chat', 'agent-chat', 'advanced-chat'};

/// Dify's settings save payload (`ConfigParams`): JSON as the modal sends it, `null` members left out (Dify's
/// `undefined`).
typedef SiteConfigParams = Map<String, Object?>;

/// The settings' save as [AppSiteUpdate].
AppSiteUpdate siteUpdateOf(SiteConfigParams p) => AppSiteUpdate(
  title: p['title'] as String?,
  description: p['description'] as String?,
  defaultLanguage: p['default_language'] as String?,
  chatColorTheme: p['chat_color_theme'] as String?,
  chatColorThemeInverted: p['chat_color_theme_inverted'] as bool?,
  promptPublic: p['prompt_public'] as bool?,
  copyright: p['copyright'] as String?,
  privacyPolicy: p['privacy_policy'] as String?,
  customDisclaimer: p['custom_disclaimer'] as String?,
  inputPlaceholder: p['input_placeholder'] as String?,
  iconType: p['icon_type'] as String?,
  icon: p['icon'] as String?,
  iconBackground: p['icon_background'] as String?,
  showWorkflowSteps: p['show_workflow_steps'] as bool?,
  useIconAsAnswerIcon: p['use_icon_as_answer_icon'] as bool?,
);

/// Shows [SiteSettingsModal] for the app in [app] (kept up to date while open). Outside clicks don't close it.
Future<void> showSiteSettingsModal(
  BuildContext context, {
  required ValueListenable<AppInfo> app,
  required bool isChat,
  bool canDeploy = false,
  required Future<void> Function(SiteConfigParams params) onSave,
}) => showDifyDialog<void>(
  context,
  dismissible: false,
  builder: (context) => ValueListenableBuilder(
    valueListenable: app,
    builder: (context, info, _) => SiteSettingsModal(
      app: info,
      isChat: isChat,
      canDeploy: canDeploy,
      onSave: onSave,
      onClose: () => Navigator.of(context).maybePop(),
    ),
  ),
);

/// SettingsModal (`w-130`, not dismissed by outside clicks). The community edition's defaults: copyright locked
/// (`webapp_copyright_enabled` false, a disabled switch explaining why), the input placeholder editable; Dify Cloud's
/// plan badges show for `deploymentEdition: 'CLOUD'` only. The form resets when the app's site changes while open.
class SiteSettingsModal extends StatefulWidget {
  const SiteSettingsModal({
    super.key,
    required this.app,
    required this.isChat,
    this.canDeploy = false,
    this.onSave,
    required this.onClose,
    this.deploymentEdition = 'SELF_HOSTED',
    this.webappCopyrightEnabled = false,
  });

  final AppInfo app;
  final bool isChat, canDeploy;
  final Future<void> Function(SiteConfigParams params)? onSave;
  final VoidCallback onClose;

  /// `deploymentEditionAtom`: `CLOUD` shows the plan badges and locks the placeholder without the entitlement.
  final String deploymentEdition;

  /// `features.webapp_copyright_enabled` (null: still loading).
  final bool? webappCopyrightEnabled;

  @override
  State<SiteSettingsModal> createState() => SiteSettingsModalState();
}

class SiteSettingsModalState extends State<SiteSettingsModal> {
  late AppSite _site;
  late String title, desc, chatColorTheme, copyright, privacyPolicy, customDisclaimer, inputPlaceholder;
  late bool chatColorThemeInverted, copyrightSwitchValue, showWorkflowSteps, useIconAsAnswerIcon;
  late String language;
  late AppIconSelection appIcon;
  bool _saving = false, _placeholderFocused = false;
  String _resetKey = '';

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(SiteSettingsModal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_keyOf(widget.app) != _resetKey) _reset();
  }

  AppSite _siteOf(AppInfo app) =>
      app.site ?? AppSite(accessToken: '', title: app.name, icon: app.icon, iconBackground: app.iconBackground);

  /// `getSettingsResetKey`.
  String _keyOf(AppInfo app) {
    final s = _siteOf(app);
    return [
      app.id,
      s.title,
      s.description,
      s.chatColorTheme,
      s.chatColorThemeInverted,
      s.copyright,
      s.privacyPolicy,
      s.customDisclaimer,
      s.inputPlaceholder,
      s.defaultLanguage,
      s.iconType,
      s.icon,
      s.iconBackground,
      s.json['icon_url'],
      s.showWorkflowSteps,
      s.useIconAsAnswerIcon,
    ].join('\u0000');
  }

  /// `createInputInfo` / `createAppIcon`.
  void _reset() {
    _resetKey = _keyOf(widget.app);
    final s = _site = _siteOf(widget.app);
    title = s.title;
    desc = s.description ?? '';
    chatColorTheme = s.chatColorTheme ?? '';
    chatColorThemeInverted = s.chatColorThemeInverted;
    copyright = s.copyright ?? '';
    copyrightSwitchValue = (s.copyright ?? '').isNotEmpty;
    privacyPolicy = s.privacyPolicy ?? '';
    customDisclaimer = s.customDisclaimer;
    inputPlaceholder = s.inputPlaceholder ?? '';
    showWorkflowSteps = s.showWorkflowSteps;
    useIconAsAnswerIcon = s.useIconAsAnswerIcon;
    language = s.defaultLanguage;
    appIcon = appIconSelectionOf(
      iconType: s.iconType,
      icon: s.icon,
      background: s.iconBackground,
      url: s.json['icon_url'] as String?,
    );
  }

  bool get _cloud => widget.deploymentEdition == 'CLOUD';
  bool get canCustomizePlaceholder => !_cloud || widget.webappCopyrightEnabled == true;
  bool get _placeholderMode => _placeholderModes.contains(widget.app.mode);

  /// `handleFormSubmit`.
  Future<void> submit() async {
    if (title.isEmpty) {
      toast.error(_c('app', 'newApp.nameNotEmpty'));
      return;
    }
    if (chatColorTheme.isNotEmpty && !RegExp('#[A-F0-9]{6}', caseSensitive: false).hasMatch(chatColorTheme)) {
      toast.error(_t('invalidHexMessage'));
      return;
    }
    if (privacyPolicy.isNotEmpty && !privacyPolicy.startsWith('http://') && !privacyPolicy.startsWith('https://')) {
      toast.error(_t('invalidPrivacyPolicy'));
      return;
    }
    setState(() => _saving = true);
    final enabled = widget.webappCopyrightEnabled;
    final params = <String, Object?>{
      'title': title,
      'description': desc,
      'default_language': language,
      'chat_color_theme': chatColorTheme,
      'chat_color_theme_inverted': chatColorThemeInverted,
      'prompt_public': false,
      if (enabled == true) 'copyright': copyrightSwitchValue ? copyright : '',
      'privacy_policy': privacyPolicy,
      'custom_disclaimer': customDisclaimer,
      if (canCustomizePlaceholder)
        'input_placeholder': _placeholderMode
            ? inputPlaceholder.substring(0, inputPlaceholder.length.clamp(0, inputPlaceholderMaxLength))
            : '',
      'icon_type': appIcon.type,
      'icon': appIcon.icon,
      if (appIcon.type == 'emoji') 'icon_background': appIcon.background,
      'show_workflow_steps': showWorkflowSteps,
      'use_icon_as_answer_icon': useIconAsAnswerIcon,
    };
    await widget.onSave?.call(params);
    if (!mounted) return;
    setState(() => _saving = false);
    widget.onClose();
  }

  Future<void> _pickIcon() async {
    final auth = AuthScope.maybeOf(context);
    final v = await pickAppIcon(context, appIcon, upload: auth == null ? null : appIconUploader(auth));
    if (v != null && mounted) setState(() => appIcon = v);
  }

  static TextStyle get _label => difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary);
  static TextStyle get _sectionTitle => difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary);
  static TextStyle get _desc => difyTextStyle(DifyType.bodyXsRegular, DifyColors.textTertiary);

  Widget _fieldDescription(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: DifyTextLine(text, style: _desc),
  );

  Widget _switchField({required String label, required Widget control, String? description}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 4,
    children: [
      Row(
        spacing: 12,
        children: [
          Expanded(child: DifyTextLine(label, style: _label)),
          control,
        ],
      ),
      if (description != null) _fieldDescription(description),
    ],
  );

  Widget _divider() => Container(height: 1, color: DifyColors.dividerRegular);

  Widget _premiumBadge() => Container(
    height: 18,
    padding: const EdgeInsets.symmetric(horizontal: 3),
    decoration: BoxDecoration(
      color: DifyColors.componentsPremiumBadgeBlueBgStop0,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        RemixIcon('sparkling-line', size: 12, color: DifyColors.componentsPremiumBadgeIndigoTextStop0),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: DifyTextLine(
            _c('billing', 'upgradeBtn.encourageShort'),
            style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textPrimaryOnSurface),
          ),
        ),
      ],
    ),
  );

  Widget _placeholderField() {
    final enabled = canCustomizePlaceholder;
    final preview = enabled && inputPlaceholder.trim().isNotEmpty && !_placeholderFocused;
    final field = Opacity(
      opacity: enabled ? 1 : 0.6,
      child: Container(
        height: 40,
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
        decoration: BoxDecoration(
          color: enabled && _placeholderFocused
              ? DifyColors.componentsInputBgActive
              : DifyColors.componentsInputBgNormal,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(
            color: enabled && _placeholderFocused
                ? DifyColors.componentsInputBorderActive
                : DifyColors.componentsInputBorderHover,
          ),
        ),
        child: Row(
          spacing: 8,
          children: [
            Expanded(
              child: Focus(
                onFocusChange: (f) => setState(() => _placeholderFocused = f),
                child: DifyInput(
                  key: const ValueKey('settings-input-placeholder'),
                  value: inputPlaceholder,
                  disabled: !enabled,
                  maxLength: inputPlaceholderMaxLength,
                  semanticLabel: _t('more.inputPlaceholder'),
                  placeholder: _t('more.inputPlaceholderPlaceholder'),
                  textStyle: difyTextStyle(
                    DifyType.bodyMdRegular,
                    preview ? DifyColors.textPlaceholder : DifyColors.textPrimary,
                  ),
                  onChanged: (v) => setState(() => inputPlaceholder = v),
                ),
              ),
            ),
            Opacity(
              opacity: 0.5,
              child: Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: DifyColors.componentsButtonPrimaryBg,
                  borderRadius: BorderRadius.circular(DifyRadius.md),
                ),
                child: DifyIcon(
                  'vender/solid/communication/send-03',
                  size: 16,
                  color: DifyColors.componentsButtonPrimaryText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (_cloud && widget.webappCopyrightEnabled == false) {
      return DifyTooltip(content: DifyTextLine(_t('more.inputPlaceholderTooltip')), child: field);
    }
    return field;
  }

  Widget _copyrightSwitch() {
    final enabled = widget.webappCopyrightEnabled;
    final control = DifySwitch(
      key: const ValueKey('settings-copyright-switch'),
      checked: copyrightSwitchValue,
      disabled: enabled != true,
      semanticLabel: _t('more.copyright'),
      onCheckedChange: (v) => setState(() => copyrightSwitchValue = v),
    );
    if (enabled != false) return control;
    return DifyTooltip(content: DifyTextLine(_t('more.copyrightTooltip')), child: control);
  }

  /// `privacyPolicyTip` with its `<privacyPolicyLink>` part as a link to dify.ai/privacy.
  Widget _privacyTip() {
    final text = _t('more.privacyPolicyTip');
    final m = RegExp('<privacyPolicyLink>(.*?)</privacyPolicyLink>', dotAll: true).firstMatch(text);
    if (m == null) return DifyTextLine(text, style: _desc);
    return DifyTextLine.rich(
      TextSpan(
        style: _desc,
        children: [
          TextSpan(text: text.substring(0, m.start)),
          TextSpan(
            text: m[1],
            style: TextStyle(color: DifyColors.textAccent),
            recognizer: TapGestureRecognizer()..onTap = () => unawaited(openExternalUrl('https://dify.ai/privacy')),
          ),
          TextSpan(text: text.substring(m.end)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.app.mode;
    final languages = [
      for (final l in difyLanguages)
        if (l.supported) (value: l.value, label: l.name),
    ];
    final cloudLocked = _cloud && widget.webappCopyrightEnabled == false;
    return DifyDialogSurface(
      label: _t('title'),
      width: 520,
      bordered: true,
      maxHeight: MediaQuery.sizeOf(context).height - 32,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  spacing: 4,
                  children: [
                    Expanded(
                      child: DifyTextLine(
                        _t('title'),
                        style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                      ),
                    ),
                    DifyIconButton(
                      key: const ValueKey('dialog-close'),
                      label: _c('common', 'operation.close'),
                      size: DifyIconButtonSize.sm,
                      icon: const RemixIcon('close-line', size: 16),
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: DifyTextLine(
                    _t('modalTip'),
                    style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                  ),
                ),
              ],
            ),
          ),
          if (widget.canDeploy)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Semantics(
                key: const ValueKey('settings-multi-environment'),
                liveRegion: true,
                container: true,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: DifyColors.componentsPanelBgBlur,
                    borderRadius: BorderRadius.circular(DifyRadius.xl),
                    border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
                    boxShadow: DifyShadows.xs,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: RemixIcon('information-2-fill', size: 16, color: DifyColors.textAccent),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: DifyTextLine(
                            _t('multiEnvironmentNotice'),
                            style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textPrimary),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 20,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 16,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 4,
                          children: [
                            DifyTextLine(_t('webName'), style: _label),
                            DifyInput(
                              key: const ValueKey('settings-title'),
                              value: title,
                              semanticLabel: _t('webName'),
                              placeholder: _c('app', 'appNamePlaceholder'),
                              onChanged: (v) => setState(() => title = v),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: DifyAppIcon(
                          key: const ValueKey('settings-icon'),
                          size: DifyAppIconSize.xxl,
                          iconType: appIcon.type,
                          icon: appIcon.icon,
                          background: appIcon.background,
                          imageUrl: appIcon.url,
                          semanticLabel: _c('app', 'iconPicker.emoji'),
                          onTap: _pickIcon,
                        ),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 4,
                    children: [
                      DifyTextLine(_t('webDesc'), style: _label),
                      DifyTextarea(
                        key: const ValueKey('settings-description'),
                        value: desc,
                        semanticLabel: _t('webDesc'),
                        placeholder: _t('webDescPlaceholder'),
                        onChanged: (v) => setState(() => desc = v),
                      ),
                      _fieldDescription(_t('webDescTip')),
                    ],
                  ),
                  _divider(),
                  if (widget.isChat)
                    _switchField(
                      label: _c('app', 'answerIcon.title'),
                      description: _c('app', 'answerIcon.description'),
                      control: DifySwitch(
                        key: const ValueKey('settings-answer-icon'),
                        checked: useIconAsAnswerIcon,
                        semanticLabel: _c('app', 'answerIcon.title'),
                        onCheckedChange: (v) => setState(() => useIconAsAnswerIcon = v),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: DifyTextLine(_t('language'), style: _sectionTitle),
                        ),
                      ),
                      DifySelect<String>(
                        key: const ValueKey('settings-language'),
                        width: 200,
                        value: languages.any((l) => l.value == language) ? language : null,
                        placeholder: _c('common', 'placeholder.select'),
                        semanticLabel: _t('language'),
                        options: languages,
                        onChanged: (v) => setState(() => language = v),
                      ),
                    ],
                  ),
                  if (widget.isChat)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: DifyTextLine(_t('chatColorTheme'), style: _sectionTitle),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 2),
                                child: DifyTextLine(_t('chatColorThemeDesc'), style: _desc),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 200,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: DifyInput(
                                  key: const ValueKey('settings-color'),
                                  value: chatColorTheme,
                                  semanticLabel: _t('chatColorTheme'),
                                  placeholder: 'E.g #A020F0',
                                  onChanged: (v) => setState(() => chatColorTheme = v),
                                ),
                              ),
                              Row(
                                spacing: 8,
                                children: [
                                  Expanded(child: DifyTextLine(_t('chatColorThemeInverted'), style: _desc)),
                                  DifySwitch(
                                    key: const ValueKey('settings-color-inverted'),
                                    checked: chatColorThemeInverted,
                                    semanticLabel: _t('chatColorThemeInverted'),
                                    onCheckedChange: (v) => setState(() => chatColorThemeInverted = v),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  _switchField(
                    label: _t('workflow.subTitle'),
                    description: _t('workflow.showDesc'),
                    control: DifySwitch(
                      key: const ValueKey('settings-workflow-steps'),
                      checked: showWorkflowSteps,
                      disabled: !(mode == AppModes.workflow || mode == AppModes.advancedChat),
                      semanticLabel: _t('workflow.subTitle'),
                      onCheckedChange: (v) => setState(() => showWorkflowSteps = v),
                    ),
                  ),
                  _divider(),
                  if (_placeholderMode)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 4, top: 4, bottom: 4),
                                child: DifyTextLine(_t('more.inputPlaceholder'), style: _sectionTitle),
                              ),
                            ),
                            if (cloudLocked) _premiumBadge(),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: DifyTextLine(_t('more.inputPlaceholderTip'), style: _desc),
                        ),
                        _placeholderField(),
                        if (canCustomizePlaceholder)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: DifyTextLine(
                              '${inputPlaceholder.length} / $inputPlaceholderMaxLength',
                              textAlign: TextAlign.right,
                              style: _desc,
                            ),
                          ),
                      ],
                    ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Flexible(
                                  child: Padding(
                                    padding: const EdgeInsets.only(right: 4, top: 4, bottom: 4),
                                    child: DifyTextLine(_t('more.copyright'), style: _sectionTitle),
                                  ),
                                ),
                                if (cloudLocked) _premiumBadge(),
                              ],
                            ),
                          ),
                          _copyrightSwitch(),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: DifyTextLine(_t('more.copyrightTip'), style: _desc),
                      ),
                      if (copyrightSwitchValue)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: DifyInput(
                            key: const ValueKey('settings-copyright'),
                            value: copyright,
                            height: 40,
                            disabled: widget.webappCopyrightEnabled != true,
                            semanticLabel: _t('more.copyright'),
                            placeholder: _t('more.copyRightPlaceholder'),
                            onChanged: (v) => setState(() => copyright = v),
                          ),
                        ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: DifyTextLine(_t('more.privacyPolicy'), style: _sectionTitle),
                      ),
                      Padding(padding: const EdgeInsets.only(bottom: 2), child: _privacyTip()),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: DifyInput(
                          key: const ValueKey('settings-privacy'),
                          value: privacyPolicy,
                          semanticLabel: _t('more.privacyPolicy'),
                          placeholder: _t('more.privacyPolicyPlaceholder'),
                          onChanged: (v) => setState(() => privacyPolicy = v),
                        ),
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: DifyTextLine(_t('more.customDisclaimer'), style: _sectionTitle),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: DifyTextLine(_t('more.customDisclaimerTip'), style: _desc),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: DifyTextarea(
                          key: const ValueKey('settings-disclaimer'),
                          value: customDisclaimer,
                          semanticLabel: _t('more.customDisclaimer'),
                          placeholder: _t('more.customDisclaimerPlaceholder'),
                          onChanged: (v) => setState(() => customDisclaimer = v),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                DifyButton(onPressed: widget.onClose, child: DifyTextLine(_c('common', 'operation.cancel'))),
                DifyButton(
                  key: const ValueKey('settings-save'),
                  variant: DifyButtonVariant.primary,
                  loading: _saving,
                  onPressed: () => unawaited(submit()),
                  child: DifyTextLine(_c('common', 'operation.save')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The site the form was last reset from.
  AppSite get site => _site;
}
