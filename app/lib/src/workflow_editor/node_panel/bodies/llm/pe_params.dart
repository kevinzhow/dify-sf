/// The Parameter Extractor's parameters (nodes/parameter-extractor/components/extract-parameter/*.tsx,
/// components/reasoning-mode-picker.tsx): the list and its items, the Add / Edit Extract Parameter dialog, Import
/// from tools and the reasoning mode cards.
library;

import 'package:flutter/widgets.dart';

import '../../../../design/css_metrics.dart';
import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../panel_fields/panel_fields.dart';
import 'group_host.dart';
import 'llm_vars.dart' show jsMap;
import 'qc_pe_kit.dart';
import 'tool_picker.dart';

const _p = 'nodes.parameterExtractor';
String _w(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String _c(String key) => DifyI18n.tr('common', key);
String _d(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('app-debug', key, params);

/// `ParamType` values the dialog offers (`select` only comes from tools).
const paramTypes = ['string', 'number', 'boolean', 'array[string]', 'array[number]', 'array[object]', 'array[boolean]'];

/// `DEFAULT_PARAM`.
Json defaultParam() => {'name': '', 'type': 'string', 'description': '', 'required': false};

/// `MoreInfo` of a name change (`ChangeType.changeVarName`): the name before the last keystroke and after it.
typedef ParamRename = ({String beforeKey, String afterKey});

/// `toParmExactParams`: a tool's `llm` parameters as extract parameters (option labels in [language], else
/// `en_US`).
List<Json> toolParamsToExtractParams(List<Object?> toolParams, String language) => [
  for (final p in toolParams)
    if (jsGet(p, 'form') == 'llm')
      {
        'name': jsGet(p, 'name'),
        'type': jsGet(p, 'type'),
        'required': jsGet(p, 'required'),
        'description': jsGet(p, 'llm_description'),
        'options': [
          for (final o in jsList(jsGet(p, 'options')))
            jsStr(jsGet(jsGet(o, 'label'), language)) ?? jsGet(jsGet(o, 'label'), 'en_US'),
        ],
      },
];

/// The type labels (CSS `capitalize`).
String _cap(String s) => cssCapitalize(s);

// ---- item.tsx ----------------------------------------------------------------------------------------------------

/// Item: `group relative rounded-lg bg-components-input-bg-normal px-2.5 py-2`: the name with its icon and type,
/// REQUIRED, the description; on hover (or a tap) the edit and delete buttons over a gradient (not gated by
/// read-only, as in Dify).
class ExtractParamItem extends StatefulWidget {
  const ExtractParamItem({super.key, required this.payload, required this.onEdit, required this.onDelete});
  final Json payload;
  final VoidCallback onEdit, onDelete;

  @override
  State<ExtractParamItem> createState() => _ExtractParamItemState();
}

class _ExtractParamItemState extends State<ExtractParamItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.payload;
    final required = p['required'] == true;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _hovered = true),
        child: Stack(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: DifyColors.componentsInputBgNormal,
                borderRadius: BorderRadius.circular(DifyRadius.lg),
                boxShadow: _hovered ? DifyShadows.xs : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // `flex justify-between`: the name and type, REQUIRED at the end.
                  JustifyBetween(
                    // The name's 19.5 px line (Flutter rounds the paragraph's to 19).
                    lead: SizedBox(
                      height: 19.5,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DifyIcon(
                            'vender/solid/development/variable-02',
                            size: 14,
                            color: DifyColors.textAccentSecondary,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '${p['name'] ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              // `text-[13px]` on the inherited 1.5 line height.
                              style: difyTextStyle(DifyTw.text13MediumLeading150, DifyColors.textPrimary),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _cap('${p['type'] ?? ''}'),
                            style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    trail: required
                        ? Text(
                            _w('$_p.addExtractParameterContent.required').toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                          )
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${p['description'] ?? ''}',
                    style: difyTextStyle(DifyTw.textXsLeading18, DifyColors.textTertiary),
                  ),
                ],
              ),
            ),
            if (_hovered)
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                width: 119,
                child: Container(
                  padding: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(DifyRadius.lg),
                    gradient: LinearGradient(
                      begin: Alignment.centerRight,
                      end: Alignment.centerLeft,
                      colors: [DifyColors.componentsPanelOnPanelItemBg, DifyColors.backgroundGradientMaskTransparent],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    spacing: 4,
                    children: [
                      DifyIconButton(
                        label: _c('operation.edit'),
                        icon: RemixIcon('edit-line', size: 16, color: DifyColors.textTertiary),
                        onPressed: widget.onEdit,
                      ),
                      DifyIconButton(
                        label: _c('operation.delete'),
                        tone: DifyButtonTone.destructive,
                        icon: const RemixIcon('delete-bin-line', size: 16),
                        onPressed: widget.onDelete,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---- list.tsx ----------------------------------------------------------------------------------------------------

/// List: the "Extract Parameters not setup" placeholder, or the items; editing opens the dialog and replaces the
/// item ([onChange] with the rename the dialog reports), deleting drops it.
class ExtractParamList extends StatelessWidget {
  const ExtractParamList({super.key, required this.list, required this.onChange, this.readonly = false});
  final List<Json> list;
  final void Function(List<Json> list, ParamRename? rename) onChange;
  final bool readonly;

  @override
  Widget build(BuildContext context) {
    if (list.isEmpty) return ListNoDataPlaceholder(_w('$_p.extractParametersNotSet'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        for (final (i, item) in list.indexed)
          ExtractParamItem(
            key: ValueKey('param-$i'),
            payload: item,
            onEdit: () => showExtractParameterDialog(
              context,
              isAdd: false,
              payload: item,
              onSave: (p, rename) => onChange([for (final (j, x) in list.indexed) j == i ? p : x], rename),
            ),
            onDelete: () => onChange([
              for (final (j, x) in list.indexed)
                if (j != i) x,
            ], null),
          ),
      ],
    );
  }
}

// ---- update.tsx --------------------------------------------------------------------------------------------------

/// The add trigger (`mx-1 rounded-md p-1`, `i-ri-add-line`): opens the dialog on a fresh parameter.
class AddExtractParameterButton extends StatelessWidget {
  const AddExtractParameterButton({super.key, required this.onSave, this.onCancel});
  final void Function(Json param, ParamRename? rename) onSave;
  final VoidCallback? onCancel;

  // Alone in its `<div>`, on that block's text line (see Css.inlineButtonLineGap).
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(4, 0, 4, Css.inlineButtonLineGap),
    child: AddIconButton(
      label: _w('$_p.addExtractParameter'),
      onPressed: () => showExtractParameterDialog(context, isAdd: true, onSave: onSave, onCancel: onCancel),
    ),
  );
}

/// Opens the Add / Edit Extract Parameter dialog ([payload] for an edit). Closing it without saving (Cancel,
/// Escape, the backdrop) calls [onCancel].
Future<void> showExtractParameterDialog(
  BuildContext context, {
  required bool isAdd,
  Json? payload,
  required void Function(Json param, ParamRename? rename) onSave,
  VoidCallback? onCancel,
}) async {
  final services = LlmGroupScope.of(context);
  final saved = await showDifyDialog<bool>(
    context,
    builder: (ctx) => LlmGroupScope(
      services: services,
      child: DifyDialogSurface(
        label: _w('$_p.addExtractParameter'),
        width: 400,
        padding: const EdgeInsets.all(16),
        child: ExtractParameterForm(
          isAdd: isAdd,
          payload: isAdd ? defaultParam() : {...?payload},
          onSave: (p, r) {
            onSave(p, r);
            Navigator.of(ctx).pop(true);
          },
          onCancel: () => Navigator.of(ctx).pop(false),
        ),
      ),
    ),
  );
  if (saved != true) onCancel?.call();
}

/// The dialog's content: Name (checked on each keystroke: an invalid name is refused with a toast), Type,
/// Options (for `select`), Description, Required; Cancel and Add / Save (which checks the required fields).
class ExtractParameterForm extends StatefulWidget {
  const ExtractParameterForm({
    super.key,
    required this.isAdd,
    required this.payload,
    required this.onSave,
    required this.onCancel,
  });

  final bool isAdd;
  final Json payload;
  final void Function(Json param, ParamRename? rename) onSave;
  final VoidCallback onCancel;

  @override
  State<ExtractParameterForm> createState() => _ExtractParameterFormState();
}

class _ExtractParameterFormState extends State<ExtractParameterForm> {
  late Json _param = {...widget.payload};
  ParamRename? _rename;

  void _toast(String m) => LlmGroupScope.of(context).toast?.call(LlmToastType.error, m);

  void _change(String key, Object? value) {
    if (key == 'name') {
      final bad = checkKeys(['$value'], canBeEmpty: true);
      if (bad != null) {
        _toast(_d('varKeyError.${bad.error}', {'key': bad.key}));
        setState(() {}); // the input shows the name it had
        return;
      }
    }
    setState(() {
      _rename = key == 'name' ? (beforeKey: '${_param['name'] ?? ''}', afterKey: '$value') : null;
      _param = {..._param, key: value};
    });
  }

  String _required(String field) => _w('errorMsg.fieldRequired', {'field': field});

  void _save() {
    var err = '';
    if ('${_param['name'] ?? ''}'.isEmpty) err = _required(_w('$_p.addExtractParameterContent.name'));
    if (err.isEmpty && _param['type'] == 'select' && jsList(_param['options']).isEmpty) {
      err = _required(_d('variableConfig.options'));
    }
    if (err.isEmpty && '${_param['description'] ?? ''}'.isEmpty) {
      err = _required(_w('$_p.addExtractParameterContent.description'));
    }
    if (err.isNotEmpty) return _toast(err);
    widget.onSave(_param, _rename);
  }

  Widget _field(String title, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: 32,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(title, style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary)),
        ),
      ),
      child,
    ],
  );

  @override
  Widget build(BuildContext context) {
    final nameLabel = _w('$_p.addExtractParameterContent.name');
    final descLabel = _w('$_p.addExtractParameterContent.description');
    final type = '${_param['type'] ?? 'string'}';
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          DifyText(_w('$_p.addExtractParameter'), DifyType.title2xlSemiBold, maxLines: null),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              _field(
                nameLabel,
                DifyInput(
                  value: '${_param['name'] ?? ''}',
                  semanticLabel: nameLabel,
                  placeholder: _w('$_p.addExtractParameterContent.namePlaceholder'),
                  onChanged: (v) => _change('name', v),
                ),
              ),
              _field(
                _w('$_p.addExtractParameterContent.type'),
                DifySelect<String>(
                  value: type,
                  capitalize: true,
                  options: [for (final t in paramTypes) (value: t, label: t)],
                  onChanged: (v) => _change('type', v),
                ),
              ),
              if (type == 'select')
                _field(
                  _d('variableConfig.options'),
                  ConfigSelect(
                    options: [for (final o in jsList(_param['options'])) '$o'],
                    onChange: (o) => _change('options', o),
                  ),
                ),
              _field(
                descLabel,
                DifyTextarea(
                  value: '${_param['description'] ?? ''}',
                  semanticLabel: descLabel,
                  verticalPadding: 6,
                  placeholder: _w('$_p.addExtractParameterContent.descriptionPlaceholder'),
                  onChanged: (v) => _change('description', v),
                ),
              ),
              _field(
                _w('$_p.addExtractParameterContent.required'),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        _w('$_p.addExtractParameterContent.requiredContent'),
                        style: difyTextStyle(DifyTw.textXsLeading18, DifyColors.textTertiary),
                      ),
                    ),
                    DifySwitch(
                      size: DifySwitchSize.lg,
                      checked: _param['required'] == true,
                      semanticLabel: _w('$_p.addExtractParameterContent.required'),
                      onCheckedChange: (v) => _change('required', v),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                SizedBox(
                  width: 95,
                  child: DifyButton(
                    onPressed: widget.onCancel,
                    child: Center(child: Text(_c('operation.cancel'))),
                  ),
                ),
                SizedBox(
                  width: 95,
                  child: DifyButton(
                    variant: DifyButtonVariant.primary,
                    onPressed: _save,
                    child: Center(child: Text(_c(widget.isAdd ? 'operation.add' : 'operation.save'))),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- import-from-tool.tsx ----------------------------------------------------------------------------------------

/// ImportFromTool: the ghost "Import from tools" button opening the tool picker (bottom-end); a chosen tool's `llm`
/// parameters replace the list.
class ImportFromTool extends StatelessWidget {
  const ImportFromTool({super.key, required this.onImport, this.language = 'en_US'});
  final ValueChanged<List<Json>> onImport;
  final String language;

  @override
  Widget build(BuildContext context) => ToolPicker(
    placement: DifyPlacement.bottomEnd,
    sideOffset: 4,
    alignOffset: 52,
    language: language,
    onSelect: (t) => onImport(toolParamsToExtractParams(jsList(t.tool['parameters']), language)),
    trigger: (context, c) => DifyButton(
      variant: DifyButtonVariant.ghost,
      size: DifyButtonSize.small,
      onPressed: c.toggle,
      child: Text(_w('$_p.importFromTool'), style: TextStyle(color: DifyColors.textTertiary)),
    ),
  );
}

// ---- reasoning-mode-picker.tsx -----------------------------------------------------------------------------------

/// ReasoningModePicker: "Reasoning Mode" with its tip over the Function/Tool Calling and Prompt option cards.
class ReasoningModePicker extends StatelessWidget {
  const ReasoningModePicker({super.key, required this.type, required this.onChange});
  final String? type;
  final ValueChanged<String> onChange;

  @override
  Widget build(BuildContext context) => Field(
    title: _w('$_p.reasoningMode'),
    tooltip: _w('$_p.reasoningModeTip'),
    child: Row(
      spacing: 4,
      children: [
        Expanded(
          child: OptionCard(
            title: _w('$_p.reasoningModeFunctionToolCalling'),
            selected: type == 'function_call',
            onSelect: () => onChange('function_call'),
          ),
        ),
        Expanded(
          child: OptionCard(
            title: _w('$_p.reasoningModePrompt'),
            selected: type == 'prompt',
            onSelect: () => onChange('prompt'),
          ),
        ),
      ],
    ),
  );
}

/// The parameters of [data] (`parameters || []`).
List<Json> paramsOf(Json data) => [for (final p in jsList(data['parameters'])) jsMap(p)];
