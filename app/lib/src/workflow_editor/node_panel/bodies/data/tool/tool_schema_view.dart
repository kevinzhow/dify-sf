/// Read-only JSON schema trees: StructureOutputItem (variable/object-child-tree-panel/show: index.tsx, field.tsx),
/// used for object outputs, and SchemaModal (plugin-detail-panel/tool-selector/components/schema-modal.tsx), which
/// Dify draws with the JSON schema visual editor in read-only mode; here the same field tree.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../panel_fields/panel_fields.dart';

/// StructureOutputItem (show/index.tsx): one [SchemaField] per property of [payload]'s `schema` (a structured
/// output `{schema: {type: object, properties, required}}`), pulled 7 px left.
class StructureOutputShow extends StatelessWidget {
  const StructureOutputShow({super.key, required this.payload, this.rootStyle});
  final Map<String, Object?> payload;

  /// `rootClassName` for the root names (`code-sm-semibold text-text-secondary`).
  final DifyTextStyle? rootStyle;

  @override
  Widget build(BuildContext context) {
    final schema = jsGet(payload, 'schema');
    final props = jsGet(schema, 'properties');
    final required = jsList(jsGet(schema, 'required'));
    return Transform.translate(
      offset: const Offset(-7, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (props is Map)
            for (final MapEntry(:key, :value) in props.entries)
              SchemaField(
                name: '$key',
                payload: value is Map ? value.cast<String, Object?>() : const {},
                required: required.contains(key),
                rootStyle: rootStyle,
              ),
        ],
      ),
    );
  }
}

/// show/field.tsx: tree lines for [depth], a fold arrow for objects with properties, the name (`system-sm-medium`,
/// [rootStyle] at the root), the field type (and ` (schemaType)` unless a file), "Required", the description and
/// the enum values; the children below unless folded.
class SchemaField extends StatefulWidget {
  const SchemaField({
    super.key,
    required this.name,
    required this.payload,
    this.required = false,
    this.depth = 1,
    this.rootStyle,
  });

  final String name;
  final Map<String, Object?> payload;
  final bool required;
  final int depth;
  final DifyTextStyle? rootStyle;

  @override
  State<SchemaField> createState() => _SchemaFieldState();
}

class _SchemaFieldState extends State<SchemaField> {
  bool _fold = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final p = w.payload;
    final props = p['properties'];
    final hasChildren = p['type'] == 'object' && props is Map;
    final enums = jsList(p['enum']);
    final schemaType = jsStr(p['schemaType']);
    final rootStyle = w.depth == 1 ? w.rootStyle : null;
    final description = jsStr(p['description']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TreeIndentLine(depth: w.depth),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 24,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 7),
                                    child: DifyText(
                                      w.name,
                                      rootStyle ?? DifyType.systemSmMedium,
                                      color: DifyColors.textSecondary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                DifyText(
                                  '${fieldTypeOf(p)}${schemaType != null && schemaType.isNotEmpty && schemaType != 'file' ? ' ($schemaType)' : ''}',
                                  DifyType.systemXsRegular,
                                  color: DifyColors.textTertiary,
                                ),
                                if (w.required) ...[
                                  const SizedBox(width: 12),
                                  DifyText(
                                    DifyI18n.tr('app', 'structOutput.required'),
                                    DifyType.system2xsMediumUppercase,
                                    color: DifyColors.textWarning,
                                  ),
                                ],
                              ],
                            ),
                            if (hasChildren)
                              Positioned(
                                left: -18,
                                top: 4,
                                child: GestureDetector(
                                  onTap: () => setState(() => _fold = !_fold),
                                  child: Container(
                                    color: DifyColors.componentsPanelBg,
                                    child: RotatedBox(
                                      quarterTurns: _fold ? 3 : 0,
                                      child: RemixIcon(
                                        'arrow-drop-down-line',
                                        size: 16,
                                        color: _fold ? DifyColors.textAccent : DifyColors.textTertiary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (description != null && description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 7),
                          child: DifyText(description, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                        ),
                      if (enums.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 7),
                          child: DifyText(
                            enums.map((e) => e is String ? '"$e"' : '$e').join(' | '),
                            DifyType.systemXsRegular,
                            color: DifyColors.textQuaternary,
                            maxLines: null,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (hasChildren && !_fold)
          for (final MapEntry(:key, :value) in props.entries)
            SchemaField(
              name: '$key',
              payload: value is Map ? value.cast<String, Object?>() : const {},
              depth: w.depth + 1,
              required: jsList(p['required']).contains(key),
            ),
      ],
    );
  }
}

/// SchemaModal: a dialog (`max-w-240 p-0`) titled "Parameter Schema" with a close button, the [schema] as a
/// read-only tree under [rootName].
Future<void> showToolSchemaModal(BuildContext context, {required String rootName, required Object? schema}) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: DifyColors.backgroundOverlay,
      transitionDuration: difyTransitionDuration,
      pageBuilder: (context, _, _) => ToolSchemaModal(rootName: rootName, schema: schema),
    );

class ToolSchemaModal extends StatelessWidget {
  const ToolSchemaModal({super.key, required this.rootName, required this.schema});
  final String rootName;
  final Object? schema;

  @override
  Widget build(BuildContext context) {
    final title = DifyI18n.tr('workflow', 'nodes.agent.parameterSchema');
    final root = schema is Map ? (schema! as Map).cast<String, Object?>() : const <String, Object?>{};
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 960, maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        child: Material(
          type: MaterialType.transparency,
          child: Semantics(
            container: true,
            role: SemanticsRole.dialog,
            label: title,
            explicitChildNodes: true,
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.only(bottom: 24),
              decoration: BoxDecoration(
                color: DifyColors.componentsPanelBg,
                borderRadius: BorderRadius.circular(DifyRadius.xxl),
                boxShadow: DifyShadows.xl,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 24, 56, 12),
                        child: DifyText(title, DifyType.title2xlSemiBold),
                      ),
                      Positioned(
                        top: 20,
                        right: 20,
                        child: DifyIconButton(
                          label: DifyI18n.tr('common', 'operation.close'),
                          size: DifyIconButtonSize.lg,
                          onPressed: () => Navigator.of(context).pop(),
                          icon: RemixIcon('close-line', size: 18, color: DifyColors.textTertiary),
                        ),
                      ),
                    ],
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 18),
                        child: SchemaField(name: rootName, payload: root),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
