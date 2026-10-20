/// Dify's mailed human-input form page (`app/(humanInputLayout)/form/[token]`, protocol 1.16): the link a recipient gets
/// by mail opens this page, which fetches the form with no account and answers it. The states are Dify's: the form while
/// it waits, "Thanks!" once it was recorded, "expired" / "already completed" when the server says so, and "form not
/// found" for a token that resolves to nothing.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/node_panel/bodies/data/human_input/single_run.dart';

/// `share`'s `humanInput.*`.
String _share(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('share', 'humanInput.$key', params);

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
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(e.message)));
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

  Widget _card(String title, String? tip) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DifyText(title, DifyType.systemXlSemibold, color: DifyColors.textPrimary),
          if (tip != null) ...[
            const SizedBox(height: 8),
            DifyText(tip, DifyType.bodyMdRegular, color: DifyColors.textSecondary),
          ],
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final Widget body = switch (_state) {
      _State.loading => const Center(child: CircularProgressIndicator()),
      _State.thanks => _card(_share('thanks'), _share('recorded')),
      _State.expired => _card(_share('expired'), _share('expiredTip')),
      _State.completed => _card(_share('completed'), null),
      _State.notFound => _card(_share('formNotFound'), null),
      _State.failed => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _card(_share('sorry'), _error),
          DifyButton(onPressed: _load, child: Text(DifyI18n.tr('common', 'operation.retry'))),
        ],
      ),
      _State.form => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: HumanInputRunForm(
              nodeName: _title,
              data: _form!,
              onSubmit: _submit,
              onError: (e) {},
            ),
          ),
        ),
      ),
    };
    return Scaffold(
      backgroundColor: DifyColors.backgroundBody,
      body: SafeArea(child: Center(child: body)),
    );
  }
}
