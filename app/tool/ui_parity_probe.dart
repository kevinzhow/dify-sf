/// Actual design-system widgets in a deterministic fixture stage. Not a production renderer.
library;

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;
import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/css_metrics.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final q = Uri.base.queryParameters;
  final locale = q['lang'] ?? 'zh-Hans';
  final dark = q['theme'] == 'dark';
  await DifyFonts.loadFor(locale);
  await DifyI18n.load(locale);
  cardFontFamily = 'Noto Sans';
  DifyColors.useDark(dark);
  await IconCache.preload([('assets/remix_icons/add-line.svg', DifyColors.componentsButtonSecondaryText)]);
  runApp(
    DifyApplication(
      theme: difyTheme(
        fontFamily: cardFontFamily,
        fontFamilyFallback: DifyFonts.fallbackFamilies,
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      home: DifyPage(
        body: Listener(
          onPointerDown: (event) {
            if (event.localPosition.dx > 500) FocusManager.instance.primaryFocus?.unfocus();
          },
          child: _Fixture(kind: q['case'] ?? 'button-primary', locale: locale),
        ),
      ),
    ),
  );
}

class _Fixture extends StatefulWidget {
  const _Fixture({required this.kind, required this.locale});
  final String kind, locale;
  @override
  State<_Fixture> createState() => _FixtureState();
}

class _FixtureState extends State<_Fixture> {
  final component = GlobalKey();
  String input = '', value = 'a';
  final toastManager = DifyToastManager();
  @override
  void initState() {
    super.initState();
    if (widget.kind == 'toast') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        toastManager.add(
          DifyToastData(
            id: 'fixture',
            title: label,
            description: 'Example content',
            type: DifyToastType.success,
            timeout: Duration.zero,
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  String get label => widget.locale == 'en-US' ? 'Create' : '创建 Create';
  Widget sample() {
    final k = widget.kind, disabled = k.endsWith('-disabled');
    if (k.startsWith('button-')) {
      final variant = switch (k.split('-')[1]) {
        'primary' || 'disabled' => DifyButtonVariant.primary,
        'secondary' => DifyButtonVariant.secondary,
        'ghost' => DifyButtonVariant.ghost,
        _ => DifyButtonVariant.primary,
      };
      return DifyButton(variant: variant, disabled: disabled, onPressed: () {}, child: DifyTextLine(label));
    }
    if (k == 'icon-button') {
      return DifyIconButton(label: 'Add', onPressed: () {}, icon: const RemixIcon('add-line', size: 16));
    }
    if (k.startsWith('input')) {
      return SizedBox(
        width: 300,
        child: DifyInput(
          value: input,
          placeholder: label,
          semanticLabel: 'Input',
          disabled: disabled,
          onChanged: (x) => setState(() => input = x),
        ),
      );
    }
    if (k == 'textarea') {
      return SizedBox(
        width: 300,
        child: DifyInlineReplacedBox(
          child: DifyTextarea(
            value: input,
            placeholder: label,
            semanticLabel: 'Textarea',
            onChanged: (x) => setState(() => input = x),
          ),
        ),
      );
    }
    if (k.startsWith('checkbox') && k != 'checkbox-list') {
      return DifyCheckbox(
        checked: k == 'checkbox-checked',
        indeterminate: k == 'checkbox-indeterminate',
        disabled: disabled,
        onChanged: (_) {},
      );
    }
    if (k.startsWith('switch')) {
      return DifySwitch(checked: k == 'switch-checked', disabled: disabled, onCheckedChange: (_) {});
    }
    if (k == 'slider') return SizedBox(width: 300, child: DifySlider(value: 30, onChanged: (_) {}));
    if (k == 'number-field') {
      return SizedBox(width: 300, child: DifyNumberField(value: 13, showControls: true, onChanged: (_) {}));
    }
    if (k == 'badge') return DifyBadge(label);
    if (k == 'tabs') {
      return DifyTabsList(
        children: [
          DifyTab(label: label, active: true, onPressed: () {}),
          DifyTab(label: 'Other', active: false, onPressed: () {}),
        ],
      );
    }
    if (k == 'radio') {
      return DifyRadioGroup<String>(
        value: 'a',
        onValueChange: (_) {},
        children: [
          DifyRadio<String>(value: 'a'),
          DifyRadio<String>(value: 'b'),
        ],
      );
    }
    if (k == 'select') {
      return SizedBox(
        width: 300,
        child: DifySelect<String>(
          value: value,
          options: const [(value: 'a', label: 'Option A'), (value: 'b', label: 'Option B')],
          onChanged: (x) => setState(() => value = x),
        ),
      );
    }

    if (k == 'avatar') return const DifyAvatar(name: 'Alice');
    if (k == 'workspace-avatar') return const DifyWorkspaceAvatar(name: 'Alice');
    if (k == 'kbd') return const DifyKbdGroup(children: [DifyKbd('Ctrl'), DifyKbd('K')]);
    if (k == 'shortcut-kbd') return const DifyShortcutKbd(hotkey: 'Ctrl+K', platform: DifyPlatform.linux);
    if (k == 'status-dot') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          for (final s in DifyStatusDotStatus.values) DifyStatusDot(status: s),
          const DifyStatusDotSkeleton(),
        ],
      );
    }
    if (k == 'skeleton') return const DifySkeletonRectangle(width: 300);
    if (k == 'divider') return const SizedBox(width: 300, child: DifyDivider());
    if (k == 'segmented-control') {
      return DifySegmentedControl<String>(
        value: 'a',
        segments: [
          (value: 'a', child: DifyTextLine(label), label: label),
          (value: 'b', child: const DifyTextLine('Other'), label: 'Other'),
        ],
        onChanged: (_) {},
      );
    }
    if (k == 'tab-slider-plain') {
      return DifyTabSliderPlain(
        value: 'a',
        onChange: (_) {},
        options: [(value: 'a', text: DifyTextLine(label)), (value: 'b', text: const DifyTextLine('Other'))],
      );
    }
    if (k == 'pagination') return DifyPagination(page: 2, totalPages: 10, onPageChange: (_) {});
    if (k == 'text' || k == 'selection') {
      return DifySelectionRegion(child: DifyText('$label ABC 0123', DifyType.systemSmRegular));
    }
    if (k == 'alpha-composite') {
      return SizedBox(
        width: 320,
        child: Wrap(
          children: [
            for (final alpha in <double>[1, .8, .6, .4, .95, .05, .1, .5])
              SizedBox(
                width: 80,
                height: 80,
                child: ColoredBox(
                  color: const Color(0xFF1D1D20),
                  child: ColoredBox(
                    color: Color.from(alpha: alpha, red: 24 / 255, green: 24 / 255, blue: 27 / 255),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    if (k == 'surface') {
      return DifyBlurredBox(
        blur: 5,
        borderRadius: BorderRadius.circular(12),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          border: Border.all(color: DifyColors.dividerRegular),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(16),
        child: DifyTextLine(label, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textPrimary)),
      );
    }
    if (k == 'dashed-border') {
      return DashedBorderBox(
        color: DifyColors.componentsDropzoneBorder,
        fill: DifyColors.componentsDropzoneBg,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: DifyTextLine(label, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textPrimary)),
        ),
      );
    }
    if (k == 'popover') {
      return DifyPopover(
        open: true,
        builder: (_, _) => DifyButton(onPressed: () {}, child: DifyTextLine(label)),
        content: Padding(padding: const EdgeInsets.all(16), child: DifyTextLine(label)),
      );
    }
    if (k == 'tooltip') {
      return DifyTooltip(
        open: true,
        placement: DifyPlacement.bottom,
        content: DifyTextLine(label),
        child: DifyButton(onPressed: () {}, child: DifyTextLine(label)),
      );
    }
    if (k == 'menu') {
      return DifyDropdownMenu(
        open: true,
        placement: DifyPlacement.bottomStart,
        width: 240,
        builder: (_, _) => DifyButton(onPressed: () {}, child: DifyTextLine(label)),
        children: [
          DifyMenuGroupLabel(label),
          DifyMenuItem(onSelect: () {}, child: DifyTextLine(label)),
          DifyMenuCheckboxItem(checked: true, onCheckedChange: (_) {}, child: DifyTextLine(label)),
          const DifyMenuSeparator(),
          DifyMenuRadioGroup<String>(
            value: 'a',
            children: const [
              DifyMenuRadioItem<String>(value: 'a', child: DifyTextLine('Option A')),
              DifyMenuRadioItem<String>(value: 'b', child: DifyTextLine('Option B')),
            ],
          ),
        ],
      );
    }
    if (k == 'dialog') {
      return DifyDialogSurface(
        bordered: true,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DifyTextLine(label, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textPrimary)),
            DifyTextLine('Example content', style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textPrimary)),
          ],
        ),
      );
    }
    if (k == 'alert-dialog') {
      return DifyAlertDialog(
        title: label,
        description: 'Example content',
        onCancel: () {},
        onConfirm: () {},
        cancelLabel: 'Cancel',
        confirmLabel: 'Delete',
      );
    }

    if (k == 'search-input') return DifySearchInput(value: '', onValueChange: (_) {}, placeholder: label, width: 300);
    if (k == 'checkbox-list') {
      return SizedBox(
        width: 300,
        child: DifyCheckboxList(
          title: label,
          options: const [(value: 'a', label: 'Option A'), (value: 'b', label: 'Option B')],
          value: const ['a'],
          onChange: (_) {},
          showSearch: false,
        ),
      );
    }
    if (k == 'chip') return DifyChip(value: 'a', items: [(value: 'a', name: label)], onSelect: (_) {}, onClear: () {});
    if (k == 'app-icon') return const DifyAppIcon(iconType: 'emoji', icon: '🤖', background: '#FFEAD5');
    if (k == 'copy-feedback') return const DifyCopyFeedback(content: 'Example content');
    if (k == 'infotip') return DifyInfotip(label: 'Help', content: DifyTextLine(label));
    if (k == 'inline-delete-confirm') {
      return SizedBox(
        width: 300,
        child: DifyInlineDeleteConfirm(title: label, onConfirm: () {}, onCancel: () {}),
      );
    }
    if (k == 'tag-input') {
      return SizedBox(
        width: 300,
        child: DifyTagInput(items: const ['Alpha', 'Beta'], onChange: (_) {}, placeholder: label),
      );
    }
    if (k == 'loading') return const SizedBox(width: 300, height: 16, child: DifyLoading());
    if (k == 'loading-anim') return const DifyLoadingAnim();
    if (k == 'spinner') return const DifySpinnerIcon(child: RemixIcon('loader-2-line', size: 16));
    if (k == 'qrcode') return const DifyQrCode(data: 'https://example.test/ui-parity', size: 160);
    if (k == 'collapse') {
      return SizedBox(
        width: 300,
        child: DifyCollapse<String>(title: label, items: const ['Alpha'], itemBuilder: (_, x) => DifyTextLine(x)),
      );
    }
    if (k == 'calendar') return DifyCalendar(selected: DateTime(2026, 10, 15), onSelect: (_) {});
    if (k == 'toast') return DifyToastHost(manager: toastManager, timeout: Duration.zero);
    if (k == 'drawer') {
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: 480,
          height: 480,
          child: DifyDrawerPopup(
            width: 480,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DifyTextLine(label, style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textPrimary)),
                  DifyTextLine(
                    'Example content',
                    style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textPrimary),
                  ),
                  DifyDrawerCloseButton(onPressed: () {}),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (k == 'table') {
      return DifyTable(
        columns: const [
          DifyTableColumn(header: DifyTextLine('Name')),
          DifyTableColumn(header: DifyTextLine('Status')),
        ],
        rows: const [
          DifyTableRow(cells: [DifyTextLine('Alpha'), DifyTextLine('Ready')]),
        ],
      );
    }
    if (k == 'reorderable-list') {
      return SizedBox(
        width: 300,
        child: DifyReorderableList(
          onReorderItem: (_, _) {},
          children: const [
            DifyText('Alpha', DifyType.systemSmRegular, key: ValueKey('a')),
            DifyText('Beta', DifyType.systemSmRegular, key: ValueKey('b')),
          ],
        ),
      );
    }
    if (k == 'labeled-switch') {
      return DifyLabeledSwitch(
        title: DifyTextLine(label),
        subtitle: const DifyTextLine('Example content'),
        value: true,
        onChanged: (_) {},
      );
    }
    if (k == 'toolbar') {
      return DifyToolbarStrip(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            DifyButton(onPressed: () {}, child: DifyTextLine(label)),
            DifyButton(onPressed: () {}, child: const DifyTextLine('Other')),
          ],
        ),
      );
    }

    if (k == 'menu-submenu') {
      return DifyDropdownMenu(
        open: true,
        placement: DifyPlacement.bottomStart,
        width: 240,
        builder: (_, _) => DifyButton(onPressed: () {}, child: DifyTextLine(label)),
        children: [
          DifyMenuSubmenu(
            open: true,
            label: DifyTextLine(label),
            children: [DifyMenuItem(child: const DifyTextLine('Option A'), onSelect: () {})],
          ),
        ],
      );
    }
    if (k == 'context-menu') {
      return DifyContextMenu(
        width: 240,
        child: DifyButton(onPressed: () {}, child: DifyTextLine(label)),
        children: [DifyMenuItem(child: const DifyTextLine('Option A'), onSelect: () {})],
      );
    }
    throw StateError('No actual Flutter component registered: $k');
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final r = component.currentContext?.findRenderObject();
      if (r is! RenderBox) return;
      final p = r.localToGlobal(Offset.zero);
      final widgetTypes = <String>{};
      void inspectElement(Element e) {
        final name = e.widget.runtimeType.toString();
        if (name.startsWith('Dify')) widgetTypes.add(name);
        e.visitChildElements(inspectElement);
      }

      final element = component.currentContext;
      if (element is Element) inspectElement(element);
      web.document.documentElement!.setAttribute(
        'data-ui-parity',
        jsonEncode({
          'case': widget.kind,
          'cssHairline': Css.hairline,
          'bounds': {'x': p.dx, 'y': p.dy, 'width': r.size.width, 'height': r.size.height},
          'source': 'actual-design-widgets',
          'widgetTypes': widgetTypes.toList()..sort(),
          'locale': widget.locale,
        }),
      );
    });
    if (const {'dialog', 'alert-dialog', 'drawer', 'toast'}.contains(widget.kind)) {
      return Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: DifyColors.backgroundBody),
          if (widget.kind != 'toast') ColoredBox(color: DifyColors.backgroundOverlay),
          KeyedSubtree(key: component, child: sample()),
        ],
      );
    }
    return Align(
      alignment: Alignment.topLeft,
      child: Container(
        width: 640,
        height: 480,
        color: DifyColors.backgroundBody,
        padding: const EdgeInsets.all(16),
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          // CSS's inline fixture has height:auto. Keep the same natural height
          // instead of giving Column/scroll wrappers the stage's finite max height.
          child: Align(
            alignment: Alignment.topLeft,
            heightFactor: 1,
            child: UnconstrainedBox(
              constrainedAxis: Axis.horizontal,
              alignment: Alignment.topLeft,
              child: KeyedSubtree(key: component, child: sample()),
            ),
          ),
        ),
      ),
    );
  }
}
