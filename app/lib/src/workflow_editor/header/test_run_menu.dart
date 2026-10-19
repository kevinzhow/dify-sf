import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../cards/card_chrome.dart';
import '../../cards/node_helpers.dart' show getWorkflowEntryNode;
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import 'header_data.dart';

/// header/test-run-menu.tsx `TriggerType`.
enum TriggerType { userInput, schedule, webhook, plugin, all }

/// A way to start a test run: the Start node (user input), one trigger node, or all triggers.
@immutable
class TriggerOption {
  const TriggerOption({
    required this.id,
    required this.type,
    required this.name,
    this.nodeType,
    this.nodeId,
    this.relatedNodeIds = const [],
    this.enabled = true,
  });

  final String id;
  final TriggerType type;
  final String name;

  /// The node type whose block icon the row shows (null: the "run all triggers" icon).
  final String? nodeType;
  final String? nodeId;
  final List<String> relatedNodeIds;
  final bool enabled;

  @override
  String toString() => 'TriggerOption($id, $type)';
}

/// `TestRunOptions`.
@immutable
class TestRunOptions {
  const TestRunOptions({this.userInput, this.triggers = const [], this.runAll});
  final TriggerOption? userInput;
  final List<TriggerOption> triggers;
  final TriggerOption? runAll;
}

/// hooks/use-dynamic-test-run-options.tsx: the Start node, each trigger node, and "run all triggers" when there
/// are several.
TestRunOptions testRunOptionsOf(List<HeaderNode> nodes) {
  String tr(String key) => DifyI18n.tr('workflow', key);
  String name(HeaderNode n, String fallback) => n.title.isNotEmpty ? n.title : tr(fallback);
  TriggerOption? userInput;
  final triggers = <TriggerOption>[];
  for (final n in nodes) {
    final type = switch (n.type) {
      'trigger-schedule' => TriggerType.schedule,
      'trigger-webhook' => TriggerType.webhook,
      'trigger-plugin' => TriggerType.plugin,
      _ => null,
    };
    if (n.type == 'start') {
      userInput = TriggerOption(
        id: n.id,
        type: TriggerType.userInput,
        name: name(n, 'blocks.start'),
        nodeType: n.type,
        nodeId: n.id,
      );
    } else if (type != null) {
      final plugin = n.data['plugin_name'];
      triggers.add(
        TriggerOption(
          id: n.id,
          type: type,
          name: n.title.isEmpty && plugin is String && plugin.isNotEmpty ? plugin : name(n, 'blocks.${n.type}'),
          nodeType: n.type,
          nodeId: n.id,
        ),
      );
    }
  }
  if (userInput == null) {
    final entry = getWorkflowEntryNode(nodes, (n) => n.type);
    if (entry != null && entry.type == 'start') {
      userInput = TriggerOption(
        id: entry.id,
        type: TriggerType.userInput,
        name: name(entry, 'blocks.start'),
        nodeType: entry.type,
        nodeId: entry.id,
      );
    }
  }
  final ids = [for (final t in triggers) ?t.nodeId];
  return TestRunOptions(
    userInput: userInput,
    triggers: triggers,
    runAll: ids.length > 1
        ? TriggerOption(id: 'run-all', type: TriggerType.all, name: tr('common.runAllTriggers'), relatedNodeIds: ids)
        : null,
  );
}

/// `ShortcutMapping`.
typedef ShortcutMapping = ({TriggerOption option, String shortcutKey});

/// `buildShortcutMappings`: `~` for user input, then `0`, `1`, ... for run-all and each trigger.
List<ShortcutMapping> buildShortcutMappings(TestRunOptions options) {
  final out = <ShortcutMapping>[];
  if (options.userInput case final u? when u.enabled) out.add((option: u, shortcutKey: '~'));
  var n = 0;
  if (options.runAll case final a? when a.enabled) out.add((option: a, shortcutKey: '${n++}'));
  for (final t in options.triggers) {
    if (t.enabled) out.add((option: t, shortcutKey: '${n++}'));
  }
  return out;
}

/// `getNormalizedShortcutKey`: the key a press typed, with the backtick read as `~`.
String getNormalizedShortcutKey(String key) => key == '`' ? '~' : key;

List<TriggerOption> _enabledOptions(TestRunOptions o) => [
  ?o.userInput,
  ?o.runAll,
  ...o.triggers,
].where((x) => x.enabled).toList();

/// Lets the owner open or close the menu (Dify's `TestRunMenuRef.toggle`).
class TestRunMenuController {
  VoidCallback? _toggle;

  /// Runs the only option directly, or opens/closes the menu.
  void toggle() => _toggle?.call();
}

/// header/test-run-menu.tsx: [builder] builds the run button and gets the action for it: with one enabled option it
/// runs that option (Dify's SingleOptionTrigger), else it opens the "Choose the start node to run" menu, whose rows
/// can also be picked by their keys (`~`, `0`, `1`, ...) while it is open.
class TestRunMenu extends StatefulWidget {
  const TestRunMenu({super.key, required this.options, required this.onSelect, required this.builder, this.controller});

  final TestRunOptions options;
  final ValueChanged<TriggerOption> onSelect;
  final Widget Function(BuildContext context, VoidCallback activate) builder;
  final TestRunMenuController? controller;

  @override
  State<TestRunMenu> createState() => _TestRunMenuState();
}

class _TestRunMenuState extends State<TestRunMenu> {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    widget.controller?._toggle = _toggle;
  }

  @override
  void didUpdateWidget(TestRunMenu old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller?._toggle == _toggle) old.controller?._toggle = null;
      widget.controller?._toggle = _toggle;
    }
  }

  @override
  void dispose() {
    if (widget.controller?._toggle == _toggle) widget.controller?._toggle = null;
    super.dispose();
  }

  List<TriggerOption> get _enabled => _enabledOptions(widget.options);

  void _select(TriggerOption option) {
    widget.onSelect(option);
    if (mounted) setState(() => _open = false);
  }

  void _toggle() {
    final enabled = _enabled;
    if (enabled.length == 1) return _select(enabled.single);
    setState(() => _open = !_open);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _enabled;
    if (enabled.length == 1) return widget.builder(context, () => _select(enabled.single));
    final o = widget.options;
    final mappings = buildShortcutMappings(o);
    final keyOf = {for (final m in mappings) m.option.id: m.shortcutKey};
    final hasUserInput = o.userInput?.enabled ?? false;
    final hasTriggers = o.triggers.any((t) => t.enabled);
    final hasRunAll = o.runAll?.enabled ?? false;
    Widget row(TriggerOption x) => TestRunOptionRow(option: x, shortcutKey: keyOf[x.id], onSelect: _select);
    return TestRunShortcuts(
      open: _open,
      shortcutMappings: mappings,
      onSelect: _select,
      child: DifyDropdownMenu(
        open: _open,
        onOpenChange: (v) => setState(() => _open = v),
        placement: DifyPlacement.bottomStart,
        sideOffset: 8,
        alignOffset: -4,
        width: 284,
        builder: (context, c) => widget.builder(context, c.toggle),
        children: [
          // `mb-1 px-3 pt-2 text-sm font-medium text-text-primary`
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              DifyI18n.tr('workflow', 'common.chooseStartNodeToRun'),
              style: difyTextStyle(DifyType.systemMdMedium, DifyColors.textPrimary),
            ),
          ),
          if (hasUserInput) row(o.userInput!),
          if ((hasTriggers || hasRunAll) && hasUserInput)
            const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: DifyMenuSeparator()),
          if (hasRunAll) row(o.runAll!),
          for (final t in o.triggers)
            if (t.enabled) row(t),
        ],
      ),
    );
  }
}

/// test-run-menu-helpers.tsx `OptionRow`: the option's 24 px icon, its name and its key.
class TestRunOptionRow extends StatelessWidget {
  const TestRunOptionRow({super.key, required this.option, this.shortcutKey, required this.onSelect});

  final TriggerOption option;
  final String? shortcutKey;
  final ValueChanged<TriggerOption> onSelect;

  @override
  Widget build(BuildContext context) => DifyMenuItem(
    onSelect: () => onSelect(option),
    leading: SizedBox.square(
      dimension: 24,
      child: option.nodeType == null ? const _RunAllIcon() : BlockIcon(type: option.nodeType!),
    ),
    trailing: shortcutKey == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(left: 4),
            child: DifyShortcutKbd(displayKey: shortcutKey, secondaryText: true),
          ),
    child: Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        option.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary),
      ),
    ),
  );
}

/// `rounded-lg border-[0.5px] border-white/2 bg-util-colors-purple-purple-500 text-white shadow-md`, TriggerAll 18 px.
class _RunAllIcon extends StatelessWidget {
  const _RunAllIcon();

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: DifyColors.utilColorsPurplePurple500,
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      border: Border.all(color: DifyTailwind.white.withValues(alpha: 0.02), width: 0.5), // border-white/2
      boxShadow: DifyShadows.md,
    ),
    alignment: Alignment.center,
    child: DifyIcon('vender/workflow/trigger-all', size: 18, color: DifyTailwind.white),
  );
}

/// test-run-menu-helpers.tsx `useShortcutMenu`: while [open], a key press without Alt, Ctrl or Meta that is one of
/// the mappings' keys picks its option.
class TestRunShortcuts extends StatefulWidget {
  const TestRunShortcuts({
    super.key,
    required this.open,
    required this.shortcutMappings,
    required this.onSelect,
    required this.child,
  });

  final bool open;
  final List<ShortcutMapping> shortcutMappings;
  final ValueChanged<TriggerOption> onSelect;
  final Widget child;

  @override
  State<TestRunShortcuts> createState() => _TestRunShortcutsState();
}

class _TestRunShortcutsState extends State<TestRunShortcuts> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handle);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handle);
    super.dispose();
  }

  bool _handle(KeyEvent e) {
    final k = HardwareKeyboard.instance;
    if (!widget.open || e is! KeyDownEvent || k.isAltPressed || k.isControlPressed || k.isMetaPressed) return false;
    final key = getNormalizedShortcutKey(e.character ?? e.logicalKey.keyLabel);
    for (final m in widget.shortcutMappings) {
      if (m.shortcutKey == key) {
        widget.onSelect(m.option);
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
