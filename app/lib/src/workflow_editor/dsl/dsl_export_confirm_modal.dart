/// dsl-export-confirm-modal.tsx and workflow-app/hooks/use-DSL.ts `exportCheck`: exporting a workflow whose
/// environment holds secrets first asks whether to export their values.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../panel_fields/form_controls.dart' show DifyCheckbox;

String _tw(String key) => DifyI18n.tr('workflow', key);
String _tc(String key) => DifyI18n.tr('common', key);

/// `exportCheck`: with no secret among [environmentVariables] (Dify JSON: `name`, `value`, `value_type`) the
/// workflow is exported at once without secrets; otherwise [DslExportConfirmContent] asks first.
Future<void> exportDslWithCheck(
  BuildContext context, {
  required List<Map<String, Object?>> environmentVariables,
  required Future<void> Function(bool includeSecret) export,
}) async {
  final secrets = [
    for (final v in environmentVariables)
      if (v['value_type'] == 'secret') v,
  ];
  if (secrets.isEmpty) return export(false);
  await showDslExportConfirm(context, envList: secrets, onConfirm: export);
}

/// DSLExportConfirmModal: the dialog (closed by Cancel, by a confirmed export, or outside it while not exporting).
Future<void> showDslExportConfirm(
  BuildContext context, {
  required List<Map<String, Object?>> envList,
  required Future<void> Function(bool exportSecrets) onConfirm,
}) async {
  if (envList.isEmpty) return;
  var exporting = false;
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: DifyColors.backgroundOverlay,
    transitionDuration: difyTransitionDuration,
    transitionBuilder: (context, animation, _, child) {
      final a = CurvedAnimation(parent: animation, curve: difyTransitionCurve);
      return FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.95, end: 1.0).animate(a), child: child),
      );
    },
    pageBuilder: (context, _, _) => Stack(
      children: [
        // A click outside closes it, unless an export is running (handleOpenChange).
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (!exporting) Navigator.of(context).pop();
            },
          ),
        ),
        Center(
          child: DslExportConfirmContent(
            envList: envList,
            onConfirm: onConfirm,
            onClose: () => Navigator.of(context).pop(),
            onExportingChange: (v) => exporting = v,
          ),
        ),
      ],
    ),
  );
}

/// DSLExportConfirmContent: `w-120` with the title, the secrets' table (name with the env icon, "Secret" and a lock;
/// the value as the server sends it), the "export secret values" checkbox, and Cancel / Ignore (or Export).
class DslExportConfirmContent extends StatefulWidget {
  const DslExportConfirmContent({
    super.key,
    required this.envList,
    required this.onConfirm,
    required this.onClose,
    this.onExportingChange,
  });

  final List<Map<String, Object?>> envList;
  final Future<void> Function(bool exportSecrets) onConfirm;
  final VoidCallback onClose;
  final ValueChanged<bool>? onExportingChange;

  @override
  State<DslExportConfirmContent> createState() => _DslExportConfirmContentState();
}

class _DslExportConfirmContentState extends State<DslExportConfirmContent> {
  bool _exportSecrets = false, _exporting = false;

  Future<void> _submit() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    widget.onExportingChange?.call(true);
    try {
      await widget.onConfirm(_exportSecrets);
      widget.onClose();
    } finally {
      if (mounted) setState(() => _exporting = false);
      widget.onExportingChange?.call(false);
    }
  }

  static String _value(Object? v) => v is Map || v is List ? jsonEncode(v) : '$v';

  Widget _cell(Widget child, {required bool last, bool right = false, double? width}) => Container(
    width: width,
    height: 28,
    padding: const EdgeInsets.only(left: 12),
    alignment: Alignment.centerLeft,
    decoration: BoxDecoration(
      border: Border(
        right: right ? BorderSide(color: DifyColors.dividerRegular, width: Css.hairline * 2) : BorderSide.none,
        bottom: last ? BorderSide.none : BorderSide(color: DifyColors.dividerRegular, width: Css.hairline * 2),
      ),
    ),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final envs = widget.envList;
    final head = difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary);
    final confirmLabel = _exporting
        ? _tc('operation.exporting')
        : _exportSecrets
        ? _tw('env.export.export')
        : _tw('env.export.ignore');
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        container: true,
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: _tw('env.export.title'),
        child: Container(
          key: const ValueKey('dsl-export-confirm'),
          width: 480,
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBg,
            borderRadius: BorderRadius.circular(DifyRadius.xxl),
            border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
            boxShadow: DifyShadows.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: Text(
                        _tw('env.export.title'),
                        style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                      ),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(DifyRadius.lg),
                        border: Border.all(color: DifyColors.dividerRegular),
                        boxShadow: DifyShadows.xs,
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              _cell(Text(_tw('env.export.name'), style: head), last: false, right: true, width: 220),
                              Expanded(child: _cell(Text(_tw('env.export.value'), style: head), last: false)),
                            ],
                          ),
                          for (final (i, env) in envs.indexed)
                            Row(
                              key: ValueKey('env-row-${env['name']}'),
                              children: [
                                _cell(
                                  SizedBox(
                                    width: 200,
                                    child: Row(
                                      spacing: 4,
                                      children: [
                                        const DifyIcon(
                                          'vender/line/others/env',
                                          size: 16,
                                          color: DifyColors.utilColorsVioletViolet600,
                                        ),
                                        Flexible(
                                          child: Text(
                                            '${env['name']}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textPrimary),
                                          ),
                                        ),
                                        // `shrink-0`; bounded so a long translation cannot push the row over.
                                        ConstrainedBox(
                                          constraints: const BoxConstraints(maxWidth: 80),
                                          child: Text(
                                            _tw('env.export.secret'),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textTertiary),
                                          ),
                                        ),
                                        const RemixIcon('lock-2-line', size: 12, color: DifyColors.textTertiary),
                                      ],
                                    ),
                                  ),
                                  last: i + 1 == envs.length,
                                  right: true,
                                  width: 220,
                                ),
                                Expanded(
                                  child: _cell(
                                    Text(
                                      _value(env['value']),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textSecondary),
                                    ),
                                    last: i + 1 == envs.length,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    // The label toggles the checkbox too.
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: MouseRegion(
                        cursor: _exporting ? SystemMouseCursors.basic : SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _exporting ? null : () => setState(() => _exportSecrets = !_exportSecrets),
                          child: Row(
                            spacing: 8,
                            children: [
                              DifyCheckbox(
                                checked: _exportSecrets,
                                disabled: _exporting,
                                label: _tw('env.export.checkbox'),
                                onChanged: (v) => setState(() => _exportSecrets = v),
                              ),
                              Flexible(
                                child: Opacity(
                                  opacity: _exporting ? 0.5 : 1,
                                  child: Text(
                                    _tw('env.export.checkbox'),
                                    style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textPrimary),
                                  ),
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
              Padding(
                padding: const EdgeInsets.all(24),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    DifyButton(
                      key: const ValueKey('dsl-export-cancel'),
                      disabled: _exporting,
                      semanticLabel: _tc('operation.cancel'),
                      onPressed: widget.onClose,
                      child: Text(_tc('operation.cancel')),
                    ),
                    DifyButton(
                      key: const ValueKey('dsl-export-confirm-button'),
                      variant: DifyButtonVariant.primary,
                      loading: _exporting,
                      semanticLabel: confirmLabel,
                      onPressed: () => unawaited(_submit()),
                      child: Text(confirmLabel),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
