/// The Web App's hidden Start inputs (Dify 1.17.1 app/overview/workflow-hidden-input-fields.tsx and
/// workflow-launch-dialog): the fields for each hidden variable, and the "Configure" dialog that opens the Web App
/// with them as search parameters.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../open_url.dart';
import 'access_point_utils.dart';

String _t(String ns, String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr(ns, key, params);

String _labelOf(Json variable) => switch (variable['label']) {
  final String label => label,
  _ => '${variable['variable']}',
};

/// WorkflowHiddenInputFields: per variable its label (`system-sm-medium text-text-secondary`, not for checkboxes) and
/// its control: a select, a checkbox row (`min-h-10 rounded-lg bg-components-input-bg-normal px-3 py-2`), a textarea
/// (`min-h-24`, paragraphs and JSON) or an input (`type="number"` for numbers), the label as placeholder. Fields are
/// keyed `<fieldIdPrefix>-<variable>`.
class WorkflowHiddenInputFields extends StatelessWidget {
  const WorkflowHiddenInputFields({
    super.key,
    required this.hiddenVariables,
    required this.values,
    required this.onValueChange,
    this.fieldIdPrefix = 'workflow-launch-hidden-input',
  });

  final List<Json> hiddenVariables;
  final Map<String, LaunchValue> values;
  final void Function(String variable, LaunchValue value) onValueChange;
  final String fieldIdPrefix;

  Widget _field(Json variable) {
    final name = '${variable['variable']}';
    final key = ValueKey('$fieldIdPrefix-$name');
    final value = values[name];
    final label = _labelOf(variable);
    final text = value is String ? value : '';
    final maxLength = variable['max_length'] is num ? (variable['max_length']! as num).toInt() : null;
    switch (variable['type']) {
      case 'select':
        return DifySelect<String>(
          key: key,
          value: text.isEmpty ? null : text,
          semanticLabel: label,
          placeholder: label,
          options: [
            for (final o in (variable['options'] as List?) ?? const []) (value: '$o', label: '$o'),
          ],
          onChanged: (v) => onValueChange(name, v),
        );
      case 'checkbox':
        return Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: DifyColors.componentsInputBgNormal,
            borderRadius: BorderRadius.circular(DifyRadius.lg),
          ),
          child: Row(
            spacing: 12,
            children: [
              DifyCheckbox(key: key, checked: value == true, label: label, onChanged: (v) => onValueChange(name, v)),
              Expanded(
                child: DifyTextLine(label, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary)),
              ),
            ],
          ),
        );
      case 'paragraph' || 'json' || 'json_object':
        return DifyTextarea(
          key: key,
          value: text,
          placeholder: label,
          semanticLabel: label,
          maxLength: maxLength,
          minHeight: 96,
          onChanged: (v) => onValueChange(name, v),
        );
      default:
        return DifyInput(
          key: key,
          value: text,
          placeholder: label,
          semanticLabel: label,
          maxLength: maxLength,
          keyboardType: variable['type'] == 'number' ? TextInputType.number : null,
          onChanged: (v) => onValueChange(name, v),
        );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 16,
    children: [
      for (final v in hiddenVariables)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            if (v['type'] != 'checkbox')
              ExcludeSemantics(
                child: DifyTextLine(
                  _labelOf(v),
                  style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                ),
              ),
            _field(v),
          ],
        ),
    ],
  );
}

/// Shows [WorkflowLaunchDialog] (nothing when there are no hidden variables).
Future<void> showWorkflowLaunchDialog(
  BuildContext context, {
  required List<Json> hiddenVariables,
  required String targetUrl,
  void Function(String url)? openUrl,
}) async {
  if (hiddenVariables.isEmpty) return;
  await showDifyDialog<void>(
    context,
    builder: (context) =>
        WorkflowLaunchDialog(hiddenVariables: hiddenVariables, targetUrl: targetUrl, openUrl: openUrl),
  );
}

/// WorkflowLaunchDialog (`w-140 p-0`): "Configure hidden inputs" with its description, the supported hidden
/// variables' fields (their defaults first; reset on every opening) and Cancel / Launch, which opens [targetUrl]
/// with the values ([buildWorkflowLaunchUrl]) and closes.
class WorkflowLaunchDialog extends StatefulWidget {
  const WorkflowLaunchDialog({super.key, required this.hiddenVariables, required this.targetUrl, this.openUrl});

  final List<Json> hiddenVariables;
  final String targetUrl;

  /// `window.open(url, '_blank')`; the app's external opener by default.
  final void Function(String url)? openUrl;

  @override
  State<WorkflowLaunchDialog> createState() => _WorkflowLaunchDialogState();
}

class _WorkflowLaunchDialogState extends State<WorkflowLaunchDialog> {
  late final _supported = widget.hiddenVariables.where(isWorkflowLaunchInputSupported).toList();
  late final _values = workflowLaunchInitialValues(_supported);

  void _launch() {
    final url = buildWorkflowLaunchUrl(accessibleUrl: widget.targetUrl, variables: _supported, values: _values);
    (widget.openUrl ?? (u) => unawaited(openExternalUrl(u)))(url);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final title = _t('appOverview', 'overview.appInfo.workflowLaunchHiddenInputs.title');
    final description = _t('appOverview', 'overview.appInfo.workflowLaunchHiddenInputs.description');
    return DifyDialogSurface(
      label: title,
      width: 560,
      bordered: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                DifyTextLine(title, style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary)),
                _BoldTrans(description, style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textTertiary)),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: WorkflowHiddenInputFields(
                hiddenVariables: _supported,
                values: _values,
                onValueChange: (k, v) => setState(() => _values[k] = v),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: DifyColors.dividerSubtle, width: 0.5)),
            ),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                DifyButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: DifyTextLine(_t('common', 'operation.cancel')),
                ),
                DifyButton(
                  key: const ValueKey('workflow-launch'),
                  variant: DifyButtonVariant.primary,
                  onPressed: _launch,
                  child: DifyTextLine(_t('appOverview', 'overview.appInfo.launch')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `<Trans components={{ bold: <span className="system-md-medium" /> }}>`: `<bold>…</bold>` parts in medium weight.
class _BoldTrans extends StatelessWidget {
  const _BoldTrans(this.text, {required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    final re = RegExp('<bold>(.*?)</bold>', dotAll: true);
    var at = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > at) spans.add(TextSpan(text: text.substring(at, m.start)));
      spans.add(
        TextSpan(
          text: m[1],
          style: DifyType.systemMdMedium.style, // `system-md-medium`
        ),
      );
      at = m.end;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return DifyTextLine.rich(TextSpan(style: style, children: spans));
  }
}
