/// Content moderation (moderation/index.tsx, moderation-setting-modal.tsx, moderation-content.tsx,
/// form-generation.tsx) and the API extension selector it uses
/// (header/account-setting/api-based-extension-page/selector.tsx).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import 'features_services.dart';
import 'features_store.dart';
import 'new_feature_panel.dart';

const _systemTypes = ['openai_moderation', 'keywords', 'api'];

/// A label in the app's language (`label[locale]`, en-US otherwise).
String _i18n(Object? label, String locale) {
  final m = featureMap({'l': label}, 'l');
  return '${m[locale == 'zh-Hans' ? 'zh-Hans' : 'en-US'] ?? m['en-US'] ?? ''}';
}

/// Moderation: the switch (turning it on without a provider opens the settings with keywords; off clears it), the
/// provider and what is checked, and while hovered "Settings".
class Moderation extends StatefulWidget {
  const Moderation({super.key, this.disabled = false, this.onChange});
  final bool disabled;
  final OnFeaturesChange? onChange;

  @override
  State<Moderation> createState() => _ModerationState();
}

class _ModerationState extends State<Moderation> with FeatureHover {
  void _show(ModerationModalRequest r) {
    final services = FeaturesServicesScope.of(context);
    (services.showModerationSettingModal ?? showModerationSettingModal)(context, r);
  }

  void _set(Json moderation, {bool pass = true}) {
    final store = FeaturesScope.of(context);
    final next = {...store.features.value, FeatureEnum.moderation: moderation};
    store.setFeatures(next);
    pass ? widget.onChange?.call(next) : widget.onChange?.call();
  }

  void _openSettings() {
    if (widget.disabled) return;
    _show((
      payload: featureMap(FeaturesScope.of(context).features.value, FeatureEnum.moderation),
      onSaveCallback: _set,
      onCancelCallback: () => widget.onChange?.call(),
    ));
  }

  void _toggle(bool enabled) {
    final features = FeaturesScope.of(context).features.value;
    if (enabled && featureMap(features, FeatureEnum.moderation)['type'] == null) {
      _show((
        payload: const {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'keywords': '',
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
        onSaveCallback: _set,
        onCancelCallback: () => _set(const {'enabled': false}, pass: false),
      ));
    }
    if (!enabled) _set(const {'enabled': false});
  }

  @override
  Widget build(BuildContext context) {
    final services = FeaturesServicesScope.of(context);
    return FeaturesBuilder(
      builder: (context, features) {
        final moderation = featureMap(features, FeatureEnum.moderation);
        final enabled = moderation['enabled'] == true;
        final type = moderation['type'];
        final config = featureMap(moderation, 'config');
        final inputs = featureMap(config, 'inputs_config')['enabled'] == true;
        final outputs = featureMap(config, 'outputs_config')['enabled'] == true;
        final provider = switch (type) {
          'openai_moderation' => ad('feature.moderation.modal.provider.openai'),
          'keywords' => ad('feature.moderation.modal.provider.keywords'),
          'api' => tc('apiBasedExtension.selector.title'),
          _ => () {
            final ext = services.codeBasedExtensions.where((e) => e['name'] == type).firstOrNull;
            final label = ext == null ? '' : '${featureMap(ext, 'label')[services.currentLocale] ?? ''}';
            return label.isEmpty ? '-' : label;
          }(),
        };
        final content = inputs && outputs
            ? ad('feature.moderation.allEnabled')
            : inputs
            ? ad('feature.moderation.inputEnabled')
            : outputs
            ? ad('feature.moderation.outputEnabled')
            : '';
        return FeatureCard(
          icon: FeatureIcon(color: DifyColors.textSuccess, dify: 'vender/features/content-moderation'),
          title: ad('feature.moderation.title'),
          value: enabled,
          disabled: widget.disabled,
          onChange: _toggle,
          onMouseEnter: () => setHovering(true),
          onMouseLeave: () => setHovering(false),
          child: !enabled
              ? FeatureDescription(ad('feature.moderation.description'))
              : isHovering
              ? FeatureCardButton(
                  icon: 'equalizer-2-line',
                  label: tc('operation.settings'),
                  disabled: widget.disabled,
                  onPressed: _openSettings,
                )
              : FeatureInfo([
                  (ad('feature.moderation.modal.provider.title'), provider),
                  (ad('feature.moderation.contentEnableLabel'), content),
                ]),
        );
      },
    );
  }
}

/// The modal context's moderation modal: [ModerationSettingModal] in a dialog; Save calls `onSaveCallback`, any
/// other way out `onCancelCallback`.
void showModerationSettingModal(BuildContext context, ModerationModalRequest r) {
  final services = FeaturesServicesScope.of(context);
  var saved = false;
  showDifyDialog<void>(
    context,
    dismissible: false,
    builder: (dialog) => FeaturesServicesScope(
      services: services,
      child: ModerationSettingModal(
        data: r.payload,
        onSave: (v) {
          saved = true;
          Navigator.of(dialog).pop();
          r.onSaveCallback(v);
        },
        onCancel: () => Navigator.of(dialog).pop(),
      ),
    ),
  ).then((_) {
    if (!saved) r.onCancelCallback();
  });
}

typedef _Provider = ({String key, String name, List<Json>? formSchema});

/// ModerationSettingModal: the provider (OpenAI moderation, keywords, an API extension or a code-based extension),
/// its settings, and whether inputs and outputs are checked with their preset replies. Save checks what Dify checks
/// (toasting why it refuses) and hands over the formatted config.
class ModerationSettingModal extends StatefulWidget {
  const ModerationSettingModal({super.key, required this.data, required this.onCancel, required this.onSave});
  final Json data;
  final VoidCallback onCancel;
  final ValueChanged<Json> onSave;

  @override
  State<ModerationSettingModal> createState() => _ModerationSettingModalState();
}

class _ModerationSettingModalState extends State<ModerationSettingModal> {
  /// `localeDataRef`: always current; the rendered data is [_shown] (typing a preset reply does not re-render).
  late Json _data = widget.data;
  late Json _shown = widget.data;

  void _update(Json Function(Json current) f, {bool render = true}) {
    _data = f(_data);
    if (render) setState(() => _shown = _data);
  }

  Json _config(Json d) => featureMap(d, 'config');

  List<_Provider> _providers(FeaturesServices s) => [
    (key: 'openai_moderation', name: ad('feature.moderation.modal.provider.openai'), formSchema: null),
    (key: 'keywords', name: ad('feature.moderation.modal.provider.keywords'), formSchema: null),
    (key: 'api', name: tc('apiBasedExtension.selector.title'), formSchema: null),
    for (final e in s.codeBasedExtensions)
      (
        key: '${e['name']}',
        name: _i18n(e['label'], s.currentLocale),
        formSchema: [...?(e['form_schema'] as List?)?.whereType<Json>()],
      ),
  ];

  void _typeChange(String type, List<_Provider> providers) {
    final p = providers.where((x) => x.key == type).firstOrNull;
    final Json? config = !_systemTypes.contains(type) && p?.formSchema != null
        ? {for (final f in p!.formSchema!) '${f['variable']}': f['default']}
        : null;
    _update((c) => {...c, 'type': type, 'config': config});
  }

  void _keywordsChange(String value) {
    final arr = <String>[];
    for (final next in value.split('\n')) {
      if (next.isNotEmpty) arr.add(next.length > 100 ? next.substring(0, 100) : next);
      if (next.isEmpty && (arr.isEmpty || arr.last.isNotEmpty)) arr.add(next);
    }
    _update(
      (c) => {
        ...c,
        'config': {..._config(c), 'keywords': arr.take(100).join('\n')},
      },
    );
  }

  void _contentChange(String contentType, Json contentConfig) {
    final previous = featureMap(_config(_data), contentType);
    _update(
      (c) => {
        ...c,
        'config': {..._config(c), contentType: contentConfig},
      },
      render: previous['enabled'] != contentConfig['enabled'],
    );
  }

  void _toast(FeaturesServices s, String message) => s.toast?.call(DifyToastType.error, message);

  void _save(FeaturesServices s, List<_Provider> providers) {
    final d = _data;
    final type = d['type'];
    final config = _config(d);
    final zh = s.currentLocale == 'zh-Hans';
    if (type == 'openai_moderation' && !s.isOpenAIProviderConfigured) return;
    final inputs = featureMap(config, 'inputs_config'), outputs = featureMap(config, 'outputs_config');
    if (inputs['enabled'] != true && outputs['enabled'] != true) {
      return _toast(s, ad('feature.moderation.modal.content.condition'));
    }
    bool empty(Object? v) => v == null || v == '' || v == false || v == 0;
    String required(String key) => ad('errorMessage.valueOfVarRequired', {'key': key});
    if (type == 'keywords' && empty(config['keywords'])) return _toast(s, required(zh ? '关键词' : 'keywords'));
    if (type == 'api' && empty(config['api_based_extension_id'])) {
      return _toast(s, required(zh ? 'API 扩展' : 'API Extension'));
    }
    final provider = providers.where((p) => p.key == type).firstOrNull;
    if (!_systemTypes.contains(type) && provider?.formSchema != null) {
      for (final f in provider!.formSchema!) {
        if (empty(config['${f['variable']}']) && f['required'] == true) {
          final label = featureMap(f, 'label');
          return _toast(s, required('${label[zh ? 'zh-Hans' : 'en-US']}'));
        }
      }
    }
    for (final c in [inputs, outputs]) {
      if (c['enabled'] == true && empty(c['preset_response']) && type != 'api') {
        return _toast(s, ad('feature.moderation.modal.content.errorMessage'));
      }
    }
    // formatData
    final current = providers.where((p) => p.key == type).firstOrNull;
    widget.onSave({
      'type': type,
      'enabled': d['enabled'],
      'config': {
        'inputs_config': config['inputs_config'] ?? const {'enabled': false},
        'outputs_config': config['outputs_config'] ?? const {'enabled': false},
        if (type == 'keywords') 'keywords': ?config['keywords'],
        if (type == 'api') 'api_based_extension_id': ?config['api_based_extension_id'],
        if (!_systemTypes.contains(type) && current?.formSchema != null)
          for (final f in current!.formSchema!) '${f['variable']}': ?config['${f['variable']}'],
      },
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = FeaturesServicesScope.of(context);
    final providers = _providers(s);
    final type = _shown['type'];
    final config = _config(_shown);
    final current = providers.where((p) => p.key == type).firstOrNull;
    final openaiOk = s.isOpenAIProviderConfigured;
    final isApi = type == 'api';
    Widget label(String text) => DifyText(text, DifyType.systemSmMedium, color: DifyColors.textSecondary);
    Widget content(String key, String title) {
      final c = featureMap(config, key);
      final cfg = c.isEmpty ? const <String, Object?>{'enabled': false, 'preset_response': ''} : c;
      return ModerationContent(
        key: ValueKey('$key-$type-${c['preset_response'] ?? ''}'),
        title: title,
        config: cfg,
        onConfigChange: (v) => _contentChange(key, v),
        info: isApi ? ad('feature.moderation.modal.content.fromApi') : '',
        showPreset: !isApi,
      );
    }

    // Dify's dialog has no onOpenChange: Escape does not close it.
    return Shortcuts(
      shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DoNothingAndStopPropagationIntent()},
      child: DifyDialogSurface(
        width: 600,
        label: ad('feature.moderation.modal.title'),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
            borderRadius: BorderRadius.circular(DifyRadius.xxl),
          ),
          child: Stack(
            children: [
              SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 56, 12),
                      child: DifyText(ad('feature.moderation.modal.title'), DifyType.title2xlSemiBold, maxLines: null),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: 16,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 4,
                            children: [
                              label(ad('feature.moderation.modal.provider.title')),
                              LayoutBuilder(
                                builder: (context, c) {
                                  final w = (c.maxWidth - 16) / 3;
                                  return Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      for (final p in providers)
                                        SizedBox(
                                          width: w,
                                          child: _ProviderOption(
                                            provider: p,
                                            selected: type == p.key,
                                            disabledText:
                                                type == 'openai_moderation' &&
                                                p.key == 'openai_moderation' &&
                                                !openaiOk,
                                            onTap: () => _typeChange(p.key, providers),
                                          ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                              if (!s.modelProvidersLoading && !openaiOk && type == 'openai_moderation')
                                _OpenAINotConfigured(onOpen: () => s.openAccountSettings?.call('provider')),
                            ],
                          ),
                          if (type == 'keywords') _keywords(config),
                          if (isApi)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              spacing: 4,
                              children: [
                                SizedBox(
                                  height: 24,
                                  child: Row(
                                    children: [
                                      Expanded(child: label(tc('apiBasedExtension.selector.title'))),
                                      DifyIcon(
                                        'vender/line/education/book-open-01',
                                        size: 12,
                                        color: DifyColors.textTertiary,
                                      ),
                                      const SizedBox(width: 4),
                                      DifyText(
                                        tc('apiBasedExtension.link'),
                                        DifyType.systemXsRegular,
                                        color: DifyColors.textTertiary,
                                      ),
                                    ],
                                  ),
                                ),
                                ApiBasedExtensionSelector(
                                  value: '${config['api_based_extension_id'] ?? ''}',
                                  onChange: (id) => _update(
                                    (c) => {
                                      ...c,
                                      'config': {..._config(c), 'api_based_extension_id': id},
                                    },
                                  ),
                                ),
                              ],
                            ),
                          if (!_systemTypes.contains(type) && current?.formSchema != null)
                            FormGeneration(
                              forms: current!.formSchema!,
                              value: config,
                              locale: s.currentLocale,
                              onChange: (v) => _update(
                                (c) => {
                                  ...c,
                                  'config': {..._config(c), ...v},
                                },
                              ),
                            ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 8,
                            children: [
                              Row(
                                spacing: 8,
                                children: [
                                  DifyText(
                                    ad('feature.moderation.title'),
                                    DifyType.systemXsMediumUppercase,
                                    color: DifyColors.textTertiary,
                                  ),
                                  const Expanded(child: DifyDivider(gradient: true)),
                                ],
                              ),
                              content('inputs_config', ad('feature.moderation.modal.content.input')),
                              content('outputs_config', ad('feature.moderation.modal.content.output')),
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: DifyText(
                                  ad('feature.moderation.modal.content.condition'),
                                  DifyType.systemXsRegular,
                                  color: DifyColors.textTertiary,
                                  maxLines: null,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                      child: FeatureFooter([
                        ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 72),
                          child: DifyButton(onPressed: widget.onCancel, child: Text(tc('operation.cancel'))),
                        ),
                        ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 72),
                          child: DifyButton(
                            variant: DifyButtonVariant.primary,
                            disabled: type == 'openai_moderation' && !openaiOk,
                            onPressed: () => _save(s, providers),
                            child: Text(tc('operation.save')),
                          ),
                        ),
                      ]),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 20,
                right: 20,
                child: DifyPressable(
                  onPressed: widget.onCancel,
                  semanticLabel: tc('operation.close'),
                  builder: (context, hovered, focused) => Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: hovered ? DifyColors.stateBaseHover : null,
                      borderRadius: BorderRadius.circular(DifyRadius.lg),
                      boxShadow: difyFocusRing(focused),
                    ),
                    child: Center(
                      child: RemixIcon(
                        'close-line',
                        size: 18,
                        color: hovered ? DifyColors.textSecondary : DifyColors.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _keywords(Json config) {
    final keywords = '${config['keywords'] ?? ''}';
    final lines = keywords.split('\n').where((l) => l.isNotEmpty).length;
    final placeholder = ad('feature.moderation.modal.keywords.placeholder');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        DifyText(
          ad('feature.moderation.modal.provider.keywords'),
          DifyType.systemSmMedium,
          color: DifyColors.textSecondary,
        ),
        DifyText(
          ad('feature.moderation.modal.keywords.tip'),
          DifyType.systemXsRegular,
          color: DifyColors.textTertiary,
          maxLines: null,
        ),
        _CountedTextarea(
          height: 88,
          value: keywords,
          label: ad('feature.moderation.modal.provider.keywords'),
          placeholder: placeholder,
          onChanged: _keywordsChange,
          count: '$lines',
          total: '100${ad('feature.moderation.modal.keywords.line')}',
        ),
      ],
    );
  }
}

/// A provider card of the moderation modal.
class _ProviderOption extends StatelessWidget {
  const _ProviderOption({
    required this.provider,
    required this.selected,
    required this.disabledText,
    required this.onTap,
  });
  final _Provider provider;
  final bool selected, disabledText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = switch (provider.key) {
      'openai_moderation' => RemixIcon('openai-fill', size: 16, color: DifyColors.textSecondary),
      'keywords' => RemixIcon('search-line', size: 16, color: DifyColors.utilColorsGreenGreen600),
      _ => RemixIcon('image-line', size: 16, color: DifyColors.utilColorsVioletViolet600),
    };
    return DifyPressable(
      onPressed: onTap,
      builder: (context, hovered, focused) => Container(
        constraints: const BoxConstraints(minHeight: 68),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? DifyColors.componentsOptionCardOptionSelectedBg
              : hovered
              ? DifyColors.componentsOptionCardOptionBgHover
              : DifyColors.componentsOptionCardOptionBg,
          border: Border.all(
            color: selected
                ? DifyColors.componentsOptionCardOptionSelectedBorder
                : hovered
                ? DifyColors.componentsOptionCardOptionBorderHover
                : DifyColors.componentsOptionCardOptionBorder,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          boxShadow: [
            if (selected || hovered) ...DifyShadows.xs,
            if (focused) difyFocusRingShadow(),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 6,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: DifyColors.backgroundDefaultDodge,
                border: Border.all(color: DifyColors.dividerRegular, width: Css.hairline),
                borderRadius: BorderRadius.circular(DifyRadius.lg),
              ),
              child: Center(child: icon),
            ),
            DifyText(
              provider.name,
              DifyType.systemXsRegular,
              color: disabledText ? DifyColors.textDisabled : DifyColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// "OpenAI is not set up": a link to the provider settings between the two halves of the sentence.
class _OpenAINotConfigured extends StatelessWidget {
  const _OpenAINotConfigured({required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 12, height: 18 / 12, fontWeight: FontWeight.w500, color: Color(0xFF344054));
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAEB),
        border: Border.all(color: const Color(0xFFFEF0C7)),
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: DifyIcon('vender/line/general/info-circle', size: 16, color: Color(0xFFF79009)),
          ),
          Flexible(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(ad('feature.moderation.modal.openaiNotConfig.before'), style: style),
                GestureDetector(
                  onTap: onOpen,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Text(
                      ' ${tc('settings.provider')} ',
                      style: style.copyWith(color: const Color(0xFF155EEF)),
                    ),
                  ),
                ),
                Text(ad('feature.moderation.modal.openaiNotConfig.after'), style: style),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A textarea of fixed [height] with a `count/total` badge in its bottom-right corner.
class _CountedTextarea extends StatelessWidget {
  const _CountedTextarea({
    required this.height,
    required this.value,
    required this.label,
    required this.placeholder,
    required this.onChanged,
    required this.count,
    required this.total,
  });
  final double height;
  final String value, label, placeholder, count, total;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final badge = difyTextStyle(DifyType.system2xsMediumUppercase, DifyColors.textQuaternary);
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              child: DifyTextarea(
                value: value,
                minHeight: height,
                semanticLabel: label,
                placeholder: placeholder,
                onChanged: onChanged,
              ),
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: Container(
              height: 20,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: DifyColors.backgroundSection,
                borderRadius: BorderRadius.circular(DifyRadius.md),
              ),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: count),
                    const TextSpan(text: '/'),
                    TextSpan(
                      text: total.toUpperCase(),
                      style: badge.copyWith(color: DifyColors.textTertiary),
                    ),
                  ],
                ),
                style: badge,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ModerationContent: a section with [title], [info] and the switch; when on (and [showPreset]) the preset reply (at
/// most 100 characters, Markdown) with its counter. Each change reports the whole content config.
class ModerationContent extends StatefulWidget {
  const ModerationContent({
    super.key,
    required this.title,
    required this.config,
    required this.onConfigChange,
    this.info,
    this.showPreset = true,
  });

  final String title;
  final String? info;
  final bool showPreset;
  final Json config;
  final ValueChanged<Json> onConfigChange;

  @override
  State<ModerationContent> createState() => _ModerationContentState();
}

class _ModerationContentState extends State<ModerationContent> {
  late String _preset = '${widget.config['preset_response'] ?? ''}';

  void _change(String field, Object value) {
    var v = value;
    if (field == 'preset_response' && v is String && v.length > 100) v = v.substring(0, 100);
    widget.onConfigChange({
      ...widget.config,
      'preset_response': field == 'preset_response' ? v : _preset,
      field: v,
    });
  }

  void _presetChange(String value) {
    final next = value.length > 100 ? value.substring(0, 100) : value;
    setState(() => _preset = next);
    _change('preset_response', next);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final enabled = w.config['enabled'] == true;
    final badge = difyTextStyle(DifyType.system2xsMediumUppercase, DifyColors.textTertiary);
    return Semantics(
      container: true,
      label: w.title,
      child: Container(
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelOnPanelItemBg,
          border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: Css.hairline),
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          boxShadow: DifyShadows.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              constraints: const BoxConstraints(minHeight: 40),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                spacing: 8,
                children: [
                  Expanded(child: DifyText(w.title, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
                  if (w.info != null && w.info!.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 200),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: DifyText(w.info!, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                      ),
                    ),
                  DifySwitch(
                    checked: enabled,
                    semanticLabel: w.title,
                    onCheckedChange: (v) => _change('enabled', v),
                  ),
                ],
              ),
            ),
            if (enabled && w.showPreset)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 32,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        spacing: 8,
                        children: [
                          Flexible(
                            child: DifyText(
                              ad('feature.moderation.modal.content.preset'),
                              DifyType.system2xsMediumUppercase,
                              color: DifyColors.textSecondary,
                            ),
                          ),
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: DifyColors.backgroundSection,
                                borderRadius: BorderRadius.circular(DifyRadius.sm),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                spacing: 2,
                                children: [
                                  RemixIcon('markdown-line', size: 12, color: DifyColors.textTertiary),
                                  Flexible(
                                    child: Text(
                                      ad('feature.moderation.modal.content.supportMarkdown').toUpperCase(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: badge,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _CountedTextarea(
                      height: 80,
                      value: _preset,
                      label: ad('feature.moderation.modal.content.preset'),
                      placeholder: ad('feature.moderation.modal.content.placeholder'),
                      onChanged: _presetChange,
                      count: '${_preset.length}',
                      total: '100',
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// FormGeneration: a code-based extension's form (text input, paragraph or select per field), labels in the app's
/// language; each change reports `{...value, [variable]: v}`.
class FormGeneration extends StatelessWidget {
  const FormGeneration({
    super.key,
    required this.forms,
    required this.value,
    required this.onChange,
    this.locale = 'en-US',
  });

  final List<Json> forms;
  final Json value;
  final ValueChanged<Map<String, Object?>> onChange;
  final String locale;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final form in forms) _field(form),
    ],
  );

  Widget _field(Json form) {
    final variable = '${form['variable']}';
    final label = _i18n(form['label'], locale);
    final placeholder = form['placeholder'] as String?;
    final current = '${value[variable] ?? ''}';
    void change(String v) => onChange({...value, variable: v});
    final Widget control = switch (form['type']) {
      'text-input' => DifyInput(
        value: current,
        placeholder: placeholder,
        height: 36,
        semanticLabel: label,
        onChanged: change,
      ),
      'paragraph' => DifyTextarea(value: current, placeholder: placeholder, semanticLabel: label, onChanged: change),
      'select' => DifySelect<String>(
        value: current.isEmpty ? null : current,
        placeholder: placeholder,
        options: [
          for (final o in (form['options'] as List? ?? const []).whereType<Json>())
            (value: '${o['value']}', label: _i18n(o['label'], locale)),
        ],
        onChanged: (v) {
          if (v.isNotEmpty) change(v);
        },
      ),
      _ => const SizedBox.shrink(),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 36,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  height: 20 / 14,
                  fontWeight: FontWeight.w500,
                  color: DifyColors.textPrimary,
                ),
              ),
            ),
          ),
          control,
        ],
      ),
    );
  }
}

/// ApiBasedExtensionSelector: the chosen extension (name and endpoint) or the placeholder; the popover lists the
/// workspace's extensions, "Manage" (the account settings' custom endpoints) and "Add".
class ApiBasedExtensionSelector extends StatefulWidget {
  const ApiBasedExtensionSelector({super.key, required this.value, required this.onChange});
  final String value;
  final ValueChanged<String> onChange;

  @override
  State<ApiBasedExtensionSelector> createState() => _ApiBasedExtensionSelectorState();
}

class _ApiBasedExtensionSelectorState extends State<ApiBasedExtensionSelector> {
  final _floating = DifyFloatingController();

  @override
  Widget build(BuildContext context) {
    final s = FeaturesServicesScope.of(context);
    final items = s.apiBasedExtensions;
    final current = items.where((e) => e['id'] == widget.value).firstOrNull;
    return DifyFloating(
      controller: _floating,
      placement: DifyPlacement.bottomStart,
      sideOffset: 4,
      builder: (context, c) => DifyPressable(
        onPressed: c.toggle,
        builder: (context, hovered, focused) {
          final arrow = Opacity(
            opacity: c.isOpen ? 1 : 0.6,
            child: RemixIcon('arrow-down-s-line', size: 16, color: DifyColors.textSecondary),
          );
          return Container(
            height: 36,
            padding: const EdgeInsets.only(left: 12, right: 10),
            decoration: BoxDecoration(
              color: DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
            ),
            child: current == null
                ? Row(
                    children: [
                      Expanded(
                        child: Text(
                          tc('apiBasedExtension.selector.placeholder'),
                          style: TextStyle(fontSize: 14, color: DifyColors.textQuaternary),
                        ),
                      ),
                      arrow,
                    ],
                  )
                : Row(
                    children: [
                      Text('${current['name']}', style: TextStyle(fontSize: 14, color: DifyColors.textPrimary)),
                      const Spacer(),
                      SizedBox(
                        width: 270,
                        child: Text(
                          '${current['api_endpoint']}',
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: DifyColors.textQuaternary),
                        ),
                      ),
                      const SizedBox(width: 6),
                      arrow,
                    ],
                  ),
          );
        },
      ),
      popupBuilder: (context) => Container(
        width: 576,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          boxShadow: DifyShadows.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tc('apiBasedExtension.selector.title'),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: DifyColors.textTertiary,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            _floating.close();
                            s.openAccountSettings?.call('custom-endpoint');
                          },
                          child: Row(
                            children: [
                              Text(
                                tc('apiBasedExtension.selector.manage'),
                                style: TextStyle(fontSize: 12, color: DifyColors.textAccent),
                              ),
                              const SizedBox(width: 2),
                              DifyIcon(
                                'vender/line/arrows/arrow-up-right',
                                size: 12,
                                color: DifyColors.textAccent,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 250),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final item in items)
                            DifyPressable(
                              onPressed: () {
                                widget.onChange('${item['id']}');
                                _floating.close();
                              },
                              builder: (context, hovered, _) => Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: hovered ? DifyColors.stateBaseHover : null,
                                  borderRadius: BorderRadius.circular(DifyRadius.md),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${item['name']}',
                                      style: TextStyle(fontSize: 14, color: DifyColors.textPrimary),
                                    ),
                                    Text(
                                      '${item['api_endpoint']}',
                                      style: TextStyle(fontSize: 12, color: DifyColors.textTertiary),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: DifyColors.dividerRegular),
            Padding(
              padding: const EdgeInsets.all(4),
              child: DifyPressable(
                onPressed: () {
                  _floating.close();
                  s.addApiBasedExtension?.call();
                },
                builder: (context, hovered, _) => Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      RemixIcon('add-line', size: 16, color: DifyColors.textAccent),
                      const SizedBox(width: 8),
                      Text(tc('operation.add'), style: TextStyle(fontSize: 14, color: DifyColors.textAccent)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
