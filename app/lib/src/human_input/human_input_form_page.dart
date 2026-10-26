/// Dify's mailed human-input form page (`app/(humanInputLayout)/form/[token]`, protocol 1.16): the link a recipient gets
/// by mail opens this page, which fetches the form with no account and answers it. The states are Dify's: the form while
/// it waits, "Thanks!" once it was recorded, "expired" / "already completed" when the server says so, and "form not
/// found" for a token that resolves to nothing.
library;

import '../web/startup_ready.dart';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../design/dify_tokens.g.dart';
import '../design/dify_icon.dart';
import '../workflow/dify_json.dart';
import '../workflow_editor/run/ui/human_input_content.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/node_panel/bodies/data/human_input/single_run.dart';

/// `share`'s `humanInput.*`.
String _share(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('share', 'humanInput.$key', params);

Map<String, Object?> _object(Object? value) => Map.fromEntries(jsEntries(value));

/// A form as the page holds it: Dify's FormDefinition (the console definition API's shape).
typedef HumanInputFormPageData = Map<String, Object?>;

class HumanInputFormPage extends StatefulWidget {
  const HumanInputFormPage({super.key, required this.token, required this.server, this.apiFor});

  /// The token the link carried (a recipient's token; a console token is not served to this page).
  final String token;
  final Uri server;

  /// The API to read and submit with; the page builds an unauthenticated one (a recipient has no account).
  final WorkflowRunApi Function(Uri server)? apiFor;

  @override
  State<HumanInputFormPage> createState() => _HumanInputFormPageState();
}

enum _State { loading, form, thanks, expired, completed, notFound, failed }

class _HumanInputFormPageState extends State<HumanInputFormPage> {
  late final WorkflowRunApi _api = (widget.apiFor ?? HttpWorkflowRunApi.new)(widget.server);
  _State _state = _State.loading;
  HumanInputFormPageData? _form;
  String? _error;
  final _toasts = DifyToastManager();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _state = _State.loading;
      _error = null;
    });
    try {
      final form = await _api.humanInputForm(widget.token);
      if (!mounted) return;
      setState(() {
        _form = form;
        _state = _State.form;
      });
    } on TransportException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = switch (e.code) {
          'human_input_form_expired' => _State.expired,
          'human_input_form_submitted' => _State.completed,
          'not_found' => _State.notFound,
          _ => _State.failed,
        };
        _error = e.message;
      });
    }
  }

  Future<void> _submit(Map<String, Object?> inputs, String action) async {
    try {
      await _api.submitHumanInputForm(widget.token, {
        // The page's form carries its inputs as Dify's FormDefinition does; `form_inputs` is the same shape the panel
        // sends (`{inputs, action}` is what the console form API takes — the fields themselves).
        'inputs': inputs,
        'action': action,
      });
      if (mounted) setState(() => _state = _State.thanks);
    } on TransportException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = switch (e.code) {
          'human_input_form_expired' => _State.expired,
          'human_input_form_submitted' => _State.completed,
          _ => _state,
        };
        _error = e.message;
      });
      // A submission that failed for another reason leaves the form on screen (with what was typed), so it can be sent
      // again; the message says why.
      if (_state == _State.form) {
        DifyToast(_toasts).error(e.message);
      }
    }
  }

  String get _title => switch (_state) {
    _State.loading => DifyI18n.tr('common', 'loading'),
    _State.thanks => _share('thanks'),
    _State.expired => _share('expired'),
    _State.completed => _share('completed'),
    _State.notFound => _share('formNotFound'),
    _State.failed => _share('sorry'),
    _State.form => (_form?['node_title'] as String?) ?? (_form?['form_id'] as String?) ?? '',
  };

  Map<String, Object?> get _site => _object(jsGet(_form?['site'], 'site'));
  Map<String, Object?> get _branding => _object(jsGet(_form?['site'], 'custom_config'));

  Widget _footer({bool customBrand = false}) => DifyBrandingFooter(
    removeBrand: customBrand && _branding['remove_webapp_brand'] == true,
    logoUrl: customBrand ? jsStr(_branding['replace_webapp_logo']) : null,
  );

  Widget _card(String title, String? tip, {required String icon, Color? iconColor, bool submission = true}) =>
      LayoutBuilder(
        builder: (context, constraints) => Center(
          // The source card is 480..640px, but narrow screens must remain usable.
          child: SingleChildScrollView(
            child: IntrinsicWidth(
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth.clamp(0, 480), maxWidth: 640),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DifyChatBubbleSurface(
                      key: const Key('human-form-status-card'),
                      height: 320,
                      padding: const EdgeInsets.fromLTRB(40, 40, 40, 36),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 16,
                        children: [
                          Container(
                            width: 56,
                            height: 56,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: DifyColors.backgroundDefaultDodge,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: DifyColors.componentsPanelBorderSubtle),
                            ),
                            child: RemixIcon(icon, size: 32, color: iconColor ?? DifyColors.textAccent),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                DifyText(title, DifyType.title4xlSemiBold, maxLines: null),
                                if (tip != null) DifyText(tip, DifyType.title4xlSemiBold, maxLines: null),
                              ],
                            ),
                          ),
                          if (submission)
                            DifyText(
                              _share('submissionID', {'id': widget.token}),
                              DifyType.system2xsRegularUppercase,
                              color: DifyColors.textTertiary,
                            ),
                        ],
                      ),
                    ),
                    _footer(customBrand: _state == _State.thanks),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  Widget _loadedForm() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 28, bottom: 12),
            child: Row(
              spacing: 12,
              children: [
                DifyAppIcon(
                  size: DifyAppIconSize.large,
                  iconType: jsStr(_site['icon_type']),
                  icon: jsStr(_site['icon']),
                  background: jsStr(_site['icon_background']),
                  imageUrl: jsStr(_site['icon_url']),
                ),
                Expanded(child: DifyText(jsStr(_site['title']) ?? _title, DifyType.systemXlSemibold)),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DifyChatBubbleSurface(
                    key: const Key('human-form-content-card'),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        HumanInputForm(
                          requireParagraph: true,
                          formData: {...HumanInputRunForm.definitionOf(_form!), 'form_token': widget.token},
                          onSubmit: (_, data) => _submit(_object(data['inputs']), jsStr(data['action']) ?? ''),
                        ),
                        if (_form?['expiration_time'] case final num expiration when expiration > 0)
                          HumanInputExpirationTime(expirationTime: (expiration * 1000).toInt()),
                      ],
                    ),
                  ),
                  _footer(customBrand: true),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_state != _State.loading) markStartupReadyAfterFrame();
    final Widget body = switch (_state) {
      _State.loading => const DifyLoading(),
      _State.thanks => _card(
        _share('thanks'),
        _share('recorded'),
        icon: 'checkbox-circle-fill',
        iconColor: DifyColors.textSuccess,
      ),
      _State.expired => _card(_share('sorry'), _share('expired'), icon: 'information-2-fill'),
      _State.completed => _card(_share('sorry'), _share('completed'), icon: 'information-2-fill'),
      _State.notFound => _card(
        _share('formNotFound'),
        null,
        icon: 'error-warning-fill',
        iconColor: DifyColors.textDestructive,
        submission: false,
      ),
      _State.failed => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: _card(_share('sorry'), _error, icon: 'error-warning-fill', submission: false)),
          DifyButton(onPressed: _load, child: DifyTextLine(DifyI18n.tr('common', 'operation.retry'))),
        ],
      ),
      _State.form => _loadedForm(),
    };
    return DifyPage(
      backgroundColor: DifyColors.backgroundBody,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(gradient: DifyGradients.chatbotBg),
              child: body,
            ),
            DifyToastHost(manager: _toasts),
          ],
        ),
      ),
    );
  }
}
