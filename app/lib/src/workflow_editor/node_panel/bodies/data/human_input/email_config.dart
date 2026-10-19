/// The email delivery's configuration (components/delivery-method/email-configure-modal.tsx, mail-body-input.tsx and
/// recipient/*: index, email-input, email-item, member-list, member-selector).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/css_metrics.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../workflow/dify_json.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../../../../prompt_editor/prompt_editor.dart';
import '../data_common.dart';
import 'delivery_method.dart' show EmailContext;
import 'human_input_kit.dart';

typedef Json = Map<String, Object?>;

/// The recipients of an email config (`RecipientData`), with the default `{whole_workspace: false, items: []}`.
Json recipientsOf(Json? config) => switch (config?['recipients']) {
  final Map<String, Object?> r => {'whole_workspace': jsTruthy(r['whole_workspace']), 'items': jsList(r['items'])},
  _ => {'whole_workspace': false, 'items': <Object?>[]},
};

/// Shows the Email Configuration dialog; the config saved, or null when cancelled.
Future<Json?> showEmailConfigureModal(BuildContext context, {Json? config, required EmailContext email}) {
  final toast = DataPanelHost.of(context).toast;
  final host = HumanInputHost.of(context);
  return showDifyDialog<Json>(
    context,
    builder: (context) => DataPanelHost(
      toast: toast,
      child: HumanInputHost(
        members: host.members,
        userEmail: host.userEmail,
        workspaceName: host.workspaceName,
        child: EmailConfigureModal(config: config, email: email),
      ),
    ),
  );
}

/// EmailConfigureModal (`w-180`): Subject, Body (MailBodyInput, `{{#url#}}` by default), Recipient and the Debug
/// Mode card; Save checks subject, body, the request URL in the body and the recipients (toasting the first problem)
/// and pops the config.
class EmailConfigureModal extends StatefulWidget {
  const EmailConfigureModal({super.key, this.config, required this.email});
  final Json? config;
  final EmailContext email;

  @override
  State<EmailConfigureModal> createState() => _EmailConfigureModalState();
}

class _EmailConfigureModalState extends State<EmailConfigureModal> {
  late Json _recipients = recipientsOf(widget.config);
  late String _subject = jsStr(widget.config?['subject']) ?? '';
  late String _body = jsStr(widget.config?['body']) ?? '{{#url#}}';
  late bool _debug = jsTruthy(widget.config?['debug_mode']);

  String _t(String key, [Map<String, Object?> p = const {}]) => hi('deliveryMethod.emailConfigure.$key', p);

  bool _check() {
    String? error;
    if (_subject.trim().isEmpty) {
      error = _t('subjectRequired');
    } else if (_body.trim().isEmpty) {
      error = _t('bodyRequired');
    } else if (!_body.trim().contains('{{#url#}}')) {
      error = _t('bodyMustContainRequestURL', {'field': cm('promptEditor.requestURL.item.title')});
    } else if (jsList(_recipients['items']).isEmpty && !jsTruthy(_recipients['whole_workspace'])) {
      error = _t('recipientsRequired');
    }
    if (error != null) showDataToast(context, DataToastType.error, error);
    return error == null;
  }

  void _save() {
    if (!_check()) return;
    Navigator.of(context).pop(<String, Object?>{
      'recipients': _recipients,
      'subject': _subject,
      'body': _body,
      'debug_mode': _debug,
    });
  }

  Widget _label(String text) => SizedBox(
    height: 24,
    child: Align(
      alignment: Alignment.centerLeft,
      child: DifyText(text, DifyType.systemSmMedium, color: DifyColors.textSecondary),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final email = HumanInputHost.of(context).userEmail;
    final base = difyStyle(DifyType.bodyXsRegular, DifyColors.textTertiary);
    return DifyDialogSurface(
      padding: const EdgeInsets.all(24),
      scrollable: true,
      width: 720,
      label: _t('title'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    DifyText(_t('title'), DifyType.title2xlSemiBold, maxLines: null),
                    DifyText(_t('description'), DifyType.systemXsRegular, color: DifyColors.textTertiary),
                  ],
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: DifyIconButton(
                  label: cm('operation.close'),
                  size: DifyIconButtonSize.lg,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const RemixIcon('close-line', size: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _label(_t('subject')),
          const SizedBox(height: 4),
          DifyInput(
            value: _subject,
            semanticLabel: _t('subject'),
            placeholder: _t('subjectPlaceholder'),
            onChanged: (v) => setState(() => _subject = v),
          ),
          const SizedBox(height: 20),
          _label(_t('body')),
          const SizedBox(height: 4),
          MailBodyInput(value: _body, onChange: (v) => setState(() => _body = v), email: widget.email),
          const SizedBox(height: 20),
          _label(_t('recipient')),
          const SizedBox(height: 4),
          Recipient(data: _recipients, onChange: (v) => setState(() => _recipients = v)),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 12, 12, 12),
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelOnPanelItemBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
              boxShadow: DifyShadows.xs,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: DifyColors.componentsIconBgOrangeDarkSolid,
                    border: Border.all(color: DifyColors.dividerRegular),
                    borderRadius: BorderRadius.circular(DifyRadius.sm),
                  ),
                  child: RemixIcon('bug-line', size: 14, color: DifyColors.textPrimaryOnSurface),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      DifyText(_t('debugMode'), DifyType.systemSmMedium, color: DifyColors.textSecondary),
                      Text.rich(
                        TextSpan(
                          children: transSpans(_t('debugModeTip1', {'email': email}), {
                            'email': (inner) => TextSpan(
                              text: inner,
                              style: difyStyle(DifyType.bodyMdMedium, DifyColors.textPrimary),
                            ),
                          }),
                        ),
                        style: base,
                      ),
                      Text(_t('debugModeTip2'), style: base),
                    ],
                  ),
                ),
                DifySwitch(
                  checked: _debug,
                  semanticLabel: _t('debugMode'),
                  onCheckedChange: (v) => setState(() => _debug = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          HiFooter(
            children: [
              SizedBox(
                width: 72,
                child: DifyButton(onPressed: () => Navigator.of(context).pop(), child: Text(cm('operation.cancel'))),
              ),
              SizedBox(
                width: 72,
                child: DifyButton(
                  variant: DifyButtonVariant.primary,
                  onPressed: _save,
                  child: Text(cm('operation.save')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// mixed-variable-text-input/placeholder.tsx with `hideBadge`: "Type or press [/] insert variable".
class _InsertPlaceholder extends StatelessWidget {
  const _InsertPlaceholder();

  @override
  Widget build(BuildContext context) => Row(
    spacing: 4,
    children: [
      DifyText(
        wf('nodes.tool.insertPlaceholder1'),
        DifyType.systemSmRegular,
        color: DifyColors.componentsInputTextPlaceholder,
      ),
      const DifyKbd('/'),
      Flexible(
        child: Text(
          wf('nodes.tool.insertPlaceholder2'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: difyStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextPlaceholder).copyWith(
            decoration: TextDecoration.underline,
            decorationStyle: TextDecorationStyle.dotted,
          ),
        ),
      ),
    ],
  );
}

/// MailBodyInput: a prompt editor (`min-h-32`, `rounded-lg bg-components-input-bg-normal px-2 py-1`, the input's hover
/// and focus looks) with the request-URL block and the workflow variables.
class MailBodyInput extends StatefulWidget {
  const MailBodyInput({super.key, required this.value, this.onChange, required this.email, this.readOnly = false});
  final String value;
  final ValueChanged<String>? onChange;
  final EmailContext email;
  final bool readOnly;

  @override
  State<MailBodyInput> createState() => _MailBodyInputState();
}

class _MailBodyInputState extends State<MailBodyInput> {
  late final _focus = FocusNode(debugLabel: 'mail body')..addListener(() => setState(() {}));
  bool _hovered = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: focused
              ? DifyColors.componentsInputBgActive
              : _hovered
              ? DifyColors.componentsInputBgHover
              : DifyColors.componentsInputBgNormal,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(
            color: focused
                ? DifyColors.componentsInputBorderActive
                : _hovered
                ? DifyColors.componentsInputBorderHover
                : const Color(0x00000000),
          ),
          boxShadow: focused ? DifyShadows.xs : null,
        ),
        child: DifyPromptEditor(
          value: widget.value,
          onChange: widget.onChange,
          focusNode: _focus,
          editable: !widget.readOnly,
          minHeight: 128,
          semanticLabel: hi('deliveryMethod.emailConfigure.body'),
          placeholder: const _InsertPlaceholder(),
          requestUrlBlock: const PromptBlockConfig(show: true, selectable: true),
          workflowVariableBlock: WorkflowVariableBlockConfig(
            show: true,
            variables: widget.email.vars,
            workflowNodesMap: widget.email.nodesMap,
          ),
        ),
      ),
    );
  }
}

/// Recipient: the members / external recipients card (title, the member selector, the email tag input) and the
/// "All members (workspace)" card with its Switch.
class Recipient extends StatelessWidget {
  const Recipient({super.key, required this.data, required this.onChange});
  final Json data;
  final ValueChanged<Json> onChange;

  List<Object?> get _items => jsList(data['items']);

  void _push(Json item) => onChange({
    ...data,
    'items': [..._items, item],
  });

  void _delete(Json recipient) => onChange({
    ...data,
    'items': [
      for (final i in _items)
        if (recipient['type'] == 'member'
            ? jsGet(i, 'user_id') != recipient['user_id']
            : recipient['type'] == 'external'
            ? jsGet(i, 'email') != recipient['email']
            : true)
          i,
    ],
  });

  @override
  Widget build(BuildContext context) {
    final host = HumanInputHost.of(context);
    final workspace = host.workspaceName;
    final label = hi('deliveryMethod.emailConfigure.allMembers', {'workspaceName': workspace.replaceAll("'", '’')});
    BoxDecoration card() => BoxDecoration(
      color: DifyColors.componentsPanelOnPanelItemBg,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
      boxShadow: DifyShadows.xs,
    );
    void selectMember(String id) => _push({'type': 'member', 'user_id': id});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        Container(
          decoration: card(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 40,
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  child: Row(
                    children: [
                      RemixIcon('group-line', size: 16, color: DifyColors.textSecondary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DifyText(
                          hi('deliveryMethod.emailConfigure.memberSelector.title'),
                          DifyType.systemSmMedium,
                          color: DifyColors.textSecondary,
                        ),
                      ),
                      SizedBox(
                        width: 86,
                        child: MemberSelector(
                          value: _items,
                          email: host.userEmail,
                          list: host.members,
                          onSelect: selectMember,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              EmailInput(
                email: host.userEmail,
                value: _items,
                list: host.members,
                onDelete: _delete,
                onSelect: selectMember,
                onAdd: (e) => _push({'type': 'external', 'email': e}),
              ),
            ],
          ),
        ),
        Container(
          height: 40,
          padding: const EdgeInsets.only(left: 10, right: 12),
          decoration: card(),
          child: Row(
            spacing: 8,
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: DifyColors.componentsIconBgBlueSolid,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  workspace.isEmpty ? '' : workspace[0].toUpperCase(),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: DifyColors.componentsAvatarShapeFillStop0,
                  ),
                ),
              ),
              Expanded(child: DifyText(label, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
              DifySwitch(
                checked: jsTruthy(data['whole_workspace']),
                semanticLabel: label,
                onCheckedChange: (v) => onChange({...data, 'whole_workspace': v}),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The `{type, user_id | email}` recipients with their member's email and name (`selectedEmails`).
List<({Json item, HiMember? member})> _resolve(List<Object?> value, List<HiMember> list) => [
  for (final v in value)
    if (v is Map<String, Object?>) (item: v, member: list.where((m) => m.id == v['user_id']).firstOrNull),
];

/// `/^[^\s@]+@[^\s@][^\s.@]*\.[^\s@]+$/`.
bool isValidEmail(String email) => RegExp(r'^[^\s@]+@[^\s@][^\s.@]*\.[^\s@]+$').hasMatch(email);

/// EmailInput: the chosen recipients as chips and a text input (`min-w-41.5`): Enter, Space, Comma or blur add the
/// typed email (a member's email adds that member; invalid and duplicate emails are ignored); Backspace on an empty
/// input removes the last recipient; typing shows the matching members below. Keys stay in the input (the workflow's
/// shortcuts don't see them). [disabled] shows only the chips.
class EmailInput extends StatefulWidget {
  const EmailInput({
    super.key,
    required this.email,
    required this.value,
    required this.list,
    required this.onDelete,
    required this.onSelect,
    required this.onAdd,
    this.disabled = false,
  });

  final String email;
  final List<Object?> value;
  final List<HiMember> list;
  final ValueChanged<Json> onDelete;
  final ValueChanged<String> onSelect, onAdd;
  final bool disabled;

  @override
  State<EmailInput> createState() => _EmailInputState();
}

class _EmailInputState extends State<EmailInput> {
  late final _focus = FocusNode(debugLabel: 'email input', onKeyEvent: _onKey)..addListener(_focusChanged);
  final _text = TextEditingController();
  bool _focused = false, _open = false, _hovered = false;

  @override
  void dispose() {
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (_focus.hasFocus == _focused) return;
    setState(() => _focused = _focus.hasFocus);
    if (!_focused) _add();
  }

  void _add() {
    final w = widget, address = _text.text.trim();
    if (!isValidEmail(address)) return;
    if (w.value.any((i) => jsGet(i, 'email') == address)) return;
    final member = w.list.where((m) => m.email == address).firstOrNull;
    if (member != null) {
      w.onSelect(member.id);
    } else {
      w.onAdd(address);
    }
    _text.clear();
    setState(() => _open = false);
  }

  void _select(String id) {
    _text.clear();
    setState(() => _open = false);
    widget.onSelect(id);
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.skipRemainingHandlers;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.tab) {
      setState(() => _open = false);
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.comma) {
      _add();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace && _text.text.isEmpty && widget.value.isNotEmpty) {
      final last = widget.value.last;
      if (last is Map<String, Object?>) widget.onDelete(last);
      setState(() => _open = false);
      return KeyEventResult.handled;
    }
    // stopPropagation: the text field gets the key, the workflow's listeners don't.
    return KeyEventResult.skipRemainingHandlers;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final selected = _resolve(w.value, w.list);
    final placeholder = selected.isEmpty || _focused
        ? hi('deliveryMethod.emailConfigure.memberSelector.placeholder')
        : '';
    final matches = filterMembers(w.list, _text.text);
    final input = SizedBox(
      width: 166,
      height: 24,
      child: TextField(
        key: const ValueKey('email-input'),
        controller: _text,
        focusNode: _focus,
        onChanged: (v) => setState(() => _open = v.trim().isNotEmpty),
        style: difyStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextFilled),
        cursorColor: const Color(0xFF155EEF),
        cursorWidth: 1,
        decoration: InputDecoration(
          isCollapsed: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(4),
          hintText: placeholder,
          hintStyle: difyStyle(DifyType.systemSmRegular, DifyColors.componentsInputTextPlaceholder),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          key: const ValueKey('email-input-box'),
          behavior: HitTestBehavior.opaque,
          onTap: w.disabled ? null : _focus.requestFocus,
          child: Container(
            constraints: const BoxConstraints(minHeight: 64, maxHeight: 96),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _focused
                  ? DifyColors.componentsInputBgActive
                  : _hovered && !w.disabled
                  ? DifyColors.componentsInputBgHover
                  : DifyColors.componentsInputBgNormal,
              borderRadius: BorderRadius.circular(DifyRadius.lg),
              border: Border.all(
                color: _focused
                    ? DifyColors.componentsInputBorderActive
                    : _hovered && !w.disabled
                    ? DifyColors.componentsInputBorderHover
                    : const Color(0x00000000),
              ),
              boxShadow: _focused ? DifyShadows.xs : null,
            ),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final s in selected)
                    EmailItem(
                      key: ValueKey(s.item['user_id'] ?? s.item['email']),
                      email: w.email,
                      address: s.member?.email ?? jsStr(s.item['email']) ?? '',
                      name: s.member?.name ?? '',
                      avatarUrl: s.member?.avatarUrl,
                      disabled: w.disabled,
                      isError: s.item['type'] == 'member' && s.member == null,
                      onDelete: () => w.onDelete(s.item),
                    ),
                  if (!w.disabled)
                    DifyFloating(
                      open: _open && matches.isNotEmpty,
                      onOpenChange: (o) {
                        if (!o) setState(() => _open = false);
                      },
                      placement: DifyPlacement.bottomStart,
                      sideOffset: 4,
                      alignOffset: -40,
                      focusPopup: false,
                      builder: (context, _) => input,
                      popupBuilder: (context) => MemberList(
                        value: w.value,
                        searchValue: _text.text,
                        list: w.list,
                        email: w.email,
                        hideSearch: true,
                        onSelect: _select,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// dify-ui's Avatar: [size] px, round, the image or the name's initial on `bg-primary-600`.
class HiAvatar extends StatelessWidget {
  const HiAvatar({super.key, required this.name, this.url, this.size = 24});
  final String name;
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    clipBehavior: Clip.antiAlias,
    alignment: Alignment.center,
    decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF155AEF)),
    child: url == null || url!.isEmpty
        ? Text(
            name.isEmpty ? '' : name[0].toUpperCase(),
            style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w500, color: const Color(0xFFFFFFFF)),
          )
        : Image.network(
            url!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox(),
          ),
  );
}

/// EmailItem: a 24 px pill with the avatar (or, for a member no longer in the workspace, the destructive warning
/// icon and style), the email (the current user: their name and "(You)") and the remove icon unless [disabled].
class EmailItem extends StatelessWidget {
  const EmailItem({
    super.key,
    required this.email,
    required this.address,
    required this.onDelete,
    this.name = '',
    this.avatarUrl,
    this.disabled = false,
    this.isError = false,
  });

  final String email, address, name;
  final String? avatarUrl;
  final VoidCallback onDelete;
  final bool disabled, isError;

  @override
  Widget build(BuildContext context) {
    final isMe = email == address;
    return Tooltip(
      message: address,
      child: Container(
        height: 24,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: isError ? DifyColors.stateDestructiveHover : DifyColors.componentsBadgeWhiteToDark,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isError ? DifyColors.stateDestructiveHoverAlt : DifyColors.componentsPanelBorderSubtle,
          ),
          boxShadow: DifyShadows.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            if (isError)
              RemixIcon('error-warning-fill', size: 16, color: DifyColors.textDestructive)
            else
              HiAvatar(name: name.isNotEmpty ? name : address, url: avatarUrl, size: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: isMe ? name : address),
                    if (isMe)
                      TextSpan(
                        text: cm('members.you'),
                        style: TextStyle(color: DifyColors.textTertiary),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: difyStyle(DifyType.systemXsRegular, DifyColors.textPrimary),
              ),
            ),
            if (!disabled)
              DifyPressable(
                semanticLabel: cm('operation.remove'),
                onPressed: onDelete,
                builder: (context, hovered, _) => RemixIcon(
                  'close-circle-fill',
                  size: 16,
                  color: hovered ? DifyColors.textTertiary : DifyColors.textQuaternary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// MemberList's `filteredList`: the members whose name or email contains [search] (case-insensitive).
List<HiMember> filterMembers(List<HiMember> list, String search) {
  if (search.isEmpty) return list;
  final q = search.toLowerCase();
  return [
    for (final m in list)
      if (m.name.toLowerCase().contains(q) || m.email.toLowerCase().contains(q)) m,
  ];
}

/// MemberList (`min-w-[320px]`): a search box unless [hideSearch], then the matching members (avatar, name, "Pending"
/// and "(You)", email); a selected member is dimmed and shows "Added", the others "+ Add" on hover. Nothing with
/// [hideSearch] and no match.
class MemberList extends StatelessWidget {
  const MemberList({
    super.key,
    required this.value,
    required this.searchValue,
    required this.list,
    required this.onSelect,
    required this.email,
    this.onSearchChange,
    this.hideSearch = false,
  });

  final List<Object?> value;
  final String searchValue;
  final List<HiMember> list;
  final ValueChanged<String> onSelect;
  final ValueChanged<String>? onSearchChange;
  final String email;
  final bool hideSearch;

  @override
  Widget build(BuildContext context) {
    final filtered = filterMembers(list, searchValue);
    if (hideSearch && filtered.isEmpty) return const SizedBox.shrink();
    final search = cm('operation.search');
    return Container(
      constraints: const BoxConstraints(minWidth: 320, maxWidth: 320),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBgBlur,
        borderRadius: BorderRadius.circular(DifyRadius.xl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        boxShadow: DifyShadows.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!hideSearch)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: DifyInput(
                value: searchValue,
                placeholder: search,
                semanticLabel: search,
                onChanged: onSearchChange,
                leading: Padding(
                  padding: EdgeInsets.only(left: 8, right: 2),
                  child: RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
                ),
              ),
            ),
          if (filtered.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 248),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final m in filtered) _MemberRow(member: m, email: email, value: value, onSelect: onSelect),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member, required this.email, required this.value, required this.onSelect});
  final HiMember member;
  final String email;
  final List<Object?> value;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final selected = value.any((i) => jsGet(i, 'user_id') == member.id);
    const key = 'deliveryMethod.emailConfigure.memberSelector';
    return DifyPressable(
      disabled: selected,
      onPressed: () => onSelect(member.id),
      builder: (context, hovered, _) => Container(
        padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
        decoration: BoxDecoration(
          color: hovered && !selected ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: Row(
          spacing: 8,
          children: [
            Opacity(
              opacity: selected ? 0.5 : 1,
              child: HiAvatar(name: member.name, url: member.avatarUrl),
            ),
            Expanded(
              child: Opacity(
                opacity: selected ? 0.5 : 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: member.name),
                          if (member.status == 'pending')
                            TextSpan(
                              text: ' ${cm('members.pending')}',
                              style: difyStyle(DifyType.systemXsMedium, DifyColors.textWarning),
                            ),
                          if (email == member.email)
                            TextSpan(
                              text: cm('members.you'),
                              style: difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                            ),
                        ],
                      ),
                      style: difyStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                    ),
                    DifyText(member.email, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                  ],
                ),
              ),
            ),
            if (!selected && hovered)
              Flexible(child: DifyText(hi('$key.add'), DifyType.systemXsMedium, color: DifyColors.textAccent)),
            if (selected)
              Flexible(child: DifyText(hi('$key.added'), DifyType.systemXsRegular, color: DifyColors.textTertiary)),
          ],
        ),
      ),
    );
  }
}

/// MemberSelector: a full-width ghost-accent "Select" button (`RiContactsBookLine`) opening the searchable member list
/// (bottom-end); choosing a member closes it.
class MemberSelector extends StatefulWidget {
  const MemberSelector({
    super.key,
    required this.value,
    required this.email,
    required this.onSelect,
    this.list = const [],
  });

  final List<Object?> value;
  final String email;
  final ValueChanged<String> onSelect;
  final List<HiMember> list;

  @override
  State<MemberSelector> createState() => _MemberSelectorState();
}

class _MemberSelectorState extends State<MemberSelector> {
  final _popup = DifyFloatingController();
  String _search = '';

  @override
  Widget build(BuildContext context) => DifyFloating(
    controller: _popup,
    placement: DifyPlacement.bottomEnd,
    sideOffset: 4,
    alignOffset: 35,
    // Long translations shrink the button rather than overflow its 86 px.
    builder: (context, c) => FittedBox(
      fit: BoxFit.scaleDown,
      child: DifyButton(
        variant: DifyButtonVariant.ghostAccent,
        onPressed: c.toggle,
        semanticLabel: hi('deliveryMethod.emailConfigure.memberSelector.trigger'),
        leading: const RemixIcon('contacts-book-line', size: 16),
        child: Text(hi('deliveryMethod.emailConfigure.memberSelector.trigger')),
      ),
    ),
    popupBuilder: (context) => StatefulBuilder(
      builder: (context, setPopup) => MemberList(
        value: widget.value,
        searchValue: _search,
        list: widget.list,
        email: widget.email,
        onSearchChange: (v) {
          setPopup(() {});
          setState(() => _search = v);
        },
        onSelect: (id) {
          widget.onSelect(id);
          _popup.close();
        },
      ),
    ),
  );
}
