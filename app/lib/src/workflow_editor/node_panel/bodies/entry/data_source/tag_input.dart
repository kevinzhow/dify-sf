/// TagInput (base/tag-input): the tags with a remove button each, then a dashed "+" field that adds its trimmed text
/// on Enter or blur (empty ignored, or refused when `required`; duplicates and tags over 20 characters refused with
/// a toast).
library;

import 'package:flutter/material.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/css_metrics.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';

String _docs(String key) => DifyI18n.tr('dataset-documents', key);

class TagInput extends StatefulWidget {
  const TagInput({
    super.key,
    required this.items,
    required this.onChange,
    this.placeholder,
    this.disableAdd = false,
    this.disableRemove = false,
    this.required = false,
    this.isInWorkflow = false,
    this.onError,
  });

  final List<String> items;
  final ValueChanged<List<String>> onChange;
  final String? placeholder;
  final bool disableAdd, disableRemove, required, isInWorkflow;

  /// `toast.error`.
  final ValueChanged<String>? onError;

  @override
  State<TagInput> createState() => _TagInputState();
}

class _TagInputState extends State<TagInput> {
  final _text = TextEditingController();
  late final _focus = FocusNode(debugLabel: 'TagInput')..addListener(_onFocus);
  bool _focused = false;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focus.hasFocus == _focused) return;
    setState(() => _focused = _focus.hasFocus);
    if (!_focus.hasFocus) _newTag(_text.text);
  }

  /// `handleNewTag`.
  void _newTag(String value) {
    final w = widget;
    final v = value.trim();
    if (v.isEmpty) {
      if (w.required) w.onError?.call(_docs('segment.keywordEmpty'));
      return;
    }
    if (w.items.contains(v)) {
      w.onError?.call(_docs('segment.keywordDuplicate'));
      return;
    }
    if (v.length > 20) {
      w.onError?.call(_docs('segment.keywordError'));
      return;
    }
    w.onChange([...w.items, v]);
    _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final placeholder = w.placeholder ?? _docs('segment.addKeyWord');
    final style = difyStyle(DifyType.systemXsRegular, DifyColors.textPrimary);
    final hintStyle = style.copyWith(color: DifyColors.textPlaceholder);
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: w.isInWorkflow ? 0 : 200),
      child: Wrap(
        children: [
          for (final (i, item) in w.items.indexed)
            Container(
              margin: const EdgeInsets.only(top: 4, right: 4),
              padding: const EdgeInsets.fromLTRB(6, 4, 4, 4),
              decoration: BoxDecoration(
                color: DifyColors.componentsBadgeWhiteToDark,
                border: Border.all(color: DifyColors.dividerDeep),
                borderRadius: BorderRadius.circular(DifyRadius.md),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DifyText(item, DifyType.systemXsRegular, color: DifyColors.textSecondary),
                  if (!w.disableRemove)
                    DifyPressable(
                      semanticLabel: '${DifyI18n.tr('common', 'operation.remove')} $item',
                      onPressed: () => w.onChange([...w.items]..removeAt(i)),
                      builder: (context, hovered, focused) => const SizedBox(
                        width: 16,
                        height: 16,
                        child: Center(child: RemixIcon('close-line', size: 14, color: DifyColors.textTertiary)),
                      ),
                    ),
                ],
              ),
            ),
          if (!w.disableAdd)
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              foregroundDecoration: const _DashedBorder(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 2,
                children: [
                  if (!_focused) const RemixIcon('add-line', size: 14, color: DifyColors.textPlaceholder),
                  ListenableBuilder(
                    listenable: _text,
                    builder: (context, _) {
                      final shown = _text.text.isEmpty ? placeholder : _text.text;
                      final p = TextPainter(
                        text: TextSpan(text: shown, style: style),
                        textDirection: TextDirection.ltr,
                        maxLines: 1,
                      )..layout();
                      final width = p.width.ceilToDouble() + 2;
                      p.dispose();
                      return SizedBox(
                        width: width.clamp(0, w.isInWorkflow ? 146 : 300),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: TextField(
                            controller: _text,
                            focusNode: _focus,
                            style: style,
                            cursorColor: const Color(0xFF295EFF),
                            cursorWidth: 1,
                            decoration: InputDecoration.collapsed(hintText: placeholder, hintStyle: hintStyle),
                            // Enter adds the tag and keeps the focus (no blur, which would add again).
                            onEditingComplete: () {},
                            onSubmitted: _newTag,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// `rounded-md border border-dashed border-divider-deep`.
class _DashedBorder extends Decoration {
  const _DashedBorder();

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _DashedPainter();
}

class _DashedPainter extends BoxPainter {
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size!;
    final rect = (offset & size).deflate(0.5);
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(DifyRadius.md)));
    final paint = Paint()
      ..color = DifyColors.dividerDeep
      ..style = PaintingStyle.stroke
      ..strokeWidth = Css.hairline * 2;
    for (final m in path.computeMetrics()) {
      for (var d = 0.0; d < m.length; d += 6) {
        canvas.drawPath(m.extractPath(d, d + 3), paint);
      }
    }
  }
}
