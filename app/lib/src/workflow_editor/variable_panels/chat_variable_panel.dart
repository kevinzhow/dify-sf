/// The Conversation Variables panel of chatflows (panel/chat-variable-panel: index.tsx,
/// components/variable-item.tsx, components/variable-modal-trigger.tsx) on the collaborative document: changes are
/// item ops on the document's `conversation_variables` list (an edit carries the version its modal opened on).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../cards/card_kit.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../../workflow/dify_json.dart';
import '../block_selector/selector_widgets.dart' show SelectorBlockIcon;
import '../node_panel/bodies/core/core_kit.dart' show showRemoveEffectVarConfirm;
import '../store/store.dart';
import 'app_variables.dart';
import 'chat_variable_modal.dart';
import 'panel_kit.dart';

/// ChatVariablePanel: the tips (open at first, toggled by the book button), "Add Variable" and the variables of
/// [WorkflowStore.conversationVariables]. Deleting one that nodes use asks first; deleting clears its uses and
/// renaming renames them.
class ChatVariablePanel extends StatefulWidget {
  const ChatVariablePanel({super.key, required this.controller});
  final EditorController controller;

  @override
  State<ChatVariablePanel> createState() => _ChatVariablePanelState();
}

class _ChatVariablePanelState extends State<ChatVariablePanel> {
  bool _showTip = true;
  bool _showVariableModal = false;
  DifyVariable? _currentVar;
  int _base = 0;

  EditorController get _c => widget.controller;
  WorkflowStore get _store => WorkflowStoreScope.of(context);
  AppVariableList get _list => AppVariableList(_c, AppVariableList.conversation);

  List<String> _selector(DifyVariable v) => ['conversation', '${v['name']}'];

  void _handleEdit(DifyVariable v) => setState(() {
    _currentVar = v;
    _base = _c.seenVersion;
    _showVariableModal = true;
  });

  void _deleteCheck(DifyVariable v) {
    if (findUsedVarNodes(_selector(v), _c.doc.nodes.values).isNotEmpty) {
      showRemoveEffectVarConfirm(context, onConfirm: () => _handleDelete(v));
    } else {
      _handleDelete(v);
    }
  }

  void _handleDelete(DifyVariable v) {
    updateAffectedNodes(_c, _store, _selector(v), const []);
    _list.remove('${v['id']}');
  }

  void _handleSave(DifyVariable v) {
    final current = _currentVar;
    if (current == null) return _list.add(v);
    final live = variableById(_c.appLists.conversationVariables, current['id']);
    final seen = live != null && jsonEquals(live, current);
    _list.update(v, base: _base);
    // A variable someone changed meanwhile is refused (the editor shows the conflict): its uses stay.
    if (seen && current['name'] != v['name']) updateAffectedNodes(_c, _store, _selector(current), _selector(v));
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return VariablePanelShell(
      title: tw('chatVariable.panelTitle'),
      actions: [
        Semantics(
          expanded: _showTip,
          child: _TipsButton(open: _showTip, onPressed: () => setState(() => _showTip = !_showTip)),
        ),
        DifyIconButton(
          label: tc('operation.close'),
          onPressed: () => store.setShowChatVariablePanel(false),
          icon: const RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
        ),
      ],
      children: [
        if (_showTip) const _Tips(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: ChatVariableModalTrigger(
            open: _showVariableModal,
            setOpen: (v) => setState(() => _showVariableModal = v),
            showTip: _showTip,
            chatVar: _currentVar,
            onSave: _handleSave,
            onClose: () => setState(() => _currentVar = null),
          ),
        ),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: store.conversationVariables,
            builder: (context, varList, _) => ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final v in varList)
                  ChatVariableItem(key: ValueKey(v['id']), item: v, onEdit: _handleEdit, onDelete: _deleteCheck),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// VariableModalTrigger: "Add Variable" with the [ChatVariableModal] (for [chatVar], or a new variable) in a popover
/// beside it (aligned lower while the tips show). Closing it any way ([setOpen] false) calls [onClose].
class ChatVariableModalTrigger extends StatelessWidget {
  const ChatVariableModalTrigger({
    super.key,
    required this.open,
    required this.setOpen,
    required this.showTip,
    this.chatVar,
    required this.onClose,
    required this.onSave,
  });
  final bool open, showTip;
  final ValueChanged<bool> setOpen;
  final DifyVariable? chatVar;
  final VoidCallback onClose;
  final ValueChanged<DifyVariable> onSave;

  @override
  Widget build(BuildContext context) => VariableModalTrigger(
    open: open,
    onOpenChange: (next) {
      setOpen(next);
      if (!next) onClose();
    },
    label: tw('chatVariable.button'),
    alignOffset: showTip ? -278 : -48,
    modalKey: chatVar?['id'],
    modalBuilder: (context) => ChatVariableModal(
      chatVar: chatVar,
      onSave: onSave,
      onClose: () {
        onClose();
        setOpen(false);
      },
    ),
  );
}

/// The tips toggle (`IconButton` with `i-ri-book-open-line`, `rounded-lg text-text-secondary`; open
/// `bg-state-accent-active text-text-accent`, hover `bg-state-accent-active-alt`).
class _TipsButton extends StatelessWidget {
  const _TipsButton({required this.open, required this.onPressed});
  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: tw('chatVariable.tips'),
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: open
            ? (hovered ? DifyColors.stateAccentActiveAlt : DifyColors.stateAccentActive)
            : hovered
            ? DifyColors.stateBaseHover
            : null,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      alignment: Alignment.center,
      child: RemixIcon('book-open-line', size: 16, color: open ? DifyColors.textAccent : DifyColors.textSecondary),
    ),
  );
}

/// The tips: what conversation variables are, with an example (a variable card, an Assigner writing it, an LLM
/// reading it) in `rounded-2xl bg-background-section-burn p-3`, its caret pointing at the tips button.
class _Tips extends StatelessWidget {
  const _Tips();

  @override
  Widget build(BuildContext context) {
    Widget arrow(String icon, String label, {required bool before}) => SizedBox(
      width: 64,
      height: 12,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          spacing: 4,
          children: [
            if (!before) DifyText(label, DifyType.system2xsMedium, color: DifyColors.textTertiary),
            // `h-2 grow`: the 21 x 8 arrow.
            Expanded(
              child: SizedBox(
                height: 8,
                child: OverflowBox(
                  maxWidth: 21,
                  maxHeight: 21,
                  child: DifyIcon('vender/line/others/$icon', size: 21, color: DifyColors.textQuaternary),
                ),
              ),
            ),
            if (before) DifyText(label, DifyType.system2xsMedium, color: DifyColors.textTertiary),
          ],
        ),
      ),
    );
    Widget flow(Widget arrow, String type, String label) => Row(
      spacing: 8,
      children: [
        arrow,
        SelectorBlockIcon(type: type),
        Expanded(
          child: DifyText(tw(label), DifyType.systemXsSemibold, color: DifyColors.textSecondary),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: DifyColors.backgroundSectionBurn,
              borderRadius: BorderRadius.circular(DifyRadius.xxl),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // An `inline-block` badge on the box's 24 px line (the inherited 16 px font): 4 px above it.
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                  decoration: BoxDecoration(
                    border: Border.all(color: DifyColors.dividerDeep),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const DifyText('TIPS', DifyType.system2xsMediumUppercase, color: DifyColors.textTertiary),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 16),
                  child: DifyText(
                    tw('chatVariable.panelDescription'),
                    DifyType.systemSmRegular,
                    color: DifyColors.textSecondary,
                    maxLines: null,
                  ),
                ),
                Row(
                  spacing: 8,
                  children: [
                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                      decoration: BoxDecoration(
                        color: DifyColors.workflowBlockBg,
                        border: Border.all(color: DifyColors.workflowBlockBorder),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: DifyShadows.md,
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: EdgeInsets.only(bottom: 4),
                            child: DifyIcon(
                              'vender/line/others/bubble-x',
                              size: 16,
                              color: DifyColors.utilColorsTealTeal700,
                            ),
                          ),
                          DifyText('conversation_var', DifyType.systemXsSemibold, color: DifyColors.textSecondary),
                          DifyText('String', DifyType.system2xsRegular, color: DifyColors.textTertiary),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8, top: 4),
                            child: flow(arrow('long-arrow-left', 'WRITE', before: true), 'assigner', 'blocks.assigner'),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: flow(arrow('long-arrow-right', 'READ', before: false), 'llm', 'blocks.llm'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            top: -4,
            right: 38,
            child: Transform.rotate(
              angle: math.pi / 4,
              child: const SizedBox.square(
                dimension: 12,
                child: ColoredBox(color: DifyColors.backgroundSectionBurn),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// VariableItem: the variable's card (teal bubble icon, name, capitalised type) with its description below.
class ChatVariableItem extends StatelessWidget {
  const ChatVariableItem({super.key, required this.item, required this.onEdit, required this.onDelete});
  final DifyVariable item;
  final ValueChanged<DifyVariable> onEdit, onDelete;

  @override
  Widget build(BuildContext context) {
    final description = '${item['description'] ?? ''}';
    return VariableItemCard(
      icon: const DifyIcon('vender/line/others/bubble-x', size: 16, color: DifyColors.utilColorsTealTeal700),
      name: DifyText('${item['name']}', DifyType.systemSmMedium),
      type: capitalize('${item['value_type'] ?? ''}'),
      onEdit: () => onEdit(item),
      onDelete: () => onDelete(item),
      body: description.isEmpty
          ? null
          : DifyText(description, DifyType.systemXsRegular, color: DifyColors.textTertiary),
    );
  }
}
