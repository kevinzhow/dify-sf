import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store.dart';
import '../store/workflow_store_scope.dart';
import 'header_data.dart';
import 'header_widgets.dart';
import 'hotkey.dart';

String _tr(String key) => DifyI18n.tr('workflow', key);

/// One of the variable panels' buttons (env-button.tsx, chat-variable-button.tsx, global-variable-button.tsx): an
/// `IconButton size=lg variant=ghost` with a 16 px icon; it opens its panel, closing the other variable panels and
/// the debug panel ([WorkflowStore.setShowEnvPanel] and its siblings do that).
class _VariablePanelButton extends StatelessWidget {
  const _VariablePanelButton({
    required this.disabled,
    required this.label,
    required this.icon,
    required this.shown,
    required this.open,
  });

  final bool disabled;
  final String label;
  final String icon;
  final ValueNotifier<bool> Function(WorkflowStore s) shown;
  final void Function(WorkflowStore s, WorkflowHeaderData data) open;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    final data = WorkflowHeaderScope.of(context);
    return ValueListenableBuilder(
      valueListenable: shown(store),
      builder: (context, expanded, _) => Semantics(
        expanded: expanded,
        child: DifyIconButton(
          label: label,
          variant: DifyButtonVariant.ghost,
          size: DifyIconButtonSize.lg,
          disabled: disabled,
          onPressed: () => open(store, data),
          icon: DifyIcon(icon, size: 16, color: DifyColors.componentsButtonSecondaryText),
        ),
      ),
    );
  }
}

/// header/env-button.tsx.
class EnvButton extends StatelessWidget {
  const EnvButton({super.key, required this.disabled});
  final bool disabled;

  @override
  Widget build(BuildContext context) => _VariablePanelButton(
    disabled: disabled,
    label: _tr('env.envPanelTitle'),
    icon: 'vender/line/others/env',
    shown: (s) => s.showEnvPanel,
    open: (s, data) {
      s.setShowEnvPanel(true);
      data.closeAllInputFieldPanels?.call();
    },
  );
}

/// header/chat-variable-button.tsx (chatflows only).
class ChatVariableButton extends StatelessWidget {
  const ChatVariableButton({super.key, required this.disabled});
  final bool disabled;

  @override
  Widget build(BuildContext context) => _VariablePanelButton(
    disabled: disabled,
    label: _tr('chatVariable.panelTitle'),
    icon: 'vender/line/others/bubble-x',
    shown: (s) => s.showChatVariablePanel,
    open: (s, data) => s.setShowChatVariablePanel(true),
  );
}

/// header/global-variable-button.tsx.
class GlobalVariableButton extends StatelessWidget {
  const GlobalVariableButton({super.key, required this.disabled});
  final bool disabled;

  @override
  Widget build(BuildContext context) => _VariablePanelButton(
    disabled: disabled,
    label: _tr('globalVar.title'),
    icon: 'vender/line/others/global-variable',
    shown: (s) => s.showGlobalVariablePanel,
    open: (s, data) {
      s.setShowGlobalVariablePanel(true);
      data.closeAllInputFieldPanels?.call();
    },
  );
}

/// header/version-history-button.tsx: `IconButton variant=secondary size=lg` with `i-ri-history-line`, a tooltip
/// "Version History ⌘ ⇧ H", and the Mod+Shift+H shortcut.
class VersionHistoryButton extends StatelessWidget {
  const VersionHistoryButton({super.key, required this.onClick});
  final VoidCallback onClick;

  @override
  Widget build(BuildContext context) {
    final label = _tr('common.versionHistory');
    final r = BorderRadius.circular(DifyRadius.lg);
    return PageHotkey(
      hotkey: versionHistoryHotkey,
      onPressed: onClick,
      child: DifyTooltip(
        surface: false,
        content: DifyBlurredBox(
          blur: 5,
          borderRadius: r,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: DifyColors.componentsTooltipBg,
            border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
            borderRadius: r,
            boxShadow: DifyShadows.lg,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Text(label, style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textSecondary)),
              ),
              const DifyShortcutKbd(hotkey: versionHistoryHotkey, secondaryText: true),
            ],
          ),
        ),
        child: DifyIconButton(
          label: label,
          variant: DifyButtonVariant.secondary,
          size: DifyIconButtonSize.lg,
          onPressed: onClick,
          icon: const RemixIcon('history-line', size: 16, color: DifyColors.componentsButtonSecondaryText),
        ),
      ),
    );
  }
}

/// The first selected node's id (Dify: `nodes.find((node) => node.data.selected)`).
String? selectedNodeIdOf(CanvasController canvas) {
  final g = canvas.graph;
  if (g == null) return null;
  final slots = [...canvas.selection.nodes]..sort();
  for (final s in slots) {
    if (s < g.slots.length && g.slots[s] != null) return g.slots[s]!.id;
  }
  return null;
}

/// header/scroll-to-selected-node-button.tsx: shown while a node is selected; centres the view on it like Dify's
/// `setupScrollToNodeListener` (zoom 1, the node's top-left a quarter of the window from the middle, 800 ms).
class ScrollToSelectedNodeButton extends StatefulWidget {
  const ScrollToSelectedNodeButton({super.key});

  @override
  State<ScrollToSelectedNodeButton> createState() => _ScrollToSelectedNodeButtonState();
}

class _ScrollToSelectedNodeButtonState extends State<ScrollToSelectedNodeButton> with SingleTickerProviderStateMixin {
  Ticker? _ticker;

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  void _scrollTo(CanvasController canvas, String id) {
    final n = canvas.graph?[id];
    if (n == null) return;
    final window = MediaQuery.sizeOf(context);
    final view = canvas.view;
    final fromCenter = view.center, fromScale = view.scale;
    final toCenter = Offset(n.x + window.width * 0.25, n.y + window.height * 0.25);
    _ticker?.dispose();
    const duration = Duration(milliseconds: 800);
    _ticker = createTicker((elapsed) {
      // d3-zoom's default ease (cubic in-out); the zoom and the centre move together.
      final t = Curves.easeInOutCubic.transform((elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0));
      view
        ..scale = fromScale + (1 - fromScale) * t
        ..center = Offset.lerp(fromCenter, toCenter, t)!;
      if (elapsed >= duration) _ticker?.stop();
    })..start();
  }

  @override
  Widget build(BuildContext context) {
    final canvas = WorkflowHeaderScope.canvasOf(context);
    if (canvas == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: canvas.selection,
      builder: (context, _) {
        final id = selectedNodeIdOf(canvas);
        if (id == null) return const SizedBox.shrink();
        final scroll = WorkflowHeaderScope.of(context).scrollToNode;
        return ScrollToSelectedNodeFace(onPressed: () => scroll != null ? scroll(id) : _scrollTo(canvas, id));
      },
    );
  }
}

/// The button itself: `flex h-6 items-center rounded-md border-[0.5px] border-effects-highlight
/// bg-components-actionbar-bg px-3 system-xs-medium text-text-tertiary shadow-lg backdrop-blur-xs
/// hover:text-text-accent`.
class ScrollToSelectedNodeFace extends StatelessWidget {
  const ScrollToSelectedNodeFace({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(DifyRadius.md);
    return HeaderPressable(
      onPressed: onPressed,
      builder: (context, hovered) => DifyBlurredBox(
        blur: 4,
        borderRadius: r,
        decoration: BoxDecoration(
          color: DifyColors.componentsActionbarBg,
          border: Border.all(color: DifyColors.effectsHighlight, width: Css.hairline),
          borderRadius: r,
          boxShadow: DifyShadows.lg,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          height: 24,
          child: Center(
            widthFactor: 1,
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: difyTextStyle(
                DifyType.systemXsMedium,
                hovered ? DifyColors.textAccent : DifyColors.textTertiary,
              ),
              child: Text(_tr('panel.scrollToSelectedNode'), maxLines: 1, softWrap: false),
            ),
          ),
        ),
      ),
    );
  }
}
