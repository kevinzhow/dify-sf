import 'package:flutter/material.dart';

import '../../cards/bodies/note_body.dart';
import '../../cards/bodies/note_text.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import 'note_editor.dart';

String _tw(String key) => DifyI18n.tr('workflow', key);

/// `text-primary-600`.
const _primary600 = Color(0xFF155EEF);

/// toolbar/index.tsx: the colour picker, font size, the formatting commands and the "…" menu, in
/// `inline-flex items-center rounded-lg border-[0.5px] border-components-actionbar-border bg-components-actionbar-bg
/// p-0.5 shadow-sm`. Taps on it leave the editor focused.
class NoteEditorToolbar extends StatelessWidget {
  const NoteEditorToolbar({
    super.key,
    required this.theme,
    required this.onThemeChange,
    required this.onCopy,
    required this.onDuplicate,
    required this.onDelete,
    required this.showAuthor,
    required this.onShowAuthorChange,
  });

  final NoteTheme theme;
  final ValueChanged<NoteTheme> onThemeChange;
  final VoidCallback onCopy, onDuplicate, onDelete;
  final bool showAuthor;
  final ValueChanged<bool> onShowAuthorChange;

  @override
  Widget build(BuildContext context) => NoteTextScope(
    child: TextFieldTapRegion(
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: DifyColors.componentsActionbarBg,
          border: Border.all(color: DifyColors.componentsActionbarBorder, width: Css.hairline),
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          boxShadow: DifyShadows.sm,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            NoteColorPicker(theme: theme, onThemeChange: onThemeChange),
            const NoteToolbarDivider(),
            const NoteFontSizeSelector(),
            const NoteToolbarDivider(),
            const Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: [
                NoteCommand(NoteCommandType.bold),
                NoteCommand(NoteCommandType.italic),
                NoteCommand(NoteCommandType.strikethrough),
                NoteCommand(NoteCommandType.link),
                NoteCommand(NoteCommandType.bullet),
              ],
            ),
            const NoteToolbarDivider(),
            NoteOperator(
              onCopy: onCopy,
              onDuplicate: onDuplicate,
              onDelete: onDelete,
              showAuthor: showAuthor,
              onShowAuthorChange: onShowAuthorChange,
            ),
          ],
        ),
      ),
    ),
  );
}

/// toolbar/divider.tsx: `mx-1 h-3.5 w-px bg-divider-regular`.
class NoteToolbarDivider extends StatelessWidget {
  const NoteToolbarDivider({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 14,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    color: DifyColors.dividerRegular,
  );
}

/// A swatch: `size-4 rounded-full border border-black/5` in the theme's title colour.
Widget _swatch(NoteTheme t) => Container(
  width: 16,
  height: 16,
  decoration: BoxDecoration(
    color: t.title,
    shape: BoxShape.circle,
    border: Border.all(color: const Color(0x0D000000)),
  ),
);

/// toolbar/color-picker.tsx: the theme's swatch (`size-8`, `hover:bg-black/5`) opening the six themes above it
/// (3 × 2, sideOffset 4); a hovered one shows its ring.
class NoteColorPicker extends StatefulWidget {
  const NoteColorPicker({super.key, required this.theme, required this.onThemeChange});

  final NoteTheme theme;
  final ValueChanged<NoteTheme> onThemeChange;

  @override
  State<NoteColorPicker> createState() => _NoteColorPickerState();
}

class _NoteColorPickerState extends State<NoteColorPicker> {
  final _menu = DifyFloatingController();
  bool _open = false;

  @override
  Widget build(BuildContext context) => DifyPopover(
    controller: _menu,
    placement: DifyPlacement.top,
    sideOffset: 4,
    surface: false,
    onOpenChange: (open) => setState(() => _open = open),
    builder: (context, menu) => DifyPressable(
      semanticLabel: widget.theme.name,
      onPressed: menu.toggle,
      builder: (context, hovered, focused) => Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: hovered || _open ? const Color(0x0D000000) : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: _swatch(widget.theme),
      ),
    ),
    content: TextFieldTapRegion(
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: DifyColors.componentsActionbarBg,
          border: Border.all(color: DifyColors.componentsActionbarBorder, width: Css.hairline),
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          boxShadow: DifyShadows.lg,
        ),
        child: SizedBox(
          width: 3 * 32 + 2 * 2,
          child: Wrap(
            spacing: 2,
            runSpacing: 2,
            children: [
              for (final t in NoteTheme.values)
                _ColorOption(
                  key: ValueKey('note-theme-${t.name}'),
                  theme: t,
                  onSelect: () {
                    widget.onThemeChange(t);
                    _menu.close();
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ColorOption extends StatelessWidget {
  const _ColorOption({super.key, required this.theme, required this.onSelect});
  final NoteTheme theme;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: theme.name,
    onPressed: onSelect,
    builder: (context, hovered, focused) => SizedBox(
      width: 32,
      height: 32,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (hovered)
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: theme.outer, width: 1.5),
              ),
            ),
          _swatch(theme),
        ],
      ),
    ),
  );
}

/// toolbar/font-size-selector.tsx: Small 12px (default), Medium 14px, Large 16px.
const noteFontSizes = ['12px', '14px', '16px'];
String noteFontSizeLabel(String key) => switch (key) {
  '14px' => _tw('nodes.note.editor.medium'),
  '16px' => _tw('nodes.note.editor.large'),
  _ => _tw('nodes.note.editor.small'),
};

/// The font size of the selection (`h-8 text-[13px] font-medium` with RiFontSize) opening the three sizes below
/// it (`w-30`, sideOffset 2), each in its own size, the current one checked. Opening keeps the editor's selection.
class NoteFontSizeSelector extends StatefulWidget {
  const NoteFontSizeSelector({super.key});

  @override
  State<NoteFontSizeSelector> createState() => _NoteFontSizeSelectorState();
}

class _NoteFontSizeSelectorState extends State<NoteFontSizeSelector> {
  final _menu = DifyFloatingController();
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scope = NoteEditorScope.of(context);
    final c = scope.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final size = c.fontSize;
        return DifyPopover(
          controller: _menu,
          placement: DifyPlacement.bottomStart,
          sideOffset: 2,
          surface: false,
          onOpenChange: (open) => setState(() => _open = open),
          builder: (context, menu) => DifyPressable(
            onPressed: menu.toggle,
            builder: (context, hovered, focused) {
              final active = hovered || _open;
              final color = active ? DifyColors.textSecondary : DifyColors.textTertiary;
              return Container(
                height: 32,
                padding: const EdgeInsets.only(left: 8, right: 6),
                decoration: BoxDecoration(
                  color: active ? DifyColors.stateBaseHover : null,
                  borderRadius: BorderRadius.circular(DifyRadius.md),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RemixIcon('font-size', size: 16, color: color),
                    const SizedBox(width: 4),
                    Text(
                      noteFontSizeLabel(size),
                      style: TextStyle(
                        fontFamily: cardFontFamily,
                        fontSize: 13,
                        height: 16 / 13,
                        fontWeight: FontWeight.w500,
                        color: color,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          content: NoteTextScope(
            child: TextFieldTapRegion(
              child: Container(
                width: 120,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: DifyColors.componentsPanelBgBlur,
                  border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
                  borderRadius: BorderRadius.circular(DifyRadius.md),
                  boxShadow: DifyShadows.xl,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final key in noteFontSizes)
                      DifyPressable(
                        onPressed: () {
                          c.setFontSize(key);
                          _menu.close();
                          scope.refocus();
                        },
                        builder: (context, hovered, focused) => Container(
                          height: 32,
                          padding: const EdgeInsets.only(left: 12, right: 8),
                          decoration: BoxDecoration(
                            color: hovered ? DifyColors.stateBaseHover : null,
                            borderRadius: BorderRadius.circular(DifyRadius.md),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  noteFontSizeLabel(key),
                                  style: TextStyle(
                                    fontFamily: cardFontFamily,
                                    fontSize: double.parse(key.replaceAll('px', '')),
                                    color: DifyColors.textSecondary,
                                  ),
                                ),
                              ),
                              if (size == key)
                                DifyIcon(
                                  'vender/line/general/check',
                                  size: 16,
                                  color: DifyColors.textAccent,
                                  key: ValueKey('note-font-size-check'),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

enum NoteCommandType {
  bold('bold', 'nodes.note.editor.bold'),
  italic('italic', 'nodes.note.editor.italic'),
  strikethrough('strikethrough', 'nodes.note.editor.strikethrough'),
  link('link', 'nodes.note.editor.link'),
  bullet('list-unordered', 'nodes.note.editor.bulletList');

  const NoteCommandType(this.icon, this.tip);
  final String icon, tip;
}

/// toolbar/command.tsx: a `size-8` button (`text-text-tertiary hover:bg-state-accent-active hover:text-text-accent`),
/// highlighted while the selection has the format (`bg-state-accent-active`, icon `text-primary-600`), with its tip.
class NoteCommand extends StatelessWidget {
  const NoteCommand(this.type, {super.key});
  final NoteCommandType type;

  @override
  Widget build(BuildContext context) {
    final scope = NoteEditorScope.of(context);
    final c = scope.controller;
    return ListenableBuilder(
      listenable: c.store,
      builder: (context, _) {
        final s = c.store;
        final active = switch (type) {
          NoteCommandType.bold => s.selectedIsBold,
          NoteCommandType.italic => s.selectedIsItalic,
          NoteCommandType.strikethrough => s.selectedIsStrikeThrough,
          NoteCommandType.link => s.selectedIsLink,
          NoteCommandType.bullet => s.selectedIsBullet,
        };
        final tip = _tw(type.tip);
        return DifyTooltip(
          content: Text(tip),
          child: DifyPressable(
            key: ValueKey('note-command-${type.name}'),
            semanticLabel: tip,
            onPressed: () {
              switch (type) {
                case NoteCommandType.bold:
                  c.formatText(NoteFormat.bold);
                case NoteCommandType.italic:
                  c.formatText(NoteFormat.italic);
                case NoteCommandType.strikethrough:
                  c.formatText(NoteFormat.strikethrough);
                case NoteCommandType.link:
                  c.toggleLink();
                case NoteCommandType.bullet:
                  c.toggleBullet();
              }
              if (type != NoteCommandType.link) scope.refocus();
            },
            builder: (context, hovered, focused) => Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active || hovered ? DifyColors.stateAccentActive : null,
                borderRadius: BorderRadius.circular(DifyRadius.md),
              ),
              child: RemixIcon(
                type.icon,
                size: 16,
                color: active
                    ? _primary600
                    : hovered
                    ? DifyColors.textAccent
                    : DifyColors.textTertiary,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// toolbar/operator.tsx: the "…" menu (`min-w-48`, bottom-end): Copy and Duplicate with their shortcuts, the Show
/// Author switch (toggling it keeps the menu open), Delete.
class NoteOperator extends StatefulWidget {
  const NoteOperator({
    super.key,
    required this.onCopy,
    required this.onDuplicate,
    required this.onDelete,
    required this.showAuthor,
    required this.onShowAuthorChange,
  });

  final VoidCallback onCopy, onDuplicate, onDelete;
  final bool showAuthor;
  final ValueChanged<bool> onShowAuthorChange;

  @override
  State<NoteOperator> createState() => _NoteOperatorState();
}

class _NoteOperatorState extends State<NoteOperator> {
  bool _open = false;
  late bool _showAuthor = widget.showAuthor;

  @override
  void didUpdateWidget(NoteOperator old) {
    super.didUpdateWidget(old);
    _showAuthor = widget.showAuthor;
  }

  Widget _item(String label, String shortcut, VoidCallback onSelect, {bool destructive = false}) => DifyMenuItem(
    onSelect: onSelect,
    variant: destructive ? DifyMenuItemVariant.destructive : DifyMenuItemVariant.normal,
    trailing: Padding(
      padding: const EdgeInsets.only(left: 12, right: 4),
      child: DifyShortcutKbd(shortcut: shortcut),
    ),
    child: Padding(padding: const EdgeInsets.only(left: 4), child: Text(label)),
  );

  @override
  Widget build(BuildContext context) => DifyDropdownMenu(
    width: 192,
    onOpenChange: (open) => setState(() => _open = open),
    builder: (context, menu) => DifyPressable(
      semanticLabel: DifyI18n.tr('common', 'operation.more'),
      onPressed: menu.toggle,
      builder: (context, hovered, focused) => Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: hovered || _open ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: RemixIcon(
          'more-fill',
          size: 16,
          color: hovered || _open ? DifyColors.textSecondary : DifyColors.textTertiary,
        ),
      ),
    ),
    children: [
      _item(_tw('common.copy'), 'workflow.copy', widget.onCopy),
      _item(_tw('common.duplicate'), 'workflow.duplicate', widget.onDuplicate),
      const DifyMenuSeparator(),
      StatefulBuilder(
        builder: (context, setLocal) => Container(
          height: 32,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _tw('nodes.note.editor.showAuthor'),
                  style: difyStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
                ),
              ),
              DifySwitch(
                size: DifySwitchSize.lg,
                checked: _showAuthor,
                semanticLabel: _tw('nodes.note.editor.showAuthor'),
                onCheckedChange: (v) {
                  setLocal(() => _showAuthor = v);
                  widget.onShowAuthorChange(v);
                },
              ),
            ],
          ),
        ),
      ),
      const DifyMenuSeparator(),
      _item(DifyI18n.tr('common', 'operation.delete'), 'workflow.delete', widget.onDelete, destructive: true),
    ],
  );
}
