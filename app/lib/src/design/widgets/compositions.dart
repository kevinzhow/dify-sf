/// Dify compositions used by the document launch and collaboration utilities.
library;

import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'widgets.dart';

class DifyContentDialog extends StatelessWidget {
  const DifyContentDialog({super.key, this.title, this.content, this.actions = const []});
  final Widget? title, content;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => DifyDialogSurface(
    width: 600,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: DefaultTextStyle(
              style: difyTextStyle(DifyType.titleLgBold, DifyColors.textPrimary),
              child: title!,
            ),
          ),
        if (content != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: content!),
        DifyAlertDialogActions(children: actions),
      ],
    ),
  );
}

class DifyLabeledSwitch extends StatelessWidget {
  const DifyLabeledSwitch({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                DefaultTextStyle(style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary), child: title),
                if (subtitle != null)
                  DefaultTextStyle(
                    style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                    child: subtitle!,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          DifySwitch(checked: value, onCheckedChange: onChanged),
        ],
      ),
    ),
  );
}

class DifyMenuOption<T> {
  const DifyMenuOption({required this.child, this.value, this.enabled = true, this.height, this.key});
  final Widget child;
  final T? value;
  final bool enabled;
  final double? height;
  final Key? key;
}

/// Uses the same Dify popup, item padding, keyboard navigation and focus ring as
/// the Studio menus; it does not instantiate a Material popup menu.
class DifyActionMenu<T> extends StatelessWidget {
  const DifyActionMenu({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.itemBuilder,
    this.onSelected,
    this.onOpened,
  });
  final Widget icon;
  final String tooltip;
  final List<DifyMenuOption<T>> Function(BuildContext) itemBuilder;
  final ValueChanged<T>? onSelected;
  final VoidCallback? onOpened;
  @override
  Widget build(BuildContext context) => DifyDropdownMenu(
    width: 280,
    onOpenChange: (open) {
      if (open) onOpened?.call();
    },
    builder: (context, controller) => DifyTooltip(
      content: DifyTextLine(tooltip),
      child: DifyIconButton(label: tooltip, icon: icon, onPressed: controller.toggle),
    ),
    children: [
      for (final item in itemBuilder(context))
        DifyMenuItem(
          key: item.key,
          disabled: !item.enabled,
          onSelect: item.value == null ? null : () => onSelected?.call(item.value as T),
          child: item.child,
        ),
    ],
  );
}

class DifyValueChip extends StatelessWidget {
  const DifyValueChip({super.key, required this.label, this.avatar});
  final Widget label;
  final Widget? avatar;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: DifyColors.componentsInputBgNormal,
      borderRadius: BorderRadius.circular(DifyRadius.md),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        ?avatar,
        DefaultTextStyle(style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary), child: label),
      ],
    ),
  );
}
