/// Published app shell. Reuses the existing typed run inputs, Markdown, output,
/// file picker and human-input form; its transport never uses console auth.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../design/dify_tokens.g.dart';
import '../design/dify_icon.dart';
import 'public_inputs.dart';
import '../design/widgets/widgets.dart';
import '../files/upload_service.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/run/ui/before_run_form.dart';
import '../workflow_editor/run/run_events.dart' show RunServiceException;
import '../workflow_editor/run/ui/human_input_content.dart';
import '../workflow_editor/run/ui/markdown.dart';
import '../workflow_editor/run/ui/run_widgets.dart';

typedef PublicJson = Map<String, Object?>;
PublicJson _map(Object? value) => value is Map ? value.cast<String, Object?>() : {};
List<PublicJson> _files(Object? value) => [
  for (final item in value is List ? value : const [])
    if (item is Map) _map(item),
];
String _share(String key) => DifyI18n.tr('share', key);

class PublicAppPage extends StatefulWidget {
  const PublicAppPage({
    super.key,
    required this.code,
    required this.server,
    this.apiFor,
    this.parameters = const {},
  });
  final String code;
  final Map<String, String> parameters;
  final Uri server;
  final HttpPublicAppApi Function(Uri, String, String?)? apiFor;
  @override
  State<PublicAppPage> createState() => _PublicAppPageState();
}

class _PublicAppPageState extends State<PublicAppPage> {
  HttpPublicAppApi? _api;
  SharedPreferences? _prefs;
  PublicJson? _definition;
  PublicJson _inputs = {}, _result = {};
  List<PublicJson> _forms = [], _history = [], _chatFiles = [];
  String _query = '', _answer = '', _question = '';
  String? _runId, _conversationId, _parentMessageId, _turnParentMessageId, _error;
  bool _busy = false, _terminal = false, _loading = true;
  bool _followDenied = false, _loadFailed = false;
  int _generation = 0, _retry = 0;
  StreamSubscription<PublicJson>? _subscription;
  Timer? _reconnect;
  String get _key => 'public-app:${widget.server}:${widget.code}';
  bool get _chat => _definition?['mode'] == 'advanced-chat';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _reconnect?.cancel();
    unawaited(_subscription?.cancel());
    _api?.close();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _loadFailed = false;
      _followDenied = false;
    });
    try {
      _generation++;
      _reconnect?.cancel();
      await _subscription?.cancel();
      _subscription = null;
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final previousPassport = prefs.getString('$_key:passport');
      final api =
          widget.apiFor?.call(
            widget.server,
            widget.code,
            prefs.getString('$_key:passport'),
          ) ??
          HttpPublicAppApi(
            widget.server,
            code: widget.code,
            passport: prefs.getString('$_key:passport'),
          );
      _api?.close();
      _api = api;
      _prefs = prefs;
      final passport = await api.establishPassport();
      await prefs.setString('$_key:passport', passport);
      if (previousPassport != null && previousPassport != passport) {
        await prefs.remove('$_key:conversation');
        await prefs.remove('$_key:run');
        if (!mounted) return;
        setState(() {
          _runId = null;
          _conversationId = null;
          _parentMessageId = null;
          _turnParentMessageId = null;
          _history = [];
          _chatFiles = [];
          _forms = [];
          _result = {};
          _question = '';
          _answer = '';
          _query = '';
          _busy = false;
          _terminal = false;
        });
      }
      final definition = await api.definition();
      if (!mounted) return;
      setState(() {
        _definition = definition;
        _inputs = {
          for (final field in _fields)
            if (field.containsKey('default')) '${field['variable']}': field['default'],
        };
        _inputs.addAll(publicInputsFromQuery(_fields, widget.parameters));
      });
      _conversationId = prefs.getString('$_key:conversation');
      _history = [];
      _chatFiles = [];
      _parentMessageId = null;
      _turnParentMessageId = null;
      if (_chat && _conversationId != null) {
        _history = (await api.publicMessages(_conversationId!)).reversed.toList();
        if (_history.isNotEmpty) _inputs = _map(_history.last['inputs']);
        _parentMessageId = _history.lastOrNull?['id'] as String?;
      }
      final previous = prefs.getString('$_key:run');
      if (previous != null) {
        final run = await api.publishedRun(previous);
        if (!mounted) return;
        _runId = previous;
        _terminal = !{'running', 'paused'}.contains(run['status']);
        setState(() {
          _busy = !_terminal;
          _result = run;
          if (_chat && _history.isNotEmpty && _history.last['workflow_run_id'] == previous) {
            _turnParentMessageId = _history.last['parent_message_id'] as String?;
          }
          if (_chat && {'failed', 'stopped'}.contains(run['status'])) {
            _error = run['error'] as String? ?? DifyI18n.tr('common', 'errorMsg.serverError');
            if (_history.isNotEmpty && _history.last['workflow_run_id'] == previous) {
              _query = '${_history.last['query'] ?? ''}';
              _parentMessageId = _history.last['parent_message_id'] as String?;
            }
          }
          if (_chat && !_terminal && _history.isNotEmpty && _history.last['workflow_run_id'] == previous) {
            final active = _history.removeLast();
            _question = '${active['query'] ?? ''}';
            _answer = '${active['answer'] ?? ''}';
            _chatFiles = _files(active['files']);
          }
        });
        if (!_terminal) _follow();
      }
      if (mounted) setState(() => _loading = false);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
          _error = _message(error);
        });
      }
    }
  }

  String _message(Object error) => error is TransportException ? error.message : '$error';
  List<PublicJson> get _fields => [
    for (final entry in (_map(_definition?['parameters'])['user_input_form'] as List? ?? []))
      for (final item in _map(entry).entries) {..._map(item.value), 'type': item.key},
  ];
  RunFormProps get _form => RunFormProps(
    inputs: _fields,
    values: _inputs,
    onChange: (v) => setState(() => _inputs = v),
  );

  Future<void> _start() async {
    final api = _api;
    if (api == null || _busy || _loading || _loadFailed || _followDenied) return;
    final error = getFormErrorMessage([_form], const []);
    if (error.isNotEmpty || (_chat && _query.trim().isEmpty)) {
      setState(
        () => _error = error.isNotEmpty
            ? error
            : DifyI18n.tr('common', 'errorMsg.fieldRequired', {
                'field': 'Query',
              }),
      );
      return;
    }
    _generation++;
    _reconnect?.cancel();
    await _subscription?.cancel();
    if (!mounted) return;
    setState(() {
      _busy = true;
      _terminal = false;
      _error = null;
      _runId = null;
      _forms = [];
      _result = {};
      _answer = '';
      _chatFiles = [];
      _question = _chat ? _query : '';
      _turnParentMessageId = _parentMessageId;
    });
    _retry = 0;
    _followDenied = false;
    try {
      final body = <String, Object?>{
        'inputs': getProcessedInputs(_inputs, _fields),
        if (_chat) 'query': _query,
        if (_conversationId != null) 'conversation_id': _conversationId,
        if (_parentMessageId != null) 'parent_message_id': _parentMessageId,
      };
      _listen(api.runPublished(body, chat: _chat));
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _message(error);
        });
      }
    }
  }

  void _listen(Stream<PublicJson> stream) {
    final generation = _generation;
    _subscription = stream.listen(
      (frame) {
        if (!mounted || generation != _generation) return;
        _retry = 0;
        final data = _map(frame['data']);
        final event = frame['event'];
        final id = frame['workflow_run_id'] as String? ?? (event == 'workflow_started' ? data['id'] as String? : null);
        if (id != null && id.isNotEmpty) {
          _runId = id;
          unawaited(_prefs?.setString('$_key:run', id));
        }
        final conversation = frame['conversation_id'] as String?;
        if (conversation != null && conversation.isNotEmpty) {
          _conversationId = conversation;
          unawaited(_prefs?.setString('$_key:conversation', conversation));
        }
        final message = frame['message_id'] as String?;
        if (message != null && !(_terminal && const {'failed', 'stopped'}.contains(_result['status']))) {
          _parentMessageId = message;
        }
        setState(() {
          // message_end follows workflow_finished, including a failed run. Its
          // final files/metadata must not erase the error or select the failed parent.
          if (!_terminal || event == 'workflow_started') _error = null;
          if (event == 'workflow_started' && _chat) _query = '';
          if (event == 'message') _answer += frame['answer'] as String? ?? '';
          if (event == 'message_replace') {
            _answer = frame['answer'] as String? ?? '';
            _chatFiles = _files(frame['files']);
          }
          if (event == 'message_end') _chatFiles = _files(frame['files']);
          if (event == 'node_finished' && data['node_type'] == 'answer') {
            for (final file in _files(_map(data['outputs'])['files'])) {
              if (!_chatFiles.any((saved) => saved['related_id'] == file['related_id'])) _chatFiles.add(file);
            }
          }
          if (event == 'human_input_required' && data['display_in_ui'] == true) {
            final token = data['form_token'];
            _forms = [..._forms.where((f) => f['form_token'] != token), data];
          }
          if (event == 'workflow_paused') {
            _result = data;
            _busy = true;
          }
          if (event == 'human_input_form_filled' || event == 'human_input_form_timeout') {
            _forms = _forms.where((f) => f['node_id'] != data['node_id']).toList();
          }
          if (event == 'workflow_finished') {
            _result = data;
            _terminal = true;
            _busy = false;
            _forms = [];
            if (_chat && {'failed', 'stopped'}.contains(data['status'])) {
              _error = data['error'] as String? ?? DifyI18n.tr('common', 'errorMsg.serverError');
              _query = _question;
              _parentMessageId = _turnParentMessageId;
            }
          }
        });
      },
      onError: (Object error) {
        if (!mounted || generation != _generation) return;
        setState(() => _error = _message(error));
        if (error is TransportException && const [401, 403, 404].contains(error.statusCode)) {
          _followDenied = true;
          _loadFailed = true;
        }
        if (_runId == null || _followDenied) setState(() => _busy = false);
      },
      onDone: () {
        if (!mounted || generation != _generation) return;
        _subscription = null;
        if (!_terminal && !_followDenied && _runId != null) _scheduleFollow();
        if (_terminal && _chat && _conversationId != null) {
          unawaited(_refreshHistory());
        }
      },
    );
  }

  Future<void> _refreshHistory() async {
    final generation = _generation, conversation = _conversationId;
    try {
      final history = await _api!.publicMessages(conversation!);
      if (mounted && generation == _generation && conversation == _conversationId && _terminal) {
        setState(() {
          _history = history.reversed.toList();
          _answer = '';
          _chatFiles = [];
          _question = '';
        });
      }
    } on Object catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = _message(error);
          _loadFailed = true;
        });
      }
    }
  }

  void _scheduleFollow() {
    _reconnect?.cancel();
    final delay = Duration(
      milliseconds: (500 * (1 << _retry.clamp(0, 4))).clamp(500, 5000),
    );
    _retry++;
    _reconnect = Timer(delay, () => _follow());
  }

  void _follow() {
    final id = _runId;
    if (id == null || !mounted || _terminal) return;
    _listen(
      _api!.workflowEvents(
        id,
        includeStateSnapshot: true,
        continueOnPause: true,
      ),
    );
  }

  Future<void> _submit(String token, PublicJson data) async {
    try {
      await _api!.submitHumanInputForm(token, data);
    } on TransportException catch (e) {
      throw RunServiceException(e.message, code: e.code);
    }
  }

  Future<void> _stop() async {
    if (_runId == null) return;
    try {
      await _api!.stopPublished(_runId!, chat: _chat);
    } on Object catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  Future<void> _newChat() async {
    if (_busy || _loading || _loadFailed || _followDenied) return;
    setState(() => _loading = true);
    _generation++;
    await _subscription?.cancel();
    _reconnect?.cancel();
    await _prefs?.remove('$_key:conversation');
    await _prefs?.remove('$_key:run');
    if (mounted) {
      setState(() {
        _loading = false;
        _error = null;
        _loadFailed = false;
        _followDenied = false;
        _query = '';
        _question = '';
        _conversationId = null;
        _runId = null;
        _parentMessageId = null;
        _turnParentMessageId = null;
        _history = [];
        _chatFiles = [];
        _answer = '';
        _forms = [];
        _result = {};
        _terminal = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    final picker = api == null ? null : runtimeFilePickerWithApi(context, () => api);
    final title = '${_definition?['title'] ?? _definition?['name'] ?? ''}';
    final site = _map(_definition?['site']);
    final description = '${site['description'] ?? _definition?['description'] ?? ''}';
    final customPlaceholder = site['input_placeholder'] as String?;
    final unavailable = _busy || _loading || _loadFailed || _followDenied;
    Widget icon(DifyAppIconSize size) => DifyAppIcon(
      size: size,
      iconType: site['icon_type'] as String?,
      icon: site['icon'] as String?,
      background: site['icon_background'] as String?,
      imageUrl: site['icon_url'] as String?,
    );
    final header = Row(
      spacing: 12,
      children: [
        icon(DifyAppIconSize.large),
        Expanded(
          child: DifyTextLine(
            title,
            style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    final form = RunForm(
      props: RunFormProps(
        inputs: _fields.where((f) => f['hide'] != true).toList(),
        values: _inputs,
        onChange: (v) => setState(() => _inputs = v),
      ),
      pickFile: picker,
    );
    final errors = <Widget>[
      if (_error != null) ...[
        DifyTextLine(
          _error!,
          key: const Key('public-app-error'),
          maxLines: null,
          style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textDestructive),
        ),
        if (!_busy)
          DifyButton(
            onPressed: () => unawaited(_definition == null || _loadFailed || _followDenied ? _load() : _start()),
            child: DifyTextLine(DifyI18n.tr('common', 'operation.retry')),
          ),
      ],
    ];
    final humanForms = <Widget>[
      for (final form in _forms)
        HumanInputForm(
          key: ValueKey(form['form_token']),
          formData: form,
          onSubmit: _submit,
          pickFile: picker,
          requireParagraph: true,
        ),
    ];
    if (_definition == null) {
      return DifyPage(
        body: Center(
          child: _loading ? const DifyLoading() : Column(mainAxisSize: MainAxisSize.min, children: errors),
        ),
      );
    }
    final footer = DifyBrandingFooter(alignment: _chat ? MainAxisAlignment.end : MainAxisAlignment.start);
    if (!_chat) {
      final hasResult = _result.isNotEmpty || _busy;
      return DifyPage(
        backgroundColor: DifyColors.backgroundDefaultBurn,
        body: DifyPublicWorkflowLayout(
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 16,
            children: [
              header,
              if (description.isNotEmpty) DifyMarkdown(content: description),
            ],
          ),
          tabs: DifyTabsList(
            children: [
              // Text-generation sidebar wraps the label in ml-2 (Dify 1.17.1).
              DifyTab(
                label: _share('generation.tabs.create'),
                padding: const EdgeInsets.fromLTRB(8, 10, 0, 8),
                active: true,
                onPressed: () {},
              ),
            ],
          ),
          inputs: Padding(
            // Upstream puts mt-4 on actual fields, not on an empty form.
            padding: EdgeInsets.only(top: _fields.any((f) => f['hide'] != true) || errors.isNotEmpty ? 16 : 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 16, children: [...errors, form]),
          ),
          actions: DifyJustifiedRow(
            children: [
              DifyButton(
                disabled: unavailable,
                onPressed: () => setState(() {
                  _error = null;
                  _inputs = {
                    for (final field in _fields)
                      '${field['variable']}': switch (field['type']) {
                        'checkbox' => false,
                        'file-list' => <Object?>[],
                        _ => '',
                      },
                  };
                }),
                child: DifyTextLine(DifyI18n.tr('common', 'operation.clear')),
              ),
              DifyButton(
                onPressed: () => unawaited(_busy ? _stop() : _start()),
                disabled: _loading || _loadFailed || _followDenied,
                variant: DifyButtonVariant.primary,
                leading: RemixIcon(_busy ? 'stop-circle-fill' : 'play-large-line', size: 16),
                child: DifyTextLine(_share(_busy ? 'generation.stopRun' : 'generation.run')),
              ),
            ],
          ),
          hasResult: hasResult,
          result: hasResult
              ? LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 16,
                      children: [
                        ...humanForms,
                        OutputPanel(
                          height: constraints.maxHeight,
                          outputs: _result['outputs'],
                          error: _result['error'] as String?,
                          isRunning: _busy && _forms.isEmpty,
                        ),
                      ],
                    ),
                  ),
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 8,
                    children: [
                      RemixIcon('sparkling-fill', size: 48, color: DifyColors.textEmptyStateIcon),
                      DifyTextLine(
                        _share('generation.noData'),
                        maxLines: null,
                        style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textQuaternary),
                      ),
                    ],
                  ),
                ),
          footer: footer,
        ),
      );
    }
    final opening = '${_map(_definition?['parameters'])['opening_statement'] ?? ''}';
    final empty = _history.isEmpty && _question.isEmpty && _answer.isEmpty;
    final chat = SingleChildScrollView(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 768),
          child: Padding(
            // The welcome node precedes the message container (whose pt-6
            // applies only to messages) in the original Chat component.
            padding: EdgeInsets.fromLTRB(16, empty && opening.isNotEmpty ? 0 : 24, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                ...errors,
                if (_fields.any((f) => f['hide'] != true)) form,
                if (empty && opening.isNotEmpty)
                  ConstrainedBox(
                    constraints: BoxConstraints(minHeight: MediaQuery.sizeOf(context).height / 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      spacing: 12,
                      children: [
                        icon(DifyAppIconSize.xl),
                        DifyMarkdown(
                          content: opening,
                          paragraphStyle: difyTextStyle(DifyType.body2xlRegular, DifyColors.textTertiary),
                        ),
                      ],
                    ),
                  ),
                for (final message in _history) ...[
                  Align(
                    alignment: Alignment.centerRight,
                    child: DifyChatBubbleSurface(child: DifyMarkdown(content: '${message['query'] ?? ''}')),
                  ),
                  DifyMarkdown(content: '${message['answer'] ?? ''}'),
                  RunFileList(files: getProcessedFilesFromResponse(_files(message['files']))),
                ],
                if (_question.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: DifyChatBubbleSurface(child: DifyMarkdown(content: _question)),
                  ),
                if (_answer.isNotEmpty) DifyMarkdown(content: _answer, isStreaming: _busy),
                if (_chatFiles.isNotEmpty) RunFileList(files: getProcessedFilesFromResponse(_chatFiles)),
                ...humanForms,
              ],
            ),
          ),
        ),
      ),
    );
    return DifyPage(
      backgroundColor: DifyColors.backgroundDefaultBurn,
      body: DifyPublicChatLayout(
        header: header,
        newChat: DifyButton(
          variant: DifyButtonVariant.secondaryAccent,
          onPressed: () => unawaited(_newChat()),
          disabled: unavailable,
          leading: const RemixIcon('edit-box-line', size: 16),
          child: DifyTextLine(_share('chat.newChat')),
        ),
        body: chat,
        composer: DifyPublicChatComposer(
          value: _query,
          disabled: unavailable,
          onChanged: (v) => setState(() => _query = v),
          onSubmitted: () => unawaited(_start()),
          placeholder: customPlaceholder != null && customPlaceholder.isNotEmpty
              ? customPlaceholder
              : DifyI18n.tr('common', 'chat.inputPlaceholder', {'botName': title}),
          action: DifyIconButton(
            label: _share(_busy ? 'generation.stopRun' : 'generation.run'),
            variant: DifyButtonVariant.primary,
            restyle: (look, hovered) =>
                look.copyWith(background: difyPublicChatPrimary(site['chat_color_theme'] as String?)),
            size: DifyIconButtonSize.lg,
            disabled: _loading || _loadFailed || _followDenied,
            onPressed: () => unawaited(_busy ? _stop() : _start()),
            icon: RemixIcon(_busy ? 'stop-circle-fill' : 'send-plane-2-fill', size: 16),
          ),
        ),
        footer: footer,
      ),
    );
  }
}
