/// base/chat/chat as the chatflow Debug & Preview uses it (no avatars, no annotations or feedback): Chat (the list and
/// the footer), Question (the bubble with copy / edit on hover and inline editing), Answer (the workflow process, the
/// streamed Markdown, files, opening statement questions, sibling switch, copy / regenerate on hover),
/// WorkflowProcessItem, ChatInputArea with the feature bar, TryToAsk and ContentSwitch. Chat items are Dify's ChatItem
/// JSON (see DebugChatController).
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../design/css_metrics.dart';
import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../../features/features_store.dart' show buildInitialFeatures, featureEnabled;
import '../../store/workflow_store.dart' show DifyJson;
import '../run_types.dart' show WorkflowRunningStatus;
import '../../node_panel/bodies/data/human_input/human_input_kit.dart' show HumanInputHost;
import 'before_run_form.dart' show RunFilePicker;
import 'human_input_content.dart';
import 'markdown.dart';
import 'run_widgets.dart';
import 'tracing_panel.dart';

String _tc(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

typedef ChatOnSend = bool Function(String message, [List<DifyJson>? files]);

/// The callbacks the chat's parts share (ChatContextProvider).
class ChatContext extends InheritedWidget {
  const ChatContext({
    super.key,
    this.onSend,
    this.onRegenerate,
    this.readonly = false,
    this.toast,
    this.onHumanInputFormSubmit,
    this.getHumanInputNodeData,
    this.pickFile,
    this.onFeedback,
    required super.child,
  });

  final ChatOnSend? onSend;
  final void Function(DifyJson item, {String? editedMessage, List<DifyJson>? editedFiles})? onRegenerate;
  final bool readonly;
  final void Function(DifyToastType type, String message)? toast;

  /// Submits a paused run's human input form (`onHumanInputFormSubmit`).
  final HumanInputFormSubmit? onHumanInputFormSubmit;

  /// A form's Human Input node data (`getHumanInputNodeData`: its delivery methods give the form's tips).
  final HumanInputNodeData? getHumanInputNodeData;
  final RunFilePicker? pickFile;

  /// The logs' admin feedback (`onFeedback` with `supportFeedback` + `supportAnnotation`): answers show the user's
  /// rating and the admin's like / dislike (pressed: click again to clear). `{rating, content}`; resolves to whether it
  /// was saved. Null (the debugger): no feedback bar.
  final Future<bool> Function(String messageId, Map<String, Object?> feedback)? onFeedback;

  static ChatContext? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ChatContext>();

  @override
  bool updateShouldNotify(ChatContext old) =>
      onSend != old.onSend ||
      onRegenerate != old.onRegenerate ||
      readonly != old.readonly ||
      onHumanInputFormSubmit != old.onHumanInputFormSubmit ||
      getHumanInputNodeData != old.getHumanInputNodeData ||
      onFeedback != old.onFeedback;
}

void _copy(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  (ChatContext.maybeOf(context)?.toast ?? difyToast)(DifyToastType.success, _tc('actionMsg.copySuccessfully'));
}

/// The hover action bar (`gap-0.5 rounded-[10px] border-[0.5px] border-components-actionbar-border
/// bg-components-actionbar-bg p-0.5 shadow-md backdrop-blur-xs`).
class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 2, sigmaY: 2),
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: DifyColors.componentsActionbarBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: DifyColors.componentsActionbarBorder, width: Css.hairline),
          boxShadow: DifyShadows.md,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, spacing: 2, children: children),
      ),
    ),
  );
}

/// ContentSwitch: "‹ 1 / 3 ›" between an item's siblings.
class ContentSwitch extends StatelessWidget {
  const ContentSwitch({
    super.key,
    required this.count,
    required this.currentIndex,
    required this.prevDisabled,
    required this.nextDisabled,
    required this.switchSibling,
  });

  final int? count;
  final int? currentIndex;
  final bool prevDisabled, nextDisabled;
  final void Function(bool next) switchSibling;

  @override
  Widget build(BuildContext context) {
    if (count == null || count! <= 1 || currentIndex == null) return const SizedBox.shrink();
    Widget arrow(bool next) {
      final disabled = next ? nextDisabled : prevDisabled;
      return DifyPressable(
        semanticLabel: next ? 'Next' : 'Previous',
        disabled: disabled,
        onPressed: () => switchSibling(next),
        builder: (context, h, f) => Opacity(
          opacity: disabled ? 0.3 : 1,
          child: RotatedBox(
            quarterTurns: next ? 0 : 2,
            child: DifyIcon('vender/line/arrows/chevron-right', size: 14, color: DifyColors.textPrimary),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          arrow(false),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: DifyTextLine(
              '${currentIndex! + 1} /$count',
              style: difyTextStyle(DifyTw.textXs, DifyColors.textPrimary),
            ),
          ),
          arrow(true),
        ],
      ),
    );
  }
}

/// Question: the user's message right-aligned in a `rounded-2xl` bubble (`px-4 py-3 text-sm`), copy / edit on hover
/// to its left; editing turns it into a textarea with Cancel and Save (Save resends as a sibling).
class ChatQuestion extends StatefulWidget {
  const ChatQuestion({super.key, required this.item, this.switchSibling, this.enableEdit = true});
  final DifyJson item;
  final ValueChanged<String>? switchSibling;
  final bool enableEdit;

  @override
  State<ChatQuestion> createState() => _ChatQuestionState();
}

class _ChatQuestionState extends State<ChatQuestion> {
  bool _hover = false;
  bool _editing = false;
  String _edited = '';

  String get _content => '${widget.item['content'] ?? ''}';

  void _resend() {
    setState(() => _editing = false);
    ChatContext.maybeOf(context)?.onRegenerate?.call(
      widget.item,
      editedMessage: _edited,
      editedFiles: (widget.item['message_files'] as List?)?.cast<DifyJson>(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final files = (item['message_files'] as List?)?.cast<DifyJson>() ?? const [];
    final bubble = Container(
      width: _editing ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: _editing
          ? BoxDecoration(
              color: DifyColors.componentsPanelBgBlur,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: DifyColors.componentsOptionCardOptionSelectedBorder, width: 3),
              boxShadow: DifyShadows.lg,
            )
          : BoxDecoration(
              // `bg-background-gradient-bg-fill-chat-bubble-bg-3` (web/themes/manual-*.css).
              color: DifyColors.backgroundGradientBgFillChatBubbleBg3,
              borderRadius: BorderRadius.circular(DifyRadius.xxl),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (files.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: _editing ? 12 : 8),
              child: RunFileList(files: files),
            ),
          if (!_editing)
            DifyMarkdown(content: _content)
          else ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 158),
              child: DifyTextarea(value: _edited, onChanged: (v) => _edited = v, minHeight: 28),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 96),
                  child: DifyButton(
                    onPressed: () => setState(() => _editing = false),
                    child: DifyTextLine(_tc('operation.cancel')),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 96),
                  child: DifyButton(
                    variant: DifyButtonVariant.primary,
                    onPressed: _resend,
                    child: DifyTextLine(_tc('operation.save')),
                  ),
                ),
              ],
            ),
          ],
          if (!_editing)
            ContentSwitch(
              count: (item['siblingCount'] as num?)?.toInt(),
              currentIndex: (item['siblingIndex'] as num?)?.toInt(),
              prevDisabled: item['prevSibling'] == null,
              nextDisabled: item['nextSibling'] == null,
              switchSibling: (next) {
                final id = item[next ? 'nextSibling' : 'prevSibling'];
                if (id is String) widget.switchSibling?.call(id);
              },
            ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Padding(
          padding: const EdgeInsets.only(left: 56, right: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_editing)
                Visibility(
                  visible: _hover,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _ActionBar(
                      children: [
                        DifyIconButton(
                          label: _tc('operation.copy'),
                          icon: const RemixIcon('clipboard-line', size: 16),
                          onPressed: () => _copy(context, _content),
                        ),
                        if (widget.enableEdit)
                          DifyIconButton(
                            label: _tc('operation.edit'),
                            icon: const RemixIcon('edit-line', size: 16),
                            onPressed: () => setState(() {
                              _editing = true;
                              _edited = _content;
                            }),
                          ),
                      ],
                    ),
                  ),
                ),
              _editing ? Expanded(child: bubble) : Flexible(child: bubble),
            ],
          ),
        ),
      ),
    );
  }
}

/// WorkflowProcessItem: the run inside an answer — collapsed, the status icon and the latest node (or the error);
/// open, "Workflow Process", the error and the tracing (node rows without process details when [hideProcessDetail]).
class WorkflowProcessItem extends StatefulWidget {
  const WorkflowProcessItem({
    super.key,
    required this.data,
    this.expand = false,
    this.hideInfo = false,
    this.hideProcessDetail = false,
    this.readonly = false,
  });

  final DifyJson data;
  final bool expand;
  final bool hideInfo;
  final bool hideProcessDetail;
  final bool readonly;

  @override
  State<WorkflowProcessItem> createState() => _WorkflowProcessItemState();
}

class _WorkflowProcessItemState extends State<WorkflowProcessItem> {
  late bool _collapse = !widget.expand;

  @override
  void didUpdateWidget(WorkflowProcessItem old) {
    super.didUpdateWidget(old);
    if (old.expand != widget.expand) _collapse = !widget.expand;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.readonly) return const SizedBox.shrink();
    final data = widget.data;
    final status = data['status'];
    final running = status == WorkflowRunningStatus.running;
    final succeeded = status == WorkflowRunningStatus.succeeded;
    final failed = status == WorkflowRunningStatus.failed || status == WorkflowRunningStatus.stopped;
    final paused = status == WorkflowRunningStatus.paused;
    final tracing = [for (final t in (data['tracing'] as List? ?? const [])) t as DifyJson];
    final latest = tracing.lastOrNull;
    final fallbackTitle = DifyI18n.tr('workflow', 'common.workflowProcess');
    final error = data['error'] as String?;
    final collapsedTitle = failed
        ? [
            error,
            latest?['error'],
            latest?['title'],
          ].whereType<String>().firstWhere((s) => s.isNotEmpty, orElse: () => fallbackTitle)
        : (latest?['title'] as String?)?.isNotEmpty == true
        ? latest!['title'] as String
        : fallbackTitle;
    final collapse = _collapse;
    final Color? bg = collapse
        ? null
        : running
        ? DifyColors.backgroundSectionBurn
        : succeeded
        ? DifyColors.stateSuccessHover
        : failed
        ? DifyColors.stateDestructiveHover
        : paused
        ? DifyColors.stateWarningHover
        : null;
    final Gradient? gradient = !collapse
        ? null
        : failed
        ? DifyGradients.workflowProcessFailedBg
        : paused
        ? DifyGradients.workflowProcessPausedBg
        : DifyGradients.workflowProcessBg;
    final icon = running
        ? DifySpinner(size: 14, color: DifyColors.textTertiary)
        : succeeded
        ? DifyIcon('vender/solid/general/check-circle', size: 14, color: DifyColors.textSuccess)
        : failed
        ? RemixIcon('error-warning-fill', size: 14, color: DifyColors.textDestructive)
        : paused
        ? RemixIcon('pause-circle-fill', size: 14, color: DifyColors.textWarningSecondary)
        : null;
    return NegativeMarginX(
      margin: 4,
      child: Container(
        width: double.infinity,
        padding: collapse
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 7)
            : const EdgeInsets.fromLTRB(4, 7, 4, 4),
        decoration: BoxDecoration(
          color: bg,
          gradient: gradient,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          border: collapse
              ? Border(left: BorderSide(color: DifyColors.componentsPanelBorder, width: 0.25))
              : Border.all(color: DifyColors.componentsPanelBorderSubtle, width: Css.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExpandedSemantics(
              expanded: !collapse,
              child: DifyPressable(
                semanticLabel: collapse ? collapsedTitle : fallbackTitle,
                onPressed: () => setState(() => _collapse = !_collapse),
                builder: (context, h, f) => Padding(
                  padding: EdgeInsets.symmetric(horizontal: collapse ? 0 : 6),
                  child: Row(
                    children: [
                      if (icon != null) Padding(padding: const EdgeInsets.only(right: 4), child: icon),
                      Expanded(
                        child: DifyText(
                          collapse ? collapsedTitle : fallbackTitle,
                          DifyType.systemXsMedium,
                          color: collapse && failed && (error ?? '').isNotEmpty
                              ? DifyColors.textDestructive
                              : DifyColors.textSecondary,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: RotatedBox(
                          quarterTurns: collapse ? 0 : 1,
                          child: RemixIcon('arrow-right-s-line', size: 16, color: DifyColors.textTertiary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!collapse)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (failed && (error ?? '').isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: DifyColors.stateDestructiveHover,
                          borderRadius: BorderRadius.circular(DifyRadius.lg),
                          border: Border.all(color: DifyColors.stateDestructiveBorder, width: Css.hairline),
                        ),
                        child: Semantics(
                          liveRegion: true,
                          child: DifyText(
                            error!,
                            DifyType.systemXsRegular,
                            color: DifyColors.textDestructive,
                            maxLines: null,
                          ),
                        ),
                      ),
                    if (tracing.isNotEmpty)
                      TracingPanel(
                        list: tracing,
                        hideNodeInfo: widget.hideInfo,
                        hideNodeProcessDetail: widget.hideProcessDetail,
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Answer: the bubble (`rounded-2xl bg-chat-bubble-bg px-4 py-3 body-lg-regular`, full width with a workflow
/// process) with the process, the reasoning, the dots while waiting for text, the Markdown, files, the opening
/// statement's questions and the sibling switch; copy / regenerate on hover below its right edge.
class ChatAnswer extends StatefulWidget {
  const ChatAnswer({
    super.key,
    required this.item,
    this.responding = false,
    this.hideProcessDetail = false,
    this.switchSibling,
    this.noChatInput = false,
  });

  final DifyJson item;
  final bool responding;
  final bool hideProcessDetail;
  final ValueChanged<String>? switchSibling;
  final bool noChatInput;

  @override
  State<ChatAnswer> createState() => _ChatAnswerState();
}

class _ChatAnswerState extends State<ChatAnswer> {
  bool _hover = false;

  /// The admin feedback set here until the item is rebuilt from the server (`adminFeedbackOverride`).
  Map<String, Object?>? _adminOverride;

  Future<bool> _feedback(
    Future<bool> Function(String, Map<String, Object?>) onFeedback,
    String? rating, [
    String? content,
  ]) async {
    final next = {'rating': rating, 'content': rating == null ? null : content};
    final ok = await onFeedback('${widget.item['id']}', next);
    if (ok && mounted) setState(() => _adminOverride = next);
    return ok;
  }

  /// The dislike: operation.tsx's "Provide Feedback" dialog asks what went wrong first; Submit saves the dislike with
  /// that text (the dialog stays open when saving fails), Cancel saves nothing.
  void _dislike(Future<bool> Function(String, Map<String, Object?>) onFeedback) => showDifyDialog<void>(
    context,
    builder: (dialog) => ChatFeedbackDialog(
      onCancel: () => Navigator.of(dialog).pop(),
      onSubmit: (content) async {
        if (await _feedback(onFeedback, 'dislike', content) && dialog.mounted) Navigator.of(dialog).pop();
      },
    ),
  );

  /// operation.tsx's admin feedback bar: the user's rating (read-only) and the admin's.
  Widget? _feedbackBar(ChatContext? ctx, bool isOpening) {
    final onFeedback = ctx?.onFeedback;
    if (onFeedback == null || isOpening) return null;
    final user = widget.item['feedback'] as Map?;
    final admin = _adminOverride ?? (widget.item['adminFeedback'] as Map?)?.cast<String, Object?>();
    final userRating = user?['rating'] as String?, adminRating = admin?['rating'] as String?;
    if (!_hover && userRating == null && adminRating == null) return null;
    final userLabel = DifyI18n.tr('app-log', 'table.header.userRate');
    final adminLabel = DifyI18n.tr('app-log', 'table.header.adminRate');
    final like = DifyI18n.tr('app-log', 'detail.operation.like'),
        dislike = DifyI18n.tr('app-log', 'detail.operation.dislike');
    Widget pressed(String rating, String label, {VoidCallback? onPressed}) {
      final isLike = rating == 'like';
      final icon = RemixIcon(
        isLike ? 'thumb-up-line' : 'thumb-down-line',
        size: 16,
        color: isLike ? DifyColors.textAccent : DifyColors.textDestructive,
      );
      final box = Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: isLike ? DifyColors.stateAccentActive : DifyColors.stateDestructiveHover,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Center(child: icon),
      );
      return onPressed == null
          ? Semantics(image: true, label: '$label: ${isLike ? like : dislike}', child: box)
          : DifyPressable(
              semanticLabel: '$label: ${isLike ? like : dislike}',
              onPressed: onPressed,
              builder: (context, h, f) => box,
            );
    }

    Widget tip(Map? feedback, String label, Widget child) =>
        DifyTooltip(content: DifyTextLine(ChatAnswerFeedback.tooltip(feedback, label)), child: child);
    return _ActionBar(
      children: [
        if (userRating != null) ...[
          tip(user, userLabel, pressed(userRating, userLabel)),
          Container(
            width: 0.5,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: DifyColors.componentsActionbarBorder,
          ),
        ],
        if (adminRating != null)
          tip(admin, adminLabel, pressed(adminRating, adminLabel, onPressed: () => _feedback(onFeedback, null)))
        else ...[
          tip(
            admin,
            adminLabel,
            DifyIconButton(
              label: '$adminLabel: $like',
              icon: const RemixIcon('thumb-up-line', size: 16),
              onPressed: () => _feedback(onFeedback, 'like'),
            ),
          ),
          tip(
            admin,
            adminLabel,
            DifyIconButton(
              label: '$adminLabel: $dislike',
              icon: const RemixIcon('thumb-down-line', size: 16),
              onPressed: () => _dislike(onFeedback),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final content = '${item['content'] ?? ''}';
    final contentIsEmpty = content.trim().isEmpty;
    final process = item['workflowProcess'] as DifyJson?;
    final reasoning = item['reasoningContent'];
    final hasReasoning = reasoning is Map && ReasoningPanel.textOf(reasoning).isNotEmpty;
    final responding = widget.responding;
    final reasoningDone = !contentIsEmpty || item['reasoningFinished'] == true || !responding;
    final allFiles = (item['allFiles'] as List?)?.cast<DifyJson>() ?? const [];
    final messageFiles = (item['message_files'] as List?)?.cast<DifyJson>() ?? const [];
    final isOpening = item['isOpeningStatement'] == true;
    final ctx = ChatContext.maybeOf(context);
    final suggested = [
      for (final q in (item['suggestedQuestions'] as List? ?? const []))
        if (q is String && q.trim().isNotEmpty) q,
    ];
    Widget bubbleBox(List<Widget> children, {required bool full, Key? key}) => Container(
      key: key,
      width: full ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: DifyGradients.chatBubbleBg,
        borderRadius: BorderRadius.circular(DifyRadius.xxl),
      ),
      child: DefaultTextStyle.merge(
        style: difyStyle(DifyType.bodyLgRegular, DifyColors.textPrimary),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    );
    Widget contentSwitch() => ContentSwitch(
      count: (item['siblingCount'] as num?)?.toInt(),
      currentIndex: (item['siblingIndex'] as num?)?.toInt(),
      prevDisabled: item['prevSibling'] == null,
      nextDisabled: item['nextSibling'] == null,
      switchSibling: (next) {
        final id = item[next ? 'nextSibling' : 'prevSibling'];
        if (id is String) widget.switchSibling?.call(id);
      },
    );
    final responseParts = <Widget>[
      if (hasReasoning) ReasoningPanel(content: reasoning, done: reasoningDone),
      if (responding && contentIsEmpty && !hasReasoning)
        const SizedBox(width: 24, height: 20, child: Center(child: DifyLoadingAnim())),
      if (!contentIsEmpty)
        DifyMarkdown(
          content: RegExp(r'^\\\\\S').hasMatch(content) && !RegExp(r'^`.*`$').hasMatch(content)
              ? '`$content`'
              : content,
          isStreaming: responding,
          color: item['isError'] == true ? DifyRunStatusColors.error : null,
        ),
      if (allFiles.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: RunFileList(files: allFiles),
        ),
      if (messageFiles.isNotEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: RunFileList(files: messageFiles),
        ),
      if (isOpening && suggested.isNotEmpty)
        Wrap(
          children: [
            for (final q in suggested)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: _SuggestedQuestion(
                  question: q,
                  readonly: ctx?.readonly ?? false,
                  onTap: () => ctx?.onSend?.call(q),
                ),
              ),
          ],
        ),
      contentSwitch(),
    ];
    // Human input forms (answer/index.tsx): the workflow process and the forms in a first bubble, the response in a
    // second one joined to it by a short line.
    final forms = [for (final f in (item['humanInputFormDataList'] as List? ?? const [])) f as DifyJson];
    final filled = [for (final f in (item['humanInputFilledFormDataList'] as List? ?? const [])) f as DifyJson];
    final Widget bubble;
    if (forms.isEmpty && filled.isEmpty) {
      bubble = bubbleBox([
        if (process != null) WorkflowProcessItem(data: process, hideProcessDetail: widget.hideProcessDetail),
        ...responseParts,
      ], full: process != null);
    } else {
      bubble = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          bubbleBox(key: const Key('chat-answer-container-humaninput'), [
            if (process != null) WorkflowProcessItem(data: process, hideProcessDetail: widget.hideProcessDetail),
            if (forms.isNotEmpty)
              HumanInputFormList(
                humanInputFormDataList: forms,
                onHumanInputFormSubmit: ctx?.onHumanInputFormSubmit,
                getHumanInputNodeData: ctx?.getHumanInputNodeData,
                pickFile: ctx?.pickFile,
                email: HumanInputHost.of(context).userEmail,
              ),
            if (filled.isNotEmpty) HumanInputFilledFormList(humanInputFilledFormDataList: filled),
            if (!responding && contentIsEmpty) contentSwitch(),
          ], full: true),
          if (responding || !contentIsEmpty || hasReasoning)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  bubbleBox(responseParts, full: true),
                  // `absolute -top-2 left-6 h-3 w-0.5 bg-chat-answer-human-input-form-divider-bg`.
                  Positioned(
                    top: -8,
                    left: 24,
                    width: 2,
                    height: 12,
                    child: DecoratedBox(
                      decoration: BoxDecoration(gradient: DifyGradients.chatAnswerHumanInputFormDividerBg),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    }
    final showOps = !responding && !isOpening && _hover;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Padding(
          // `ml-4 pb-4` and the inner `pr-10` (`pr-2!` in the debug panel).
          padding: const EdgeInsets.only(left: 16, bottom: 16, right: 8),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Align(alignment: Alignment.centerLeft, child: bubble),
              if (_feedbackBar(ctx, isOpening) case final bar?) Positioned(top: -14, right: -6, child: bar),
              if (showOps)
                Positioned(
                  right: 8,
                  bottom: -16,
                  child: _ActionBar(
                    children: [
                      if (!contentIsEmpty)
                        DifyIconButton(
                          label: _tc('operation.copy'),
                          icon: const RemixIcon('clipboard-line', size: 16),
                          onPressed: () => _copy(context, content),
                        ),
                      if (!widget.noChatInput)
                        DifyIconButton(
                          label: _tc('operation.regenerate'),
                          icon: const RemixIcon('reset-left-line', size: 16),
                          onPressed: () => ctx?.onRegenerate?.call(item),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestedQuestion extends StatelessWidget {
  const _SuggestedQuestion({required this.question, required this.onTap, this.readonly = false});
  final String question;
  final VoidCallback onTap;
  final bool readonly;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: readonly ? 0.5 : 1,
    child: DifyPressable(
      semanticLabel: question,
      disabled: readonly,
      onPressed: onTap,
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: hovered ? DifyColors.componentsButtonSecondaryBgHover : DifyColors.componentsButtonSecondaryBg,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(
            color: hovered
                ? DifyColors.componentsButtonSecondaryBorderHover
                : DifyColors.componentsButtonSecondaryBorder,
            width: Css.hairline,
          ),
          boxShadow: DifyShadows.xs,
        ),
        child: DifyTextLine(
          question,
          style: difyStyle(DifyType.systemSmMedium, DifyColors.componentsButtonSecondaryAccentText),
        ),
      ),
    ),
  );
}

/// TryToAsk: "TRY TO ASK" between gradient lines over the suggested questions as small secondary-accent buttons.
class TryToAsk extends StatelessWidget {
  const TryToAsk({super.key, required this.suggestedQuestions, required this.onSend});
  final List<String> suggestedQuestions;
  final ChatOnSend onSend;

  @override
  Widget build(BuildContext context) {
    Widget line(bool flip) => Expanded(
      child: Container(
        height: 1,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [DifyRunDividerColors.transparentWhite, DifyColors.dividerRegular],
            begin: flip ? Alignment.centerRight : Alignment.centerLeft,
            end: flip ? Alignment.centerLeft : Alignment.centerRight,
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 8),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10, top: 0),
            child: Row(
              spacing: 8,
              children: [
                line(false),
                DifyText(
                  DifyI18n.tr('app-debug', 'feature.suggestedQuestionsAfterAnswer.tryToAsk'),
                  DifyType.systemXsMediumUppercase,
                  color: DifyColors.textTertiary,
                ),
                line(true),
              ],
            ),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final q in suggestedQuestions)
                DifyButton(
                  size: DifyButtonSize.small,
                  variant: DifyButtonVariant.secondaryAccent,
                  onPressed: () => onSend(q),
                  child: DifyTextLine(q),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// FeatureBar (new-feature-panel/feature-bar.tsx): under the input, "Enable feature to enhance…" when no feature is
/// on, else the enabled features' icons, "Features Enabled" and Manage.
class FeatureBar extends StatelessWidget {
  const FeatureBar({
    super.key,
    required this.features,
    this.disabled = false,
    this.onFeatureBarClick,
    this.isChatMode = true,
    this.showFileUpload = true,
    this.hideEditEntrance = false,
  });

  /// The features store shape (`opening`, `suggested`, `file`, ...).
  final DifyJson features;
  final bool disabled;
  final VoidCallback? onFeatureBarClick;
  final bool isChatMode, showFileUpload, hideEditEntrance;

  @override
  Widget build(BuildContext context) {
    String ta(String key) => DifyI18n.tr('app-debug', key);
    final order = [
      (
        'moreLikeThis',
        'sparkling-fill',
        null,
        DifyColors.utilColorsBlueLightBlueLight500,
        'feature.moreLikeThis.title',
      ),
      (
        'opening',
        null,
        'vender/features/love-message',
        DifyColors.utilColorsBlueLightBlueLight500,
        'feature.conversationOpener.title',
      ),
      ('moderation', null, 'vender/features/content-moderation', DifyColors.textSuccess, 'feature.moderation.title'),
      (
        'speech2text',
        null,
        'vender/features/microphone-01',
        DifyColors.utilColorsVioletViolet600,
        'feature.speechToText.title',
      ),
      (
        'text2speech',
        null,
        'vender/features/text-to-audio',
        DifyColors.utilColorsVioletViolet600,
        'feature.textToSpeech.title',
      ),
      ('file', null, 'vender/features/folder-upload', DifyColors.utilColorsBlueBlue600, 'feature.fileUpload.title'),
      (
        'suggested',
        null,
        'vender/features/virtual-assistant',
        DifyColors.utilColorsBlueLightBlueLight500,
        'feature.suggestedQuestionsAfterAnswer.title',
      ),
      ('citation', null, 'vender/features/citations', DifyColors.utilColorsWarningWarning500, 'feature.citation.title'),
      (
        'annotationReply',
        null,
        'vender/features/message-fast',
        DifyColors.utilColorsIndigoIndigo600,
        'feature.annotation.title',
      ),
    ];
    final enabled = [
      for (final f in order)
        if (featureEnabled(features, f.$1) &&
            (f.$1 != 'file' || showFileUpload) &&
            (!const {'citation', 'annotationReply'}.contains(f.$1) || isChatMode))
          f,
    ];
    return Container(
      transform: Matrix4.translationValues(0, -8, 0),
      margin: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 8),
      decoration: BoxDecoration(
        color: DifyColors.utilColorsIndigoIndigo50,
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
        border: Border(
          left: BorderSide(color: DifyColors.componentsPanelBorderSubtle),
          right: BorderSide(color: DifyColors.componentsPanelBorderSubtle),
          bottom: BorderSide(color: DifyColors.componentsPanelBorderSubtle),
        ),
      ),
      child: enabled.isEmpty
          ? GestureDetector(
              onTap: onFeatureBarClick,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  spacing: 4,
                  children: [
                    RemixIcon('apps-2-add-line', size: 14, color: DifyColors.textAccent),
                    Flexible(
                      child: DifyText(ta('feature.bar.empty'), DifyType.bodyXsMedium, color: DifyColors.textAccent),
                    ),
                    RemixIcon('arrow-right-line', size: 14, color: DifyColors.textAccent),
                  ],
                ),
              ),
            )
          : Row(
              spacing: 8,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 2,
                  children: [
                    for (final f in enabled)
                      DifyTooltip(
                        content: DifyTextLine(ta(f.$5)),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: f.$4,
                            borderRadius: BorderRadius.circular(DifyRadius.lg),
                            border: Border.all(color: DifyColors.dividerSubtle, width: Css.hairline),
                            boxShadow: DifyShadows.xs,
                          ),
                          child: f.$2 != null
                              ? RemixIcon(f.$2!, size: 14, color: DifyColors.textPrimaryOnSurface)
                              : DifyIcon(f.$3!, size: 14, color: DifyColors.textPrimaryOnSurface),
                        ),
                      ),
                  ],
                ),
                Expanded(
                  child: DifyText(ta('feature.bar.enableText'), DifyType.bodyXsRegular, color: DifyColors.textTertiary),
                ),
                if (!hideEditEntrance)
                  DifyButton(
                    size: DifyButtonSize.small,
                    variant: DifyButtonVariant.ghostAccent,
                    onPressed: onFeatureBarClick,
                    trailing: RemixIcon('arrow-right-line', size: 14, color: DifyColors.textAccent),
                    child: DifyTextLine(ta('feature.bar.manage')),
                  ),
              ],
            ),
    );
  }
}

/// ChatInputArea: the rounded composer (`rounded-xl border border-components-chat-input-border
/// bg-components-panel-bg-blur pb-2.25 shadow-md`) — the textarea ("Talk to Bot", Enter sends, Shift+Enter breaks,
/// Cmd+↑/↓ walks the sent history) and the send button — and the feature bar under it.
class ChatInputArea extends StatefulWidget {
  const ChatInputArea({
    super.key,
    this.botName = 'Bot',
    this.disabled = false,
    this.readonly = false,
    this.isResponding = false,
    required this.onSend,
    this.showFeatureBar = false,
    this.features = const {},
    this.featureBarDisabled = false,
    this.onFeatureBarClick,
    this.toast,
  });

  final String botName;
  final bool disabled;
  final bool readonly;
  final bool isResponding;
  final ChatOnSend onSend;
  final bool showFeatureBar;
  final DifyJson features;
  final bool featureBarDisabled;
  final VoidCallback? onFeatureBarClick;
  final void Function(DifyToastType type, String message)? toast;

  @override
  State<ChatInputArea> createState() => _ChatInputAreaState();
}

class _ChatInputAreaState extends State<ChatInputArea> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _history = <String>[];
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final query = _controller.text;
    if (widget.isResponding) {
      (widget.toast ?? difyToast)(DifyToastType.info, DifyI18n.tr('app-debug', 'errorMessage.waitForResponse'));
      return;
    }
    if (query.trim().isEmpty) {
      (widget.toast ?? difyToast)(DifyToastType.info, DifyI18n.tr('app-annotation', 'errorMessage.queryRequired'));
      return;
    }
    final accepted = widget.onSend(query);
    if (accepted != false) _controller.clear();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (e.logicalKey == LogicalKeyboardKey.enter && !keys.isShiftPressed) {
      if (_controller.value.composing.isValid) return KeyEventResult.ignored;
      final q = _controller.text.replaceFirst(RegExp(r'\n$'), '');
      _history.add(q);
      _index = _history.length;
      _send();
      return KeyEventResult.handled;
    }
    if (keys.isMetaPressed && e.logicalKey == LogicalKeyboardKey.arrowUp && _index > 0) {
      _index--;
      _controller.text = _history[_index];
      return KeyEventResult.handled;
    }
    if (keys.isMetaPressed && e.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_index < _history.length - 1) {
        _index++;
        _controller.text = _history[_index];
      } else if (_index == _history.length - 1) {
        _index = _history.length;
        _controller.clear();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = _tc(widget.readonly ? 'chat.inputDisabledPlaceholder' : 'chat.inputPlaceholder', {
      'botName': widget.botName,
    });
    final canSend = _controller.text.trim().isNotEmpty;
    final textStyle = difyStyle(DifyType.bodyLgRegular, DifyColors.textPrimary).copyWith(height: 24 / 14);
    final sendButton = Padding(
      padding: const EdgeInsets.only(left: 12),
      child: SizedBox(
        width: 32,
        child: DifyButton(
          variant: DifyButtonVariant.primary,
          paddingX: 0,
          disabled: widget.readonly || !canSend,
          semanticLabel: _tc('operation.send'),
          onPressed: _send,
          // The button's text colour (disabled: components-button-primary-text-disabled).
          child: const RemixIcon('send-plane-2-fill', size: 16),
        ),
      ),
    );
    final input = Opacity(
      opacity: widget.disabled ? 0.5 : 1,
      child: IgnorePointer(
        ignoring: widget.disabled,
        child: Container(
          padding: const EdgeInsets.only(bottom: 9),
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBgBlur,
            borderRadius: BorderRadius.circular(DifyRadius.xl),
            border: Border.all(
              color: widget.disabled ? DifyColors.componentsPanelBorder : DifyColors.componentsChatInputBorder,
            ),
            boxShadow: widget.disabled ? null : DifyShadows.md,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(9, 9, 9, 0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 158),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Focus(
                      onKeyEvent: _onKey,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: EditableTextHost(
                          controller: _controller,
                          focusNode: _focus,
                          style: textStyle,
                          placeholder: placeholder,
                          readOnly: widget.readonly,
                          enabled: !widget.disabled,
                        ),
                      ),
                    ),
                  ),
                  sendButton,
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // The input (`z-10`) lies over the feature bar's top (`-translate-y-2`): laid out bottom-up, so the bar, first,
    // is painted first.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      verticalDirection: VerticalDirection.up,
      children: [
        if (widget.showFeatureBar)
          FeatureBar(
            features: widget.features,
            disabled: widget.featureBarDisabled,
            onFeatureBarClick: widget.onFeatureBarClick,
          ),
        input,
      ],
    );
  }
}

/// A multi-line EditableText with a placeholder (react-textarea-autosize's growing textarea).
class EditableTextHost extends StatelessWidget {
  const EditableTextHost({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.style,
    required this.placeholder,
    this.readOnly = false,
    this.enabled = true,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle style;
  final String placeholder;
  final bool readOnly;
  final bool enabled;

  @override
  Widget build(BuildContext context) => DifyEditableArea(
    controller: controller,
    focusNode: focusNode,
    style: style,
    placeholder: placeholder,
    enabled: enabled,
    readOnly: readOnly,
  );
}

/// Chat (chat/index.tsx) for the debug panel: [chatNode] (the user inputs, the empty state) and the messages in a
/// scroll view that follows new content, the footer over its bottom (`bg-chat-input-mask`) with "Stop responding",
/// TryToAsk and the input.
class DebugChat extends StatefulWidget {
  const DebugChat({
    super.key,
    required this.chatList,
    this.isResponding = false,
    this.onSend,
    this.onRegenerate,
    this.onStopResponding,
    this.switchSibling,
    this.suggestedQuestions = const [],
    this.config,
    this.chatNode,
    this.emptyNode,
    this.inputDisabled = false,
    this.showFeatureBar = false,
    this.onFeatureBarClick,
    this.noChatInput = false,
    this.toast,
    this.onHumanInputFormSubmit,
    this.getHumanInputNodeData,
    this.pickFile,
  });

  final List<DifyJson> chatList;
  final bool isResponding;
  final ChatOnSend? onSend;
  final void Function(DifyJson item, {String? editedMessage, List<DifyJson>? editedFiles})? onRegenerate;
  final VoidCallback? onStopResponding;
  final ValueChanged<String>? switchSibling;
  final List<String> suggestedQuestions;

  /// The chat config in the server shape (`opening_statement`, `suggested_questions_after_answer`, ...).
  final DifyJson? config;
  final Widget? chatNode;

  /// Shown centred over the panel while there are no messages (debug-and-preview/empty.tsx, `absolute
  /// top-1/2 left-1/2 -translate-1/2`).
  final Widget? emptyNode;
  final bool inputDisabled;
  final bool showFeatureBar;
  final VoidCallback? onFeatureBarClick;
  final bool noChatInput;
  final void Function(DifyToastType type, String message)? toast;
  final HumanInputFormSubmit? onHumanInputFormSubmit;
  final HumanInputNodeData? getHumanInputNodeData;
  final RunFilePicker? pickFile;

  @override
  State<DebugChat> createState() => _DebugChatState();
}

class _DebugChatState extends State<DebugChat> {
  final _scroll = ScrollController();
  double _footerHeight = 0;
  bool _userScrolled = false;

  @override
  void didUpdateWidget(DebugChat old) {
    super.didUpdateWidget(old);
    // use-chat-layout: scroll to the bottom as the conversation grows, unless the user scrolled up.
    if (!_userScrolled || widget.chatList.length != old.chatList.length) {
      if (widget.chatList.length != old.chatList.length) _userScrolled = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.chatList;
    final suggestedEnabled = (widget.config?['suggested_questions_after_answer'] as Map?)?['enabled'] == true;
    final hasTryToAsk = suggestedEnabled && widget.suggestedQuestions.isNotEmpty && widget.onSend != null;
    final features = buildInitialFeatures(widget.config ?? const {});
    return ChatContext(
      onSend: widget.onSend,
      onRegenerate: widget.onRegenerate,
      toast: widget.toast,
      onHumanInputFormSubmit: widget.onHumanInputFormSubmit,
      getHumanInputNodeData: widget.getHumanInputNodeData,
      pickFile: widget.pickFile,
      child: Stack(
        children: [
          if (list.isEmpty && widget.emptyNode != null) Positioned.fill(child: Center(child: widget.emptyNode)),
          NotificationListener<UserScrollNotification>(
            onNotification: (n) {
              _userScrolled = _scroll.position.pixels < _scroll.position.maxScrollExtent - 1;
              return false;
            },
            child: SingleChildScrollView(
              controller: _scroll,
              padding: EdgeInsets.only(left: 12, right: 12, bottom: _footerHeight),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?widget.chatNode,
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, item) in list.indexed)
                          if (item['isAnswer'] == true)
                            ChatAnswer(
                              key: ValueKey('a-${item['id']}'),
                              item: item,
                              responding: i == list.length - 1 && widget.isResponding,
                              switchSibling: widget.switchSibling,
                              noChatInput: widget.noChatInput,
                            )
                          else
                            ChatQuestion(
                              key: ValueKey('q-${item['id']}'),
                              item: item,
                              switchSibling: widget.switchSibling,
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _MeasureHeight(
              onHeight: (h) {
                if (h != _footerHeight) setState(() => _footerHeight = h);
              },
              child: Container(
                decoration: BoxDecoration(
                  gradient: DifyGradients.chatInputMask,
                  borderRadius: BorderRadius.only(bottomLeft: Radius.circular(DifyRadius.xxl)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.isResponding)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Center(
                          child: DifyButton(
                            onPressed: widget.onStopResponding,
                            leading: DifyIcon(
                              'vender/solid/mediaAndDevices/stop-circle',
                              size: 14,
                              color: DifyColors.componentsButtonSecondaryText,
                            ),
                            child: DifyTextLine(
                              DifyI18n.tr('app-debug', 'operation.stopResponding'),
                              style: DifyTw.textXsNormal.style,
                            ),
                          ),
                        ),
                      ),
                    if (hasTryToAsk) TryToAsk(suggestedQuestions: widget.suggestedQuestions, onSend: widget.onSend!),
                    if (!widget.noChatInput)
                      ChatInputArea(
                        disabled: widget.inputDisabled,
                        isResponding: widget.isResponding,
                        onSend: (m, [f]) => widget.onSend?.call(m, f) ?? false,
                        showFeatureBar: widget.showFeatureBar,
                        features: features,
                        featureBarDisabled: widget.isResponding,
                        onFeatureBarClick: widget.onFeatureBarClick,
                        toast: widget.toast,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A negative horizontal margin (`-mx-1`): the child is [margin] wider on each side than the space it is given.
class NegativeMarginX extends SingleChildRenderObjectWidget {
  const NegativeMarginX({super.key, required this.margin, required super.child});
  final double margin;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderNegativeMarginX(margin);

  @override
  void updateRenderObject(BuildContext context, RenderNegativeMarginX renderObject) => renderObject.margin = margin;
}

class RenderNegativeMarginX extends RenderProxyBox {
  RenderNegativeMarginX(this._margin);
  double _margin;
  set margin(double v) {
    if (v == _margin) return;
    _margin = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final c = constraints;
    final w = c.maxWidth.isFinite ? c.maxWidth + _margin * 2 : c.maxWidth;
    child!.layout(c.copyWith(minWidth: c.minWidth + _margin * 2, maxWidth: w), parentUsesSize: true);
    size = c.constrain(Size(child!.size.width - _margin * 2, child!.size.height));
  }

  @override
  void paint(PaintingContext context, Offset offset) => context.paintChild(child!, offset - Offset(_margin, 0));

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => result.addWithPaintOffset(
    offset: Offset(-_margin, 0),
    position: position,
    hitTest: (result, transformed) => child!.hitTest(result, position: transformed),
  );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) => transform.translateByDouble(-_margin, 0, 0, 1);
}

class _MeasureHeight extends StatefulWidget {
  const _MeasureHeight({required this.onHeight, required this.child});
  final ValueChanged<double> onHeight;
  final Widget child;

  @override
  State<_MeasureHeight> createState() => _MeasureHeightState();
}

class _MeasureHeightState extends State<_MeasureHeight> {
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box = context.findRenderObject() as RenderBox?;
      if (mounted && box != null && box.hasSize) widget.onHeight(box.size.height);
    });
    return widget.child;
  }
}

/// operation.tsx's feedback helpers.
abstract final class ChatAnswerFeedback {
  /// operation.tsx `buildFeedbackTooltip`: the label, else "label: Like|Dislike", with " - content" when there is some.
  static String tooltip(Map? feedback, String label) {
    final rating = feedback?['rating'];
    if (rating == null) return label;
    final r = DifyI18n.tr('app-log', rating == 'like' ? 'detail.operation.like' : 'detail.operation.dislike');
    final text = '${feedback?['content'] ?? ''}'.trim();
    return text.isEmpty ? '$label: $r' : '$label: $r - $text';
  }
}

/// operation.tsx's feedback dialog (DialogContent `p-0`): "Provide Feedback" with its subtitle and close button
/// (`p-6 pr-14 pb-3`), the "Feedback Content" textarea (4 rows, `px-6 py-3`), Cancel and Submit (`p-6 pt-5`).
class ChatFeedbackDialog extends StatefulWidget {
  const ChatFeedbackDialog({super.key, required this.onSubmit, required this.onCancel});

  final Future<void> Function(String content) onSubmit;
  final VoidCallback onCancel;

  @override
  State<ChatFeedbackDialog> createState() => _ChatFeedbackDialogState();
}

class _ChatFeedbackDialogState extends State<ChatFeedbackDialog> {
  String _content = '';

  @override
  Widget build(BuildContext context) {
    String c(String key) => DifyI18n.tr('common', key);
    return DifyDialogSurface(
      label: c('feedback.title'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 56, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DifyText(c('feedback.title'), DifyType.title2xlSemiBold, color: DifyColors.textPrimary),
                    const SizedBox(height: 4),
                    DifyText(c('feedback.subtitle'), DifyType.systemXsRegular, color: DifyColors.textTertiary),
                  ],
                ),
              ),
              Positioned(
                top: 20,
                right: 20,
                child: DifyIconButton(
                  key: const ValueKey('chat-feedback-close'),
                  label: c('operation.close'),
                  size: DifyIconButtonSize.lg,
                  icon: const RemixIcon('close-line', size: 16),
                  onPressed: widget.onCancel,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DifyText(c('feedback.content'), DifyType.systemSmSemibold, color: DifyColors.textSecondary),
                ),
                DifyTextarea(
                  key: const ValueKey('chat-feedback-content'),
                  value: _content,
                  minHeight: 96,
                  semanticLabel: c('feedback.content'),
                  placeholder: c('feedback.placeholder'),
                  onChanged: (v) => setState(() => _content = v),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                DifyButton(onPressed: widget.onCancel, child: DifyTextLine(c('operation.cancel'))),
                DifyButton(
                  key: const ValueKey('chat-feedback-submit'),
                  variant: DifyButtonVariant.primary,
                  onPressed: () => widget.onSubmit(_content),
                  child: DifyTextLine(c('operation.submit')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
