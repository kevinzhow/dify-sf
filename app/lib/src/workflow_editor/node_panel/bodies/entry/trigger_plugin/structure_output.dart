/// StructureOutputItem (nodes/_base/components/variable/object-child-tree-panel/show): a structured output's fields as
/// a tree (name, type, "(schemaType)", REQUIRED, description, enum values), objects foldable.
library;

import 'package:flutter/widgets.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../panel_fields/panel_fields.dart';

/// ShowPanel over `payload.schema.properties` (`relative -left-1.75`); the root names in [rootStyle] (Dify's
/// `rootClassName`, `code-sm-semibold text-text-secondary` at the call sites).
class StructureOutputItem extends StatelessWidget {
  const StructureOutputItem({super.key, required this.payload, this.rootStyle = DifyType.codeSmSemibold});

  /// `{schema: {type: object, properties, required?}}`.
  final Json payload;
  final DifyTextStyle rootStyle;

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
          for (final e in jsEntries(props))
            _Field(
              name: e.key,
              payload: e.value is Map ? (e.value! as Map).cast<String, Object?>() : const {},
              required: required.contains(e.key),
              rootStyle: rootStyle,
            ),
        ],
      ),
    );
  }
}

class _Field extends StatefulWidget {
  const _Field({required this.name, required this.payload, required this.required, this.depth = 1, this.rootStyle});
  final String name;
  final Json payload;
  final bool required;
  final int depth;
  final DifyTextStyle? rootStyle;

  @override
  State<_Field> createState() => _FieldState();
}

class _FieldState extends State<_Field> {
  bool _fold = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final p = w.payload;
    final isRoot = w.depth == 1;
    final hasChildren = p['type'] == 'object' && p['properties'] != null;
    final enums = jsList(p['enum']);
    final schemaType = jsStr(p['schemaType']);
    final description = jsStr(p['description']) ?? '';
    final nameStyle = isRoot && w.rootStyle != null ? w.rootStyle! : DifyType.systemSmMedium;
    final row = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TreeIndentLine(depth: w.depth),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 24,
                    child: Row(
                      children: [
                        if (hasChildren)
                          Transform.translate(
                            offset: const Offset(-18, 0),
                            child: GestureDetector(
                              onTap: () => setState(() => _fold = !_fold),
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
                        Padding(
                          padding: EdgeInsets.only(left: hasChildren ? 0 : 7),
                          child: DifyText(w.name, nameStyle, color: DifyColors.textSecondary),
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
                  ),
                  if (description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 7),
                      child: DifyText(description, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                    ),
                  if (enums.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 7),
                      child: DifyText(
                        enums.map((v) => v is String ? '"$v"' : '$v').join(' | '),
                        DifyType.systemXsRegular,
                        color: DifyColors.textQuaternary,
                        maxLines: null,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (!hasChildren || _fold) return row;
    final required = jsList(p['required']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        for (final e in jsEntries(p['properties']))
          _Field(
            name: e.key,
            payload: e.value is Map ? (e.value! as Map).cast<String, Object?>() : const {},
            required: required.contains(e.key),
            depth: w.depth + 1,
          ),
      ],
    );
  }
}
