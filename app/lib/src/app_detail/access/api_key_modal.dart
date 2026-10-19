/// The Service API's secret keys (Dify 1.17.1 web/app/components/api-key: api-key-modal.tsx, api-key-table.tsx,
/// created-api-key-dialog.tsx) for an app's built-in Service API. Dataset and deployment-environment keys are not part
/// of dify-sf.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../../settings/settings_kit.dart' show showSettingsAlert;
import '../../workflow_editor/code_editor/editor_view.dart' show codeEditorFontFamily;
import '../../auth/account_time.dart';
import 'access_point_utils.dart' show clearRequestErrors, notifyRequestError;

String _t(String ns, String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr(ns, key, params);

/// `maskToken`: the first 3 and the last 20 characters.
String maskApiKeyToken(String token) =>
    '${token.substring(0, token.length < 3 ? token.length : 3)}...'
    '${token.substring(token.length < 20 ? 0 : token.length - 20)}';

/// The app's keys as react-query keeps them for the modal and the button's badge: null until loaded.
class AppApiKeysQuery extends ChangeNotifier {
  AppApiKeysQuery({required this.api, required this.appId});

  final AccessApi api;
  final String appId;

  List<AppApiKey>? data;
  Object? error;
  bool get isPending => data == null && error == null;
  bool get isError => error != null;
  bool _disposed = false;

  /// Fetches (or refetches) the list.
  Future<void> fetch() async {
    try {
      final keys = await api.listApiKeys(appId);
      data = keys;
      error = null;
      clearRequestErrors('GET /apps/$appId/api-keys');
    } on Object catch (e) {
      error = e;
      notifyRequestError(e, get: true, request: 'GET /apps/$appId/api-keys');
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Shows [ApiKeyModal] for [query]'s app.
Future<void> showApiKeyModal(BuildContext context, {required AppApiKeysQuery query, required bool canManage}) =>
    showDifyDialog<void>(
      context,
      builder: (context) => ApiKeyModal(query: query, canManage: canManage),
    );

/// ApiKeyModal (app scope): "API Secret key" with its tip and close, the keys table (while there are keys; a
/// loading row while they load), and "Create new Secret key" (disabled without [canManage]). A created key shows in
/// [CreatedApiKeyDialog]; delete asks Dify's confirmation first.
class ApiKeyModal extends StatefulWidget {
  const ApiKeyModal({super.key, required this.query, required this.canManage});

  final AppApiKeysQuery query;
  final bool canManage;

  @override
  State<ApiKeyModal> createState() => _ApiKeyModalState();
}

class _ApiKeyModalState extends State<ApiKeyModal> {
  bool _creating = false;
  bool _deleting = false;

  AppApiKeysQuery get _query => widget.query;

  @override
  void initState() {
    super.initState();
    // The modal's own query runs while it is open.
    unawaited(_query.fetch());
  }

  Future<void> _create() async {
    if (!widget.canManage || _creating) return;
    setState(() => _creating = true);
    try {
      final key = await _query.api.createApiKey(_query.appId);
      unawaited(_query.fetch());
      if (mounted) await showCreatedApiKeyDialog(context, key.token);
    } on Object catch (e) {
      notifyRequestError(e);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _requestDelete(String keyId) async {
    await showSettingsAlert(
      context,
      title: _t('appApi', 'actionMsg.deleteConfirmTitle'),
      description: _t('appApi', 'actionMsg.deleteConfirmTips'),
      lockCancelWhileBusy: true,
      onConfirm: () async {
        if (_deleting) return;
        _deleting = true;
        try {
          await _query.api.deleteApiKey(_query.appId, keyId);
          unawaited(_query.fetch());
        } on Object catch (e) {
          // Dify's request layer toasts the server's message (the mutation has no onError); the dialog closes either way.
          notifyRequestError(e);
        } finally {
          _deleting = false;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) => DifyDialogSurface(
    label: _t('appApi', 'apiKeyModal.apiSecretKey'),
    width: 800,
    bordered: true,
    child: ListenableBuilder(
      listenable: _query,
      builder: (context, _) {
        final keys = _query.data;
        return Stack(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 56, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Text(
                        _t('appApi', 'apiKeyModal.apiSecretKey'),
                        style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                      ),
                      Text(
                        _t('appApi', 'apiKeyModal.apiSecretKeyTips'),
                        style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
                      ),
                    ],
                  ),
                ),
                if (_query.isPending)
                  Container(
                    key: const ValueKey('api-keys-loading'),
                    constraints: const BoxConstraints(minHeight: 96),
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    decoration: BoxDecoration(
                      border: Border.symmetric(horizontal: BorderSide(color: DifyColors.dividerSubtle)),
                    ),
                    alignment: Alignment.center,
                    child: DifySpinner(color: DifyColors.textTertiary),
                  ),
                if (keys != null && keys.isNotEmpty)
                  Flexible(
                    child: ApiKeyTable(apiKeys: keys, canManage: widget.canManage, onDeleteRequest: _requestDelete),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: DifyButton(
                      key: const ValueKey('api-key-create'),
                      disabled: !widget.canManage,
                      loading: _creating,
                      onPressed: () => unawaited(_create()),
                      leading: const RemixIcon('add-line', size: 16),
                      child: Text(_t('appApi', 'apiKeyModal.createNewSecretKey')),
                    ),
                  ),
                ),
              ],
            ),
            Positioned(top: 24, right: 24, child: const _CloseButton()),
          ],
        );
      },
    ),
  );
}

/// DialogClose: `IconButton size="lg"` with `close-line`, named "Close".
class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) => DifyIconButton(
    key: const ValueKey('dialog-close'),
    label: _t('common', 'operation.close'),
    size: DifyIconButtonSize.lg,
    icon: const RemixIcon('close-line', size: 16),
    onPressed: () => Navigator.of(context).maybePop(),
  );
}

/// ApiKeyTable ([DifyTable], `table-fixed`): `border-y border-divider-subtle`, a sticky
/// `system-xs-semibold-uppercase text-text-tertiary` header (Secret key `w-64 px-6`, Created and Last used `w-48 px-3`,
/// the actions `w-24 px-6`) and one row per key: the masked key (`font-mono`), the times (appLog's `dateTimeFormat`;
/// "Never" when unused), copy and (with [canManage]) delete.
class ApiKeyTable extends StatelessWidget {
  const ApiKeyTable({super.key, required this.apiKeys, required this.canManage, required this.onDeleteRequest});

  final List<AppApiKey> apiKeys;
  final bool canManage;
  final ValueChanged<String> onDeleteRequest;

  @override
  Widget build(BuildContext context) {
    final time = AccountTime.of(context);
    final head = difyTextStyle(DifyType.systemXsSemiboldUppercase, DifyColors.textTertiary);
    final cell = difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary);
    final format = _t('appLog', 'dateTimeFormat');
    Widget text(String s, TextStyle style) => Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    Widget headText(String s) => Text(
      difyTransform(DifyType.systemXsSemiboldUppercase, s),
      semanticsLabel: s,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: head,
    );
    const px6 = EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        px3 = EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    // `table-fixed` with `w-64`, `w-48`, `w-48`, `w-24` columns: the browser's fixed layout stretches them all in
    // proportion to fill the table's width.
    return DifyTable(
      layout: DifyTableLayout.fixed,
      minWidth: 0,
      scrollBody: true,
      headerStyle: DifyType.systemXsSemiboldUppercase,
      headerHeight: 32,
      headerDecoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        border: Border(bottom: BorderSide(color: DifyColors.dividerRegular)),
      ),
      decoration: BoxDecoration(
        border: Border.symmetric(horizontal: BorderSide(color: DifyColors.dividerSubtle)),
      ),
      columns: [
        DifyTableColumn(width: 256, headerPadding: px6, header: headText(_t('appApi', 'apiKeyModal.secretKey'))),
        DifyTableColumn(width: 192, headerPadding: px3, header: headText(_t('appApi', 'apiKeyModal.created'))),
        DifyTableColumn(width: 192, headerPadding: px3, header: headText(_t('appApi', 'apiKeyModal.lastUsed'))),
        // The actions column's header is only for screen readers ("Settings").
        DifyTableColumn(
          width: 96,
          headerPadding: EdgeInsets.zero,
          header: Semantics(label: _t('common', 'operation.settings'), child: const SizedBox(height: 32)),
        ),
      ],
      rows: [
        for (final (i, key) in apiKeys.indexed)
          DifyTableRow(
            hoverable: false,
            dividerColor: DifyColors.dividerRegular,
            divider: i != apiKeys.length - 1,
            cells: [
              Padding(
                padding: px6,
                child: text(maskApiKeyToken(key.token), cell.copyWith(fontFamily: monoFontFamily)),
              ),
              Padding(padding: px3, child: text(time.formatTime(key.createdAt ?? 0, format), cell)),
              Padding(
                padding: px3,
                child: text(
                  key.lastUsedAt != null && key.lastUsedAt != 0
                      ? time.formatTime(key.lastUsedAt!, format)
                      : _t('appApi', 'never'),
                  cell,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  spacing: 4,
                  children: [
                    DifyCopyFeedback(content: key.token),
                    if (canManage)
                      DifyIconButton(
                        label: '${_t('common', 'operation.delete')} ${maskApiKeyToken(key.token)}',
                        icon: const RemixIcon('delete-bin-line', size: 16),
                        onPressed: () => onDeleteRequest(key.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// Shows [CreatedApiKeyDialog] with [value].
Future<void> showCreatedApiKeyDialog(BuildContext context, String value) =>
    showDifyDialog<void>(context, builder: (context) => CreatedApiKeyDialog(value: value));

/// CreatedApiKeyDialog: "API Secret key", "Keep it somewhere safe…", the key in a read-only `font-mono` input with a
/// copy add-on, and OK.
class CreatedApiKeyDialog extends StatelessWidget {
  const CreatedApiKeyDialog({super.key, required this.value});
  final String value;

  @override
  Widget build(BuildContext context) => DifyDialogSurface(
    label: _t('appApi', 'apiKeyModal.apiSecretKey'),
    bordered: true,
    child: Stack(
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 56, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(
                    _t('appApi', 'apiKeyModal.apiSecretKey'),
                    style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary),
                  ),
                  Text(
                    _t('appApi', 'apiKeyModal.generateTips'),
                    style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: DifyInput(
                key: const ValueKey('created-api-key'),
                value: value,
                readOnly: true,
                semanticLabel: _t('appApi', 'apiKeyModal.secretKey'),
                fontFamily: monoFontFamily,
                trailing: Padding(
                  padding: const EdgeInsetsDirectional.only(end: 4),
                  child: DifyCopyFeedback(content: value),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Align(
                alignment: Alignment.centerRight,
                child: DifyButton(
                  variant: DifyButtonVariant.primary,
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(_t('appApi', 'actionMsg.ok')),
                ),
              ),
            ),
          ],
        ),
        Positioned(top: 24, right: 24, child: const _CloseButton()),
      ],
    ),
  );
}

/// `font-mono`: the bundled mono font (as the code editor).
const monoFontFamily = codeEditorFontFamily;
