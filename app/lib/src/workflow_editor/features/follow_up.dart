/// Follow-up (follow-up.tsx, follow-up-setting-modal.tsx): suggested questions after the answer, with the model and
/// prompt that write them.
library;

import 'package:flutter/material.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../node_panel/bodies/llm/group_host.dart';
import '../node_panel/bodies/llm/model_parameter_modal.dart';
import 'features_services.dart';
import 'features_store.dart';
import 'new_feature_panel.dart';
import 'simple_features.dart' show toggleFeature;

/// FollowUp: the switch, the model in use (or "default model") and, while hovered, the settings button.
class FollowUp extends StatefulWidget {
  const FollowUp({super.key, this.disabled = false, this.onChange});
  final bool disabled;
  final OnFeaturesChange? onChange;

  @override
  State<FollowUp> createState() => _FollowUpState();
}

class _FollowUpState extends State<FollowUp> with FeatureHover {
  void _save(Json suggested) {
    final store = FeaturesScope.of(context);
    final next = {
      ...store.features.value,
      FeatureEnum.suggested: {...suggested, 'enabled': true},
    };
    store.setFeatures(next);
    widget.onChange?.call(next);
  }

  void _openSettings() {
    if (widget.disabled) return;
    final suggested = featureMap(FeaturesScope.of(context).features.value, FeatureEnum.suggested);
    final services = LlmGroupScope.of(context);
    showDifyDialog<void>(
      context,
      builder: (dialog) => LlmGroupScope(
        services: services,
        child: FollowUpSettingModal(
          data: suggested.isEmpty ? const {'enabled': true} : suggested,
          onSave: (v) {
            Navigator.of(dialog).pop();
            _save(v);
          },
          onCancel: () => Navigator.of(dialog).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FeaturesBuilder(
    builder: (context, features) {
      final suggested = featureMap(features, FeatureEnum.suggested);
      final enabled = suggested['enabled'] == true;
      final modelName = featureMap(suggested, 'model')['name'];
      return FeatureCard(
        icon: FeatureIcon(
          color: DifyColors.utilColorsBlueLightBlueLight500,
          dify: 'vender/features/virtual-assistant',
        ),
        title: ad('feature.suggestedQuestionsAfterAnswer.title'),
        value: enabled,
        disabled: widget.disabled,
        onChange: (v) => toggleFeature(context, FeatureEnum.suggested, v, widget.onChange, pass: true),
        onMouseEnter: () => setHovering(true),
        onMouseLeave: () => setHovering(false),
        child: !enabled
            ? FeatureDescription(ad('feature.suggestedQuestionsAfterAnswer.description'))
            : isHovering
            ? FeatureCardButton(
                icon: 'equalizer-2-line',
                label: tc('operation.settings'),
                disabled: widget.disabled,
                onPressed: _openSettings,
              )
            : FeatureDescription(
                modelName is String && modelName.isNotEmpty
                    ? modelName
                    : ad('feature.suggestedQuestionsAfterAnswer.modal.defaultModel'),
              ),
      );
    },
  );
}

const _defaultCompletionParams = <String, Object?>{
  'temperature': 0.7,
  'max_tokens': 0,
  'top_p': 0,
  'echo': false,
  'stop': <Object?>[],
  'presence_penalty': 0,
  'frequency_penalty': 0,
};

/// The system's follow-up prompt (DEFAULT_FOLLOW_UP_PROMPT).
const defaultFollowUpPrompt =
    'Please predict the three most likely follow-up questions a user would ask, keep each question under 20 '
    'characters, use the same language as the assistant\'s latest response, and output a JSON array like '
    '["question1", "question2", "question3"].';

/// FollowUpSettingModal: the model (ModelParameterModal; the workspace's default text model when none is set) and
/// the prompt (the system's, or a custom one of at most 1000 characters). Save is off while a custom prompt is empty.
class FollowUpSettingModal extends StatefulWidget {
  const FollowUpSettingModal({super.key, required this.data, required this.onSave, required this.onCancel});
  final Json data;
  final ValueChanged<Json> onSave;
  final VoidCallback onCancel;

  @override
  State<FollowUpSettingModal> createState() => _FollowUpSettingModalState();
}

class _FollowUpSettingModalState extends State<FollowUpSettingModal> {
  late Json _model = () {
    final m = featureMap(widget.data, 'model');
    String s(Object? v) => v is String ? v : '';
    return <String, Object?>{
      'provider': s(m['provider']),
      'name': s(m['name']),
      'mode': s(m['mode']).isEmpty ? 'chat' : m['mode'],
      'completion_params': {...(m['completion_params'] as Map<String, Object?>?) ?? _defaultCompletionParams},
    };
  }();
  late String _prompt = widget.data['prompt'] as String? ?? '';
  late bool _custom = _prompt.isNotEmpty;

  /// `selectedModel`: the chosen model, else the workspace default.
  Json get _selected {
    if ('${_model['provider']}'.isNotEmpty && '${_model['name']}'.isNotEmpty) return _model;
    final d = LlmGroupScope.of(context).defaultModels['llm'];
    return d == null ? _model : {..._model, 'provider': d.provider, 'name': d.model};
  }

  void _save() {
    final selected = _selected;
    final trimmed = _prompt.trim();
    final next = {...widget.data};
    if ('${selected['provider']}'.isNotEmpty && '${selected['name']}'.isNotEmpty) {
      next['model'] = selected;
    } else {
      next.remove('model');
    }
    if (_custom && trimmed.isNotEmpty) {
      next['prompt'] = trimmed;
    } else {
      next.remove('prompt');
    }
    widget.onSave(next);
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: DifyText(text, DifyType.systemSmSemiboldUppercase, color: DifyColors.textSecondary),
  );

  Widget _option({required bool custom, required String title, required String desc, required Widget body}) {
    final checked = _custom == custom;
    return _OptionButton(
      checked: checked,
      onTap: () => setState(() => _custom = custom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DifyText(title, DifyType.systemSmSemibold, maxLines: null),
                    const SizedBox(height: 4),
                    DifyText(desc, DifyType.systemXsRegular, color: DifyColors.textTertiary, maxLines: null),
                  ],
                ),
              ),
              DifyRadioControl(checked: checked),
            ],
          ),
          if (checked) Padding(padding: const EdgeInsets.only(top: 12), child: body),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    const m = 'feature.suggestedQuestionsAfterAnswer.modal.';
    return DifyDialogSurface(
      width: 640,
      label: ad('${m}title'),
      scrollable: true,
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 24),
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 32),
                child: Text(
                  ad('${m}title'),
                  style: TextStyle(
                    fontSize: 20,
                    height: 28 / 20,
                    fontWeight: FontWeight.w600,
                    color: DifyColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _label(ad('${m}modelLabel')),
              ModelParameterModal(
                popupWidth: 520,
                provider: '${selected['provider']}',
                modelId: '${selected['name']}',
                completionParams: featureMap(selected, 'completion_params'),
                onModelChange: (v) => setState(
                  () => _model = {
                    ..._model,
                    'provider': v.provider,
                    'name': v.modelId,
                    'mode': v.mode ?? _model['mode'] ?? 'chat',
                  },
                ),
                onCompletionParamsChange: (p) => setState(() => _model = {...selected, 'completion_params': p}),
              ),
              const SizedBox(height: 16),
              _label(ad('${m}promptLabel')),
              _option(
                custom: false,
                title: ad('${m}defaultPromptOption'),
                desc: ad('${m}defaultPromptOptionDescription'),
                body: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: DifyColors.componentsInputBgNormal,
                    border: Border.all(color: DifyColors.componentsInputBorderActive),
                    borderRadius: BorderRadius.circular(DifyRadius.lg),
                  ),
                  child: DifyText(
                    defaultFollowUpPrompt,
                    DifyType.systemSmRegular,
                    color: DifyColors.textSecondary,
                    maxLines: null,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _option(
                custom: true,
                title: ad('${m}customPromptOption'),
                desc: ad('${m}customPromptOptionDescription'),
                body: DifyTextarea(
                  value: _prompt,
                  minHeight: 128,
                  maxLength: 1000,
                  semanticLabel: ad('${m}customPromptOption'),
                  placeholder: ad('${m}promptPlaceholder'),
                  onChanged: (v) => setState(() => _prompt = v),
                ),
              ),
              const SizedBox(height: 24),
              FeatureFooter([
                DifyButton(onPressed: widget.onCancel, child: Text(tc('operation.cancel'))),
                DifyButton(
                  variant: DifyButtonVariant.primary,
                  disabled: _custom && _prompt.trim().isEmpty,
                  onPressed: _save,
                  child: Text(tc('operation.save')),
                ),
              ]),
            ],
          ),
          Positioned(
            top: 0,
            right: 0,
            child: DifyIconButton(
              label: tc('operation.close'),
              size: DifyIconButtonSize.lg,
              icon: const RemixIcon('close-line', size: 16),
              onPressed: widget.onCancel,
            ),
          ),
        ],
      ),
    );
  }
}

/// A RadioItem card: `rounded-xl border p-4`, `hover:bg-state-base-hover`, checked
/// `border-components-option-card-option-selected-border bg-components-option-card-option-selected-bg`. A click
/// anywhere on it selects it (the custom prompt's textarea keeps its own clicks and keys).
class _OptionButton extends StatefulWidget {
  const _OptionButton({required this.checked, required this.onTap, required this.child});
  final bool checked;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_OptionButton> createState() => _OptionButtonState();
}

class _OptionButtonState extends State<_OptionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    checked: widget.checked,
    inMutuallyExclusiveGroup: true,
    onTap: widget.onTap,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: difyTransitionDuration,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: widget.checked
                ? DifyColors.componentsOptionCardOptionSelectedBg
                : _hovered
                ? DifyColors.stateBaseHover
                : DifyColors.componentsOptionCardOptionBg,
            border: Border.all(
              color: widget.checked
                  ? DifyColors.componentsOptionCardOptionSelectedBorder
                  : DifyColors.componentsOptionCardOptionBorder,
            ),
            borderRadius: BorderRadius.circular(DifyRadius.xl),
          ),
          child: widget.child,
        ),
      ),
    ),
  );
}
