/// The Nodes tab (block-selector/blocks.tsx) and Agent v2's roster picker (agent-selector.tsx).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store.dart' show DifyJson;
import 'block_defaults.dart';
import 'block_selector.dart' show OnSelectBlock;
import 'block_selector_data.dart';
import 'selector_widgets.dart';

String _agent(String key) => DifyI18n.tr('agent-v-2', key);

/// Blocks: the [blocks] among [availableBlocksTypes] whose title contains [searchText] (case-insensitive), grouped
/// by classification (the default group without a header; `tabs.<classification>` headers `h-5.5 px-3 text-xs
/// font-medium text-text-tertiary`), Agent v2 first, then by sort; never triggers, and no second Knowledge Base.
/// Rows are `h-8 rounded-lg px-3` with BlockIcon sm and the title in `text-sm text-text-secondary`; hovering one
/// previews its icon, title and `blocksAbout`. "No match found" when nothing is left.
class BlocksPanel extends StatelessWidget {
  const BlocksPanel({
    super.key,
    required this.searchText,
    required this.onSelect,
    this.availableBlocksTypes = const [],
    this.blocks,
  });

  final String searchText;
  final OnSelectBlock onSelect;
  final List<String> availableBlocksTypes;
  final List<BlockMeta>? blocks;

  /// hooks.ts useBlocks (constants.tsx BLOCKS, titled `blocks.<type>`): the list without `blocks`.
  static List<BlockMeta> get constantBlocks => [
    for (final (c, t) in const [
      ('-', 'agent'), ('-', 'agent-v2'), ('-', 'llm'), ('-', 'knowledge-retrieval'), ('-', 'end'), ('-', 'answer'), //
      ('question-understand', 'question-classifier'),
      ('logic', 'if-else'),
      ('logic', 'loop-end'),
      ('logic', 'iteration'),
      ('logic', 'loop'),
      ('transform', 'code'),
      ('transform', 'template-transform'),
      ('transform', 'variable-aggregator'),
      ('transform', 'document-extractor'), ('transform', 'assigner'), ('transform', 'parameter-extractor'),
      ('utilities', 'http-request'), ('utilities', 'list-operator'),
    ])
      BlockMeta(type: t, classification: c, title: DifyI18n.tr('workflow', 'blocks.$t')),
  ];

  @override
  Widget build(BuildContext context) {
    final all = blocks ?? constantBlocks;
    final needle = searchText.toLowerCase();
    final hasKnowledgeBase = BlockSelectorScope.of(context).nodes.any((n) => n.type == 'knowledge-index');
    final groups = {
      for (final c in BlockClassification.all)
        c:
            [
              for (final b in all)
                if (b.classification == c &&
                    !b.type.startsWith('trigger-') &&
                    b.title.toLowerCase().contains(needle) &&
                    availableBlocksTypes.contains(b.type) &&
                    !(hasKnowledgeBase && b.type == 'knowledge-index'))
                  b,
            ]..sort((a, b) {
              if (a.type == 'agent-v2') return -1;
              if (b.type == 'agent-v2') return 1;
              return a.sort.compareTo(b.sort);
            }),
    };
    final empty = groups.values.every((g) => g.isEmpty);
    return PreviewCardScope(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480, maxWidth: 500),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (empty)
                Container(
                  height: 22,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.centerLeft,
                  child: DifyText(wf('tabs.noResult'), DifyType.systemXsMedium, color: DifyColors.textTertiary),
                ),
              if (!empty)
                for (final (i, c) in BlockClassification.all.indexed)
                  if (groups[c]!.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(bottom: i == BlockClassification.all.length - 1 ? 0 : 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (c != BlockClassification.defaultGroup)
                            Container(
                              height: 22,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              alignment: Alignment.topLeft,
                              child: DifyText(wf('tabs.$c'), DifyType.systemXsMedium, color: DifyColors.textTertiary),
                            ),
                          for (final b in groups[c]!)
                            b.type == 'agent-v2' ? AgentBlockItem(block: b, onSelect: onSelect) : _row(b),
                        ],
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BlockMeta b) => PreviewCardTrigger(
    preview: (_) => BlockPreviewContent(type: b.type, title: b.title, description: b.description),
    child: SelectorRow(
      label: b.title,
      description: b.description.isEmpty ? null : b.description,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      onPressed: () => onSelect(b.type),
      child: Row(
        children: [
          SelectorBlockIcon(type: b.type),
          const SizedBox(width: 8),
          Expanded(child: DifyText(b.title, _textSm, color: DifyColors.textSecondary)),
          if (b.type == 'loop-end') ...[
            const SizedBox(width: 8),
            DifyBadge(wf('nodes.loop.loopNode')),
          ],
        ],
      ),
    ),
  );
}

/// `text-sm` (14 / 20, regular).
const _textSm = DifyType.systemSmRegular;

/// The Agent v2 block: a row with a "status" badge and a chevron that opens the roster picker to its right
/// (hover or click); choosing an agent binds the node to it, "Start from scratch" makes an inline agent.
class AgentBlockItem extends StatefulWidget {
  const AgentBlockItem({super.key, required this.block, required this.onSelect});
  final BlockMeta block;
  final OnSelectBlock onSelect;

  @override
  State<AgentBlockItem> createState() => _AgentBlockItemState();
}

DifyJson _agentDefaults(DifyJson binding) => {
  'agent_binding': binding,
  'agent_node_kind': 'dify_agent',
  'version': '2',
};

class _AgentBlockItemState extends State<AgentBlockItem> {
  bool _open = false;
  Timer? _hover;

  @override
  void dispose() {
    _hover?.cancel();
    super.dispose();
  }

  void _set(bool open) {
    _hover?.cancel();
    if (open != _open) setState(() => _open = open);
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    return DifyPopover(
      open: _open,
      onOpenChange: _set,
      placement: DifyPlacement.rightStart,
      sideOffset: 4,
      surface: false,
      semanticLabel: _agent('roster.nodeSelector.dialogLabel'),
      builder: (context, c) => MouseRegion(
        // openOnHover (Base UI's 300 ms rest).
        onEnter: (_) => _hover = Timer(const Duration(milliseconds: 300), () => mounted ? _set(true) : null),
        onExit: (_) => _hover?.cancel(),
        child: SelectorRow(
          label: '${b.title} ${DifyI18n.tr('common', 'menus.status')}',
          highlighted: _open,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          onPressed: () => _set(!_open),
          child: Row(
            children: [
              SelectorBlockIcon(type: b.type),
              const SizedBox(width: 8),
              Expanded(child: DifyText(b.title, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
              const SizedBox(width: 8),
              _DimmBadge(DifyI18n.tr('common', 'menus.status')),
              RotatedBox(
                quarterTurns: 3,
                child: DifyIcon('vender/solid/general/arrow-down-round-fill', size: 16, color: DifyColors.textTertiary),
              ),
            ],
          ),
        ),
      ),
      content: AgentSelectorContent(
        onClose: () => _set(false),
        onSelect: (agent) {
          _set(false);
          widget.onSelect('agent-v2', _agentDefaults({'binding_type': 'roster_agent', 'agent_id': agent.id}));
        },
        onStartFromScratch: () {
          _set(false);
          widget.onSelect('agent-v2', _agentDefaults({'binding_type': 'inline_agent'}));
        },
      ),
    );
  }
}

/// Badge `size="xs" variant="dimm"`: `min-w-4 px-1 py-0.5 bg-components-badge-bg-dimm system-2xs-medium-uppercase`.
class _DimmBadge extends StatelessWidget {
  const _DimmBadge(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 16),
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(
      color: DifyColors.componentsBadgeBgDimm,
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: DifyColors.dividerDeep),
    ),
    child: DifyText(text, DifyType.system2xsMediumUppercase, color: DifyColors.textTertiary),
  );
}

/// AgentSelectorContent: `w-60 rounded-xl bg-components-panel-bg-blur shadow-lg`, a search field (the roster is
/// asked again 300 ms after typing stops and on every open), the status line (loading, error, empty), the agents
/// (avatar, name, role or description; `max-h-54`), and the footer: "Start from scratch" and "Manage in Agent
/// Console". An agent without an active configuration can't be chosen.
class AgentSelectorContent extends StatefulWidget {
  const AgentSelectorContent({super.key, required this.onSelect, this.onStartFromScratch, this.onClose});
  final ValueChanged<AgentOption> onSelect;
  final VoidCallback? onStartFromScratch;
  final VoidCallback? onClose;

  @override
  State<AgentSelectorContent> createState() => _AgentSelectorContentState();
}

class _AgentSelectorContentState extends State<AgentSelectorContent> {
  String _search = '';
  Timer? _debounce;
  List<AgentOption>? _agents;
  bool _error = false;
  int _request = 0;
  final _focus = FocusNode(debugLabel: 'agent search');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _load('');
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load(String keyword) async {
    final search = BlockSelectorScope.of(context).searchAgents;
    final id = ++_request;
    if (search == null) return setState(() => _agents = const []);
    setState(() => _agents = null);
    try {
      final agents = await search(keyword);
      if (mounted && id == _request) {
        setState(() {
          _agents = agents;
          _error = false;
        });
      }
    } catch (_) {
      if (mounted && id == _request) {
        setState(() {
          _agents = const [];
          _error = true;
        });
      }
    }
  }

  void _choose(AgentOption a) {
    if (a.activeConfigSnapshotId == null) {
      BlockSelectorScope.of(context).onError?.call(wf('nodes.agent.modelNotSelected'));
      return;
    }
    widget.onSelect(a);
  }

  @override
  Widget build(BuildContext context) {
    final agents = _agents;
    final status = agents == null
        ? DifyI18n.tr('common', 'loading')
        : _error
        ? _agent('roster.loadingError')
        : agents.isEmpty
        ? (_search.trim().isNotEmpty ? _agent('roster.emptySearch') : _agent('roster.empty'))
        : null;
    Widget footerButton(String label, String icon, VoidCallback onPressed, {bool link = false}) {
      final b = SelectorRow(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        label: label,
        onPressed: onPressed,
        child: Row(
          spacing: 8,
          children: [
            RemixIcon(icon, size: 16, color: DifyColors.textTertiary),
            Expanded(child: DifyText(label, DifyType.systemSmRegular, color: DifyColors.textSecondary)),
          ],
        ),
      );
      return link ? Semantics(link: true, linkUrl: Uri.parse('/agents'), child: b) : b;
    }

    return DifyBlurredBox(
      blur: 4,
      borderRadius: BorderRadius.circular(DifyRadius.xl),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        boxShadow: DifyShadows.lg,
      ),
      child: SizedBox(
        width: 240,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: SelectorSearchInput(
                value: _search,
                focusNode: _focus,
                placeholder: _agent('roster.nodeSelector.searchPlaceholder'),
                label: _agent('roster.searchLabel'),
                onChanged: (v) {
                  setState(() => _search = v);
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 300), () => mounted ? _load(v.trim()) : null);
                },
              ),
            ),
            if (status != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Semantics(
                  liveRegion: true,
                  child: DifyText(status, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                ),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 216),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (agents != null && !_error)
                      for (final a in agents)
                        SelectorRow(
                          height: null,
                          padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                          label: '${a.name} ${a.role ?? a.description ?? ''}'.trim(),
                          onPressed: () => _choose(a),
                          child: Row(
                            spacing: 8,
                            children: [
                              _AgentAvatar(agent: a),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  spacing: 2,
                                  children: [
                                    DifyText(a.name, DifyType.systemSmMedium, color: DifyColors.textSecondary),
                                    DifyText(
                                      a.role ?? a.description ?? '',
                                      DifyType.systemXsRegular,
                                      color: DifyColors.textTertiary,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.onStartFromScratch != null)
                    footerButton(
                      _agent('roster.nodeSelector.startFromScratch'),
                      'add-line',
                      widget.onStartFromScratch!,
                    ),
                  footerButton(_agent('roster.nodeSelector.manageInAgentConsole'), 'arrow-right-up-line', () {
                    BlockSelectorScope.of(context).open('/agents');
                    widget.onClose?.call();
                  }, link: true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AppIcon `small` (32 px, rounded-lg): the agent's emoji on its background, or its image.
class _AgentAvatar extends StatelessWidget {
  const _AgentAvatar({required this.agent});
  final AgentOption agent;

  @override
  Widget build(BuildContext context) {
    final a = agent;
    final image = a.iconType == 'image' && a.icon != null;
    final bg = int.tryParse((a.iconBackground ?? '').replaceFirst('#', ''), radix: 16);
    return Container(
      width: 32,
      height: 32,
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg == null ? DifyColors.stateBaseHover : Color(0xFF000000 | bg),
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      child: image
          ? BlockSelectorScope.of(context).iconBuilder?.call(context, a.icon, 32) ?? const SizedBox.shrink()
          : Text(a.icon ?? '', style: difyEmojiTextStyle(18)),
    );
  }
}
