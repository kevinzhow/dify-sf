/// The Snippets tab (block-selector/snippets/**): published snippets matching the search, inserted on click.
library;

import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../store/workflow_store.dart' show DifyJson;
import 'block_selector_data.dart';
import 'selector_widgets.dart';

/// Snippets: its search field (`p-2`, a ghost clear button), then (below a rule) the loading skeleton, "No snippets
/// were found", or the snippets (`max-h-120`): name in `system-md-semibold`, one line of description, a preview of
/// name, description, block icons and author. Choosing one inserts it ([BlockSelectorData.onInsertSnippet]) and,
/// once inserted, calls [onInserted].
class SnippetsPanel extends StatefulWidget {
  const SnippetsPanel({
    super.key,
    required this.searchText,
    this.onSearchTextChange,
    this.insertPayload,
    this.onInserted,
  });

  final String searchText;
  final ValueChanged<String>? onSearchTextChange;
  final DifyJson? insertPayload;
  final VoidCallback? onInserted;

  @override
  State<SnippetsPanel> createState() => _SnippetsPanelState();
}

class _SnippetsPanelState extends State<SnippetsPanel> {
  List<SnippetItem>? _items;
  String? _loaded;
  int _request = 0;
  final _focus = FocusNode(debugLabel: 'snippet search');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _load(String keyword) {
    if (_loaded == keyword) return;
    _loaded = keyword;
    final search = BlockSelectorScope.of(context).searchSnippets;
    final id = ++_request;
    if (search == null) {
      _items = const [];
      return;
    }
    // Rows already shown stay while the new search runs (useInfiniteSnippetList keeps its cached pages).
    if (_items?.isEmpty ?? true) _items = null;
    search(keyword).then(
      (r) => mounted && id == _request ? setState(() => _items = r) : null,
      onError: (Object _) => mounted && id == _request ? setState(() => _items = const []) : null,
    );
  }

  Future<void> _insert(SnippetItem s) async {
    final inserted = await BlockSelectorScope.of(context).onInsertSnippet?.call(s, widget.insertPayload) ?? false;
    if (inserted) widget.onInserted?.call();
  }

  @override
  Widget build(BuildContext context) {
    _load(widget.searchText.trim());
    final items = _items;
    final label = wf('tabs.searchSnippets');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Semantics(
            textField: true,
            label: label,
            child: DifyInput(
              value: widget.searchText,
              onChanged: widget.onSearchTextChange,
              placeholder: label,
              semanticLabel: label,
              focusNode: _focus,
              height: 32,
              leading: Padding(
                padding: EdgeInsets.only(left: 8, right: 6),
                child: RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
              ),
              trailing: widget.searchText.isEmpty
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: DifyIconButton(
                        label: wf('tabs.clearSnippetSearch'),
                        variant: DifyButtonVariant.ghost,
                        onPressed: () => widget.onSearchTextChange?.call(''),
                        icon: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
                      ),
                    ),
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
          ),
          child: items == null
              ? const _Skeleton()
              : items.isEmpty
              ? const SnippetEmptyState()
              : PreviewCardScope(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 480, maxWidth: 500),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final s in items)
                            PreviewCardTrigger(
                              key: ValueKey(s.id),
                              preview: (_) => SnippetDetailCard(snippet: s),
                              child: SnippetListItem(snippet: s, onPressed: () => _insert(s)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// The loading skeleton: four faded bars.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => Semantics(
    label: DifyI18n.tr('common', 'loading'),
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        children: [
          for (final o in const [0.2, 0.2, 0.2, 0.1])
            Opacity(
              opacity: o,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 200,
                    height: 8,
                    decoration: BoxDecoration(
                      color: DifyColors.textQuaternary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// snippet-empty-state.tsx: `min-h-120`, the search-menu icon and "No snippets were found".
class SnippetEmptyState extends StatelessWidget {
  const SnippetEmptyState({super.key});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 480),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: 8,
      children: [
        DifyIcon('vender/line/general/search-menu', size: 32, color: DifyColors.textTertiary),
        DifyText(wf('tabs.noSnippetsFound'), DifyType.systemSmRegular, color: DifyColors.textSecondary),
      ],
    ),
  );
}

/// snippet-list-item.tsx: `rounded-xl px-3 py-2`, hover `bg-background-default-hover`.
class SnippetListItem extends StatelessWidget {
  const SnippetListItem({super.key, required this.snippet, this.onPressed});
  final SnippetItem snippet;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: snippet.description.isEmpty ? snippet.name : '${snippet.name} ${snippet.description}',
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: hovered ? DifyColors.backgroundDefaultHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
      ),
      foregroundDecoration: insetFocusRing(focused, DifyRadius.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 4,
        children: [
          DifyText(snippet.name, DifyType.systemMdSemibold, color: DifyColors.textSecondary),
          if (snippet.description.isNotEmpty)
            DifyText(snippet.description, DifyType.systemSmRegular, color: DifyColors.textTertiary),
        ],
      ),
    ),
  );
}

/// snippet-detail-card.tsx: the name, the description (`w-50`), the graph's block icons and the author.
class SnippetDetailCard extends StatelessWidget {
  const SnippetDetailCard({super.key, required this.snippet});
  final SnippetItem snippet;

  @override
  Widget build(BuildContext context) {
    final s = snippet;
    final author = (s.authorName?.isNotEmpty ?? false) ? s.authorName! : DifyI18n.tr('snippet', 'unknownUser');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DifyText(s.name, DifyType.systemMdMedium, color: DifyColors.textPrimary, maxLines: null),
        if (s.description.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: 200,
            child: DifyText(s.description, DifyType.systemXsRegular, color: DifyColors.textSecondary, maxLines: null),
          ),
        ],
        if (s.blockTypes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(spacing: 2, children: [for (final t in s.blockTypes.toSet()) SelectorBlockIcon(type: t)]),
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: DifyText(author, DifyType.systemXsRegular, color: DifyColors.textTertiary),
        ),
      ],
    );
  }
}
