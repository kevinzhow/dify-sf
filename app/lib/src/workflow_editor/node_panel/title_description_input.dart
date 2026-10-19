/// The node panel's title and description fields (nodes/_base/components/title-description-input.tsx), bound to one
/// register of the shared document each.
///
/// A draft remembers the document version it began on (its first keystroke) and hands it to the commit, so a write
/// that landed meanwhile makes the edit conflict instead of being overwritten silently. While there is no draft the
/// field shows the document's value (remote edits appear at once, as Dify syncs collaborative updates); a draft is
/// never clobbered by them. Drafts are committed when the field closes, never dropped.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../design/dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import '../../design/widgets/widgets.dart';

/// Commits [text], drafted on document version [base].
typedef DraftCommit = void Function(String text, int base);

/// The draft bookkeeping both fields share.
mixin _Draft<T extends StatefulWidget> on State<T> {
  late final controller = TextEditingController(text: value);
  late final focus = FocusNode()..addListener(_focusChanged);
  bool focused = false;
  int? _base;

  String get value;
  int Function() get currentVersion;
  DraftCommit get onCommit;

  /// What a commit of [text] does instead of committing it (the title reverts when emptied); null: commit.
  String? revertTo(String text) => null;

  void changed(String _) => _base ??= currentVersion();

  void commit() {
    final base = _base;
    if (base == null) return;
    _base = null;
    final text = controller.text;
    final revert = revertTo(text);
    if (revert != null) {
      if (mounted) controller.text = revert;
      return;
    }
    if (text != value) onCommit(text, base);
  }

  void _focusChanged() {
    if (focus.hasFocus != focused) setState(() => focused = focus.hasFocus);
    if (!focus.hasFocus) commit();
  }

  /// The document's value, unless a draft is open.
  void follow() {
    if (_base == null && controller.text != value) {
      controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
  }

  @override
  void dispose() {
    commit();
    focus.dispose();
    controller.dispose();
    super.dispose();
  }
}

/// TitleInput: `mr-2 h-7 min-w-0 grow rounded-md border border-transparent px-1 system-xl-semibold text-text-primary
/// focus:shadow-xs`, placeholder "Add title...". Committed on blur; Enter blurs; an emptied title goes back to the
/// node's.
class TitleInput extends StatefulWidget {
  const TitleInput({super.key, required this.value, required this.onCommit, required this.currentVersion});

  final String value;
  final DraftCommit onCommit;

  /// The document version right now (read at a draft's first keystroke).
  final int Function() currentVersion;

  @override
  State<TitleInput> createState() => _TitleInputState();
}

class _TitleInputState extends State<TitleInput> with _Draft<TitleInput> {
  @override
  String get value => widget.value;
  @override
  int Function() get currentVersion => widget.currentVersion;
  @override
  DraftCommit get onCommit => widget.onCommit;

  @override
  String? revertTo(String text) => text.isEmpty ? widget.value : null;

  @override
  void didUpdateWidget(TitleInput old) {
    super.didUpdateWidget(old);
    follow();
  }

  @override
  Widget build(BuildContext context) {
    final style = difyStyle(DifyType.systemXlSemibold, DifyColors.textPrimary);
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 5), // px-1 inside the 1 px border
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DifyRadius.md),
        boxShadow: focused ? DifyShadows.xs : null,
      ),
      child: TextField(
        controller: controller,
        focusNode: focus,
        style: style,
        cursorColor: DifyColors.textPrimary,
        cursorWidth: 1,
        maxLines: 1,
        decoration: InputDecoration.collapsed(
          hintText: DifyI18n.tr('workflow', 'common.addTitle'),
          hintStyle: style.copyWith(color: DifyColors.componentsInputTextPlaceholder),
        ),
        onChanged: changed,
        onSubmitted: (_) => focus.unfocus(),
      ),
    );
  }
}

/// DescriptionInput: `max-h-15 overflow-y-auto rounded-lg bg-components-panel-bg px-2 py-1.25`, `shadow-xs` while
/// focused, around an autosizing `text-xs leading-4.5` text area (caret `#295EFF`, placeholder "Add description..." in
/// `text-quaternary`). Dify writes every keystroke; here typing is committed after a pause of [debounce] (one small
/// op instead of one per key) and on blur.
class DescriptionInput extends StatefulWidget {
  const DescriptionInput({
    super.key,
    required this.value,
    required this.onCommit,
    required this.currentVersion,
    this.debounce = const Duration(milliseconds: 700),
  });

  final String value;
  final DraftCommit onCommit;
  final int Function() currentVersion;
  final Duration debounce;

  @override
  State<DescriptionInput> createState() => _DescriptionInputState();
}

class _DescriptionInputState extends State<DescriptionInput> with _Draft<DescriptionInput> {
  Timer? _timer;

  @override
  String get value => widget.value;
  @override
  int Function() get currentVersion => widget.currentVersion;
  @override
  DraftCommit get onCommit => widget.onCommit;

  @override
  void changed(String text) {
    super.changed(text);
    _timer?.cancel();
    _timer = Timer(widget.debounce, commit);
  }

  @override
  void commit() {
    _timer?.cancel();
    super.commit();
  }

  @override
  void didUpdateWidget(DescriptionInput old) {
    super.didUpdateWidget(old);
    follow();
  }

  @override
  Widget build(BuildContext context) {
    final style = difyTextStyle(DifyTw.textXsLeading18, DifyColors.textPrimary);
    return Container(
      constraints: const BoxConstraints(maxHeight: 60),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        boxShadow: focused ? DifyShadows.xs : null,
      ),
      child: TextField(
        controller: controller,
        focusNode: focus,
        style: style,
        cursorColor: DifyCaretColors.tagInput,
        cursorWidth: 1,
        minLines: 1,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        decoration: InputDecoration.collapsed(
          hintText: DifyI18n.tr('workflow', 'common.addDescription'),
          hintStyle: style.copyWith(color: DifyColors.textQuaternary),
        ),
        onChanged: changed,
      ),
    );
  }
}
