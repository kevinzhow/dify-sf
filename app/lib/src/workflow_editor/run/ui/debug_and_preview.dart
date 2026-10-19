/// panel/debug-and-preview: the chatflow's Debug & Preview panel — header (restart, the user input fields toggle,
/// close), the chat (ChatWrapper over DebugChatController), the user inputs card (UserInput), the empty state, and the
/// conversation variables modal.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../design/css_metrics.dart';
import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../design/widgets/widgets.dart';
import '../../../i18n/dify_i18n.dart';
import '../../code_editor/code_editor.dart';
import '../../header/format.dart' as fmt;
import '../../node_panel/resize_handle.dart';
import '../../store/panel_width.dart' show getPreviewPanelMaxWidth;
import '../../store/workflow_store.dart';
import '../../store/workflow_store_scope.dart';
import '../debug_chat.dart';
import '../run_scope.dart';
import '../run_types.dart' show WorkflowRunningStatus;
import 'before_run_form.dart';
import 'chat.dart';
import 'run_widgets.dart' show ExpandedSemantics;
import 'workflow_preview.dart' show RunPanelContext;

String _tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String _tc(String key) => DifyI18n.tr('common', key);

/// Empty: the chat bot icon and "Upload images or type a message…" centred in the panel.
class DebugEmpty extends StatelessWidget {
  const DebugEmpty({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: DifyIcon('vender/line/communication/chat-bot-slim', size: 48, color: DifyTailwind.gray300),
        ),
        SizedBox(
          width: 256,
          child: Text(
            _tw('common.previewPlaceholder'),
            textAlign: TextAlign.center,
            style: difyTextStyle(DifyTw.text13, DifyTailwind.gray400),
          ),
        ),
      ],
    ),
  );
}

/// UserInput: the Start variables as FormItems in a card (`rounded-xl border-[0.5px] bg-components-panel-on-panel-item
/// -bg shadow-xs`, `px-4 pt-3 pb-4`); hidden variables only while the debug panel is open.
class UserInput extends StatelessWidget {
  const UserInput({super.key, required this.variables, this.pickFile});
  final List<DifyJson> variables;
  final RunFilePicker? pickFile;

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([store.inputs, store.showDebugAndPreviewPanel]),
      builder: (context, _) {
        final visible = store.showDebugAndPreviewPanel.value
            ? variables
            : [
                for (final v in variables)
                  if (v['hide'] != true) v,
              ];
        if (visible.isEmpty) return const SizedBox.shrink();
        final inputs = store.inputs.value;
        return Container(
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelOnPanelItemBg,
            borderRadius: BorderRadius.circular(DifyRadius.xl),
            border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: Css.hairline),
            boxShadow: DifyShadows.xs,
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, v) in visible.indexed)
                Padding(
                  key: ValueKey('user-input-${v['variable']}'),
                  padding: EdgeInsets.only(bottom: i == visible.length - 1 ? 0 : 16),
                  child: RunFormItem(
                    autoFocus: i == 0,
                    payload: v,
                    value: inputs['${v['variable']}'],
                    pickFile: pickFile,
                    onChange: (value) => store.setInputs(
                      {...store.inputs.value, '${v['variable']}': ?value}.cast<String, Object>(),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// ChatWrapper: the chat over a [DebugChatController] (made from the editor's run scope unless given), the inputs card
/// and empty state above the messages, the features as the chat config.
class ChatWrapper extends StatefulWidget {
  const ChatWrapper({
    super.key,
    required this.startVariables,
    required this.showInputsFieldsPanel,
    required this.onHide,
    this.controller,
    this.restart,
    this.panel = const RunPanelContext(),
    this.showConversationVariableModal = false,
    this.onConversationModalHide,
  });

  final List<DifyJson> startVariables;

  /// The conversation variables modal over the editor (Dify 1.17.1 never opens it from the panel).
  final bool showConversationVariableModal;
  final VoidCallback? onConversationModalHide;
  final bool showInputsFieldsPanel;
  final VoidCallback onHide;

  /// The conversation; null: one from [WorkflowRunScope.createChat] (disposed with the wrapper).
  final DebugChatController? controller;

  /// Set to the wrapper's restart (DebugAndPreview's `chatRef.current.handleRestart`).
  final ValueNotifier<VoidCallback?>? restart;
  final RunPanelContext panel;

  @override
  State<ChatWrapper> createState() => _ChatWrapperState();
}

class _ChatWrapperState extends State<ChatWrapper> {
  late final WorkflowStore store = WorkflowStoreScope.of(context);
  DebugChatController? _own;
  late DebugChatController chat = widget.controller ?? (_own = _create());

  DebugChatController _create() =>
      WorkflowRunScope.of(context).createChat(config: _config(), formSettings: _formSettings());

  Map<String, Object?> get _initialInputs => {
    for (final v in widget.startVariables)
      if (v['default'] != null && v['default'] != '' && v['default'] != false && v['default'] != 0)
        '${v['variable']}': v['default'],
  };

  /// The chat config from the features (server shape, as useChat reads it).
  DifyJson _config() {
    final f = store.features.value;
    return {
      'opening_statement': f['opening_statement'] ?? '',
      'suggested_questions': f['suggested_questions'] ?? const [],
      'suggested_questions_after_answer': f['suggested_questions_after_answer'],
      'text_to_speech': f['text_to_speech'],
      'speech_to_text': f['speech_to_text'],
      'retriever_resource': f['retriever_resource'],
      'sensitive_word_avoidance': f['sensitive_word_avoidance'],
      'file_upload': f['file_upload'],
    };
  }

  ChatFormSettings _formSettings() => (inputs: store.inputs.value, inputsForm: widget.startVariables);

  @override
  void initState() {
    super.initState();
    widget.restart?.value = _handleRestart;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      chat.addListener(_chatChanged);
      store.workflowRunningData.addListener(_runChanged);
      store.features.addListener(_configChanged);
      store.inputs.addListener(_configChanged);
      final init = _initialInputs;
      if (init.isNotEmpty) store.setInputs({...init, ...store.inputs.value}.cast<String, Object>());
    });
  }

  @override
  void dispose() {
    chat.removeListener(_chatChanged);
    store.workflowRunningData.removeListener(_runChanged);
    store.features.removeListener(_configChanged);
    store.inputs.removeListener(_configChanged);
    _own?.dispose();
    super.dispose();
  }

  bool _wasResponding = false;

  void _chatChanged() {
    if (chat.isResponding && !_wasResponding) widget.onHide();
    _wasResponding = chat.isResponding;
  }

  /// EVENT_WORKFLOW_STOP (the variable inspect panel's Stop) stops the run: the answer stops responding too.
  void _runChanged() {
    final result = store.workflowRunningData.value?['result'];
    if (chat.isResponding && result is Map && result['status'] == WorkflowRunningStatus.stopped) chat.handleStop();
  }

  void _configChanged() {
    chat
      ..config = _config()
      ..formSettings = _formSettings();
  }

  void _handleRestart() {
    chat.handleRestart();
    store.setInputs(_initialInputs.cast<String, Object>());
  }

  bool _doSend(String message, [List<DifyJson>? files, bool isRegenerate = false, DifyJson? parentAnswer]) {
    final list = chat.chatList;
    final lastAnswer = list.lastWhere(
      (i) => i['isAnswer'] == true && i['isOpeningStatement'] != true,
      orElse: () => const {},
    );
    return chat.handleSend({
      'query': message,
      'files': files ?? const [],
      'inputs': store.inputs.value,
      'conversation_id': chat.conversationId,
      'parent_message_id': isRegenerate ? (parentAnswer == null ? null : parentAnswer['id']) : lastAnswer['id'],
    }, onGetSuggestedQuestions: chat.defaultSuggestedQuestions);
  }

  void _doRegenerate(DifyJson item, {String? editedMessage, List<DifyJson>? editedFiles}) {
    final list = chat.chatList;
    final question = editedMessage != null ? item : list.firstWhere((i) => i['id'] == item['parentMessageId']);
    final parentAnswer = list.where((i) => i['id'] == question['parentMessageId']).firstOrNull;
    final valid =
        parentAnswer != null && parentAnswer['isAnswer'] == true && parentAnswer['isOpeningStatement'] != true;
    _doSend(
      editedMessage ?? '${question['content'] ?? ''}',
      editedMessage != null ? editedFiles : (question['message_files'] as List?)?.cast<DifyJson>(),
      true,
      valid ? parentAnswer : null,
    );
  }

  final _modal = OverlayPortalController();

  @override
  Widget build(BuildContext context) {
    final chatView = _chat(context);
    if (!widget.showConversationVariableModal) return chatView;
    _modal.show();
    return OverlayPortal(
      controller: _modal,
      overlayChildBuilder: (context) => ColoredBox(
        color: DifyColors.backgroundOverlay,
        child: Center(
          child: ConversationVariableModal(
            conversationId: chat.conversationId,
            varList: store.conversationVariables.value,
            onHide: () => widget.onConversationModalHide?.call(),
          ),
        ),
      ),
      child: chatView,
    );
  }

  Widget _chat(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([chat, store.features]),
    builder: (context, _) {
      final list = chat.chatList;
      final latest = list.lastOrNull;
      final inputDisabled =
          latest?['isAnswer'] == true &&
          (latest?['workflowProcess'] as Map?)?['status'] == WorkflowRunningStatus.paused;
      return DebugChat(
        chatList: list,
        isResponding: chat.isResponding,
        config: chat.config ?? _config(),
        suggestedQuestions: chat.suggestedQuestions,
        onSend: (m, [f]) => _doSend(m, f),
        onRegenerate: _doRegenerate,
        onStopResponding: chat.handleStop,
        switchSibling: (id) => chat.handleSwitchSibling(id, onGetSuggestedQuestions: chat.defaultSuggestedQuestions),
        inputDisabled: inputDisabled,
        showFeatureBar: true,
        onFeatureBarClick: () => store.setShowFeaturesPanel(true),
        toast: widget.panel.toast,
        // chat-wrapper.tsx doHumanInputFormSubmit / getHumanInputNodeData.
        onHumanInputFormSubmit: chat.handleSubmitHumanInputForm,
        getHumanInputNodeData: (id) => chat.getHumanInputNodeData(id)?.data,
        pickFile: widget.panel.pickFile,
        emptyNode: const DebugEmpty(),
        chatNode: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showInputsFieldsPanel)
              UserInput(variables: widget.startVariables, pickFile: widget.panel.pickFile),
          ],
        ),
      );
    },
  );
}

/// DebugAndPreview: "DEBUG AND PREVIEW", restart (clears the run marks and the conversation), the user input fields
/// toggle (with the card's caret) when the Start node has variables, close; the chat below; resizable from its left
/// edge between 400 px and what the canvas leaves (720 before it is measured).
class DebugAndPreview extends StatefulWidget {
  const DebugAndPreview({super.key, this.panel = const RunPanelContext(), this.controller});
  final RunPanelContext panel;
  final DebugChatController? controller;

  @override
  State<DebugAndPreview> createState() => _DebugAndPreviewState();
}

class _DebugAndPreviewState extends State<DebugAndPreview> {
  late final WorkflowStore store = WorkflowStoreScope.of(context);
  bool _expanded = true;
  final _restart = ValueNotifier<VoidCallback?>(null);
  double _dragFrom = 0;

  @override
  void dispose() {
    _restart.dispose();
    super.dispose();
  }

  void _restartChat() {
    // handleNodeCancelRunningStatus / handleEdgeCancelRunningStatus.
    store
      ..nodeRunData.value = const {}
      ..edgeRunData.value = const {};
    _restart.value?.call();
  }

  void _close() {
    final cancel = widget.panel.onCancel ?? WorkflowRunScope.maybeOf(context)?.run.handleCancelDebugAndPreviewPanel;
    if (cancel != null) {
      cancel();
    } else {
      store
        ..setShowDebugAndPreviewPanel(false)
        ..workflowRunningData.value = null;
    }
  }

  void _resize(double width) {
    WorkflowStoreScope.preferencesOf(context)?.debugPreviewPanelWidth.value = width;
    store.setPreviewPanelWidth(width);
  }

  @override
  Widget build(BuildContext context) {
    final variables = widget.panel.startVariables;
    final userInputLabel = _tw('panel.userInputField');
    return ListenableBuilder(
      listenable: Listenable.merge([store.previewPanelWidth, store.workflowCanvasWidth]),
      builder: (context, _) {
        final width = store.previewPanelWidth.value;
        final max = getPreviewPanelMaxWidth(store.workflowCanvasWidth.value, widget.panel.hasSelectedNode, 720);
        return SizedBox(
          width: width + 4,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 4,
                child: ResizeHandle(
                  value: width,
                  min: 400,
                  max: max,
                  label: _tw('common.debugAndPreview'),
                  onResize: _resize,
                  onDragStart: () => _dragFrom = width,
                  onDrag: (dx) => store.setPreviewPanelWidth((_dragFrom - dx).clamp(400, max < 400 ? 400 : max)),
                  onDragEnd: () => _resize(store.previewPanelWidth.value),
                ),
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: DifyGradients.chatbotBg,
                    borderRadius: const BorderRadius.horizontal(left: Radius.circular(DifyRadius.xxl)),
                    border: Border(
                      left: BorderSide(color: DifyColors.componentsPanelBorder),
                      top: BorderSide(color: DifyColors.componentsPanelBorder),
                      bottom: BorderSide(color: DifyColors.componentsPanelBorder),
                    ),
                    boxShadow: DifyShadows.xl,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 32,
                                child: Text(
                                  _tw('common.debugAndPreview').toUpperCase(),
                                  style: difyStyle(DifyType.systemXlSemibold, DifyColors.textPrimary),
                                ),
                              ),
                            ),
                            Row(
                              spacing: 4,
                              children: [
                                DifyTooltip(
                                  content: Text(_tc('operation.refresh')),
                                  child: DifyIconButton(
                                    label: _tc('operation.refresh'),
                                    icon: const DifyIcon('vender/line/arrows/refresh-ccw-01', size: 16),
                                    onPressed: _restartChat,
                                  ),
                                ),
                                if (variables.isNotEmpty)
                                  Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      DifyTooltip(
                                        content: Text(userInputLabel),
                                        child: ExpandedSemantics(
                                          expanded: _expanded,
                                          child: DifyPressable(
                                            semanticLabel: userInputLabel,
                                            onPressed: () => setState(() => _expanded = !_expanded),
                                            builder: (context, hovered, focused) => Container(
                                              width: 24,
                                              height: 24,
                                              alignment: Alignment.center,
                                              decoration: BoxDecoration(
                                                color: _expanded
                                                    ? (hovered
                                                          ? DifyColors.stateAccentActiveAlt
                                                          : DifyColors.stateAccentActive)
                                                    : (hovered ? DifyColors.stateBaseHover : null),
                                                borderRadius: BorderRadius.circular(DifyRadius.md),
                                              ),
                                              child: RemixIcon(
                                                'equalizer-2-line',
                                                size: 16,
                                                color: _expanded ? DifyColors.textAccent : DifyColors.textTertiary,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      if (_expanded)
                                        Positioned(
                                          right: 5,
                                          bottom: -17,
                                          child: Transform.rotate(
                                            angle: 0.785398,
                                            child: Container(
                                              width: 12,
                                              height: 12,
                                              decoration: BoxDecoration(
                                                color: DifyColors.componentsPanelOnPanelItemBg,
                                                border: Border(
                                                  top: BorderSide(
                                                    color: DifyColors.componentsPanelBorderSubtle,
                                                    width: Css.hairline,
                                                  ),
                                                  left: BorderSide(
                                                    color: DifyColors.componentsPanelBorderSubtle,
                                                    width: Css.hairline,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                Container(
                                  width: 1,
                                  height: 14,
                                  margin: const EdgeInsets.symmetric(horizontal: 12),
                                  color: DifyColors.dividerRegular,
                                ),
                                DifyIconButton(
                                  label: _tc('operation.close'),
                                  icon: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
                                  onPressed: _close,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(DifyRadius.xxl)),
                          child: ChatWrapper(
                            startVariables: variables,
                            showInputsFieldsPanel: _expanded,
                            onHide: () {
                              if (mounted) setState(() => _expanded = false);
                            },
                            controller: widget.controller,
                            restart: _restart,
                            panel: widget.panel,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// ConversationVariableModal: the conversation variables on the left, the selected one's latest stored value (and
/// when it was updated) on the right — JSON in a read-only editor with copy, numbers and strings as text.
class ConversationVariableModal extends StatefulWidget {
  const ConversationVariableModal({
    super.key,
    required this.conversationId,
    required this.onHide,
    required this.varList,
    this.fetchValues,
    this.formatTime,
  });

  final String conversationId;
  final VoidCallback onHide;

  /// The store's `conversationVariables` (ConversationVariable JSON: `id`, `name`, `value_type`, `value`).
  final List<DifyJson> varList;

  /// `fetchCurrentValueOfConversationVariable`: `[{id, value, updated_at}]`.
  final Future<List<DifyJson>> Function(String conversationId)? fetchValues;
  final String Function(int seconds, String format)? formatTime;

  @override
  State<ConversationVariableModal> createState() => _ConversationVariableModalState();
}

class _ConversationVariableModalState extends State<ConversationVariableModal> {
  late DifyJson _current = widget.varList.firstOrNull ?? const {};
  var _values = <String, Object?>{};
  var _timestamps = <String, int>{};
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    final fetch = widget.fetchValues ?? WorkflowRunScope.maybeOf(context)?.service.fetchConversationVariables;
    if (widget.conversationId.isNotEmpty && widget.varList.isNotEmpty && fetch != null) {
      fetch(widget.conversationId).then((data) {
        if (!mounted || data.isEmpty) return;
        setState(() {
          _values = {for (final d in data) '${d['id']}': d['value']};
          _timestamps = {
            for (final d in data)
              if (d['updated_at'] is num) '${d['id']}': (d['updated_at'] as num).toInt(),
          };
        });
      }, onError: (Object _) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = _current;
    final id = '${cur['id']}';
    final type = '${cur['value_type'] ?? ''}';
    final value = _values[id];
    final ts = _timestamps[id];
    final isText = type == 'number' || type == 'string';
    return Container(
      width: 920,
      height: 640,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.xxl),
        boxShadow: DifyShadows.xl,
      ),
      child: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 224,
                decoration: BoxDecoration(
                  color: DifyColors.backgroundSidenavBg,
                  border: Border(right: BorderSide(color: DifyColors.dividerBurn)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 16, 12),
                      child: DifyText(_tw('chatVariable.panelTitle'), DifyType.systemXlSemibold),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        children: [
                          for (final v in widget.varList)
                            DifyPressable(
                              semanticLabel: '${v['name']}',
                              onPressed: () => setState(() => _current = v),
                              builder: (context, hovered, focused) {
                                final active = v['id'] == cur['id'] || hovered;
                                final color = active ? DifyColors.utilColorsTealTeal700 : DifyColors.textTertiary;
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 2),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: v['id'] == cur['id'] || hovered ? DifyColors.stateBaseHover : null,
                                    borderRadius: BorderRadius.circular(DifyRadius.lg),
                                  ),
                                  child: Row(
                                    children: [
                                      Padding(
                                        padding: const EdgeInsets.only(right: 4),
                                        child: DifyIcon('vender/line/others/bubble-x', size: 16, color: color),
                                      ),
                                      Expanded(child: DifyText('${v['name']}', DifyType.systemSmMedium, color: color)),
                                    ],
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                      child: Row(
                        spacing: 4,
                        children: [
                          DifyText('${cur['name']}', DifyType.systemXlSemibold),
                          DifyText(
                            type.isEmpty ? '' : type[0].toUpperCase() + type.substring(1),
                            DifyType.systemXsMedium,
                            color: DifyColors.textTertiary,
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                spacing: 8,
                                children: [
                                  DifyText(
                                    _tw('chatVariable.storedContent').toUpperCase(),
                                    DifyType.systemXsMediumUppercase,
                                    color: DifyColors.textTertiary,
                                  ),
                                  Expanded(
                                    child: Container(
                                      height: 1,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [DifyRunDividerColors.start, DifyTailwind.white],
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (ts != null && ts != 0)
                                    Flexible(
                                      child: DifyText(
                                        _tw('chatVariable.updatedAt') +
                                            (widget.formatTime ?? fmt.formatTime)(
                                              ts,
                                              DifyI18n.tr('app-log', 'dateTimeFormat'),
                                            ),
                                        DifyType.systemXsRegular,
                                        color: DifyColors.textTertiary,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: isText
                                  ? Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                      decoration: BoxDecoration(
                                        color: DifyColors.componentsInputBgNormal,
                                        borderRadius: BorderRadius.circular(DifyRadius.lg),
                                      ),
                                      child: SingleChildScrollView(
                                        child: DifyText(
                                          '${value ?? ''}',
                                          DifyType.systemMdRegular,
                                          color: DifyColors.componentsInputTextFilled,
                                          maxLines: null,
                                        ),
                                      ),
                                    )
                                  : Container(
                                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                                      decoration: BoxDecoration(
                                        color: DifyColors.componentsInputBgNormal,
                                        borderRadius: BorderRadius.circular(DifyRadius.lg),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: [
                                          SizedBox(
                                            height: 28,
                                            child: Padding(
                                              padding: const EdgeInsets.fromLTRB(12, 4, 8, 0),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: DifyText(
                                                      'JSON',
                                                      DifyType.systemXsSemibold,
                                                      color: DifyColors.textSecondary,
                                                    ),
                                                  ),
                                                  DifyPressable(
                                                    semanticLabel: _tc('operation.copy'),
                                                    onPressed: () {
                                                      Clipboard.setData(ClipboardData(text: '${cur['value'] ?? ''}'));
                                                      setState(() => _copied = true);
                                                      Future.delayed(const Duration(seconds: 2), () {
                                                        if (mounted) setState(() => _copied = false);
                                                      });
                                                    },
                                                    builder: (context, h, f) => Padding(
                                                      padding: const EdgeInsets.all(4),
                                                      child: DifyIcon(
                                                        _copied
                                                            ? 'vender/line/files/copy-check'
                                                            : 'vender/line/files/copy',
                                                        size: 16,
                                                        color: DifyColors.textTertiary,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: Padding(
                                              padding: const EdgeInsets.only(left: 16),
                                              child: DifyCodeEditor(
                                                readOnly: true,
                                                noWrapper: true,
                                                isExpand: true,
                                                language: CodeLanguage.json,
                                                value: value ?? '',
                                                isJSONStringifyBeauty: true,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            top: 16,
            right: 16,
            child: DifyPressable(
              semanticLabel: _tc('operation.close'),
              onPressed: widget.onHide,
              builder: (context, h, f) => Padding(
                padding: EdgeInsets.all(8),
                child: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
