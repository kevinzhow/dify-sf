/// What the core node panels share: the host's data and services ([CorePanelHost]), typed-text bases
/// ([TypingBase]) and the variable-usage helpers of hooks/use-workflow.ts. Writes (`PanelInputs`) and the variable
/// scope (`NodeVars`) are the shared `node_panel/panel_edit.dart`'s.
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../../../design/css_metrics.dart';
import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../editor/editor_controller.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../../workflow/var_types.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../panel_edit.dart' show writeNodeConfig;

String tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String tc(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('common', key, params);

// ---- the host ----------------------------------------------------------------------------------------------------

/// Builds the code generator button of the Code panel's editor (Dify's CodeGeneratorButton); [onGenerated] takes
/// the generated code.
typedef CodeGeneratorBuilder = Widget Function(
  BuildContext context,
  String nodeId,
  String language,
  ValueChanged<String> onGenerated,
);

/// What the core panels need from the app that the document does not hold: Dify's toast, the backend's node
/// default configs (`nodesDefaultConfigs`, `fetchNodeDefault` per code language), the file upload limits, the
/// code generator. Everything has a working default.
@immutable
class CorePanelHostData {
  const CorePanelHostData({
    this.toastError = difyToastError,
    this.nodesDefaultConfigs = builtinNodesDefaultConfigs,
    this.codeLanguageDefaults = builtinCodeLanguageDefaults,
    this.workflowFileUploadLimit = 10,
    this.codeGenerator,
  });

  /// `toast.error(message)`; the app's toast host by default (null: errors are not shown).
  final ValueChanged<String>? toastError;

  /// `GET /apps/{id}/workflows/default-workflow-block-configs`, by node type.
  final Map<String, Map<String, Object?>> nodesDefaultConfigs;

  /// `.../default-workflow-block-configs/code?q={"code_language": ...}`, by language.
  final Map<String, Map<String, Object?>> codeLanguageDefaults;

  /// `fileUploadConfig.workflow_file_upload_limit`.
  final int workflowFileUploadLimit;
  final CodeGeneratorBuilder? codeGenerator;
}

/// The backend's code defaults (api/core/helper/code_executor/*_code_provider.py).
const builtinCodeLanguageDefaults = <String, Map<String, Object?>>{
  'python3': {
    'code_language': 'python3',
    'code': 'def main(arg1: str, arg2: str):\n    return {\n        "result": arg1 + arg2,\n    }\n',
    'variables': [
      {'variable': 'arg1', 'value_selector': <Object?>[]},
      {'variable': 'arg2', 'value_selector': <Object?>[]},
    ],
    'outputs': {
      'result': {'type': 'string', 'children': null},
    },
  },
  'javascript': {
    'code_language': 'javascript',
    'code': 'function main({arg1, arg2}) {\n    return {\n        result: arg1 + arg2\n    }\n}\n',
    'variables': [
      {'variable': 'arg1', 'value_selector': <Object?>[]},
      {'variable': 'arg2', 'value_selector': <Object?>[]},
    ],
    'outputs': {
      'result': {'type': 'string', 'children': null},
    },
  },
};

/// The backend's `default-workflow-block-configs` for the core nodes.
const builtinNodesDefaultConfigs = <String, Map<String, Object?>>{
  'code': {
    'code_language': 'python3',
    'code': 'def main(arg1: str, arg2: str):\n    return {\n        "result": arg1 + arg2,\n    }\n',
    'variables': [
      {'variable': 'arg1', 'value_selector': <Object?>[]},
      {'variable': 'arg2', 'value_selector': <Object?>[]},
    ],
    'outputs': {
      'result': {'type': 'string', 'children': null},
    },
  },
  'template-transform': {
    'template': '{{ arg1 }}',
    'variables': [
      {'variable': 'arg1', 'value_selector': <Object?>[]},
    ],
  },
};

/// Provides [data] to the core panels below.
class CorePanelHost extends InheritedWidget {
  const CorePanelHost({super.key, required this.data, required super.child});
  final CorePanelHostData data;

  static CorePanelHostData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CorePanelHost>()?.data ?? const CorePanelHostData();

  @override
  bool updateShouldNotify(CorePanelHost old) => old.data != data;
}

// ---- typed text --------------------------------------------------------------------------------------------------

/// The document version a burst of typing into one field began on (each keystroke is written at once, with this
/// base): taken at the first keystroke, kept while keystrokes come less than a second apart.
class TypingBase {
  TypingBase(this.currentVersion);
  final int Function() currentVersion;
  int? _base;
  DateTime _last = DateTime(0);

  int call() {
    final now = DateTime.now();
    if (_base == null || now.difference(_last) > const Duration(seconds: 1)) _base = currentVersion();
    _last = now;
    return _base!;
  }
}

// ---- value selectors ---------------------------------------------------------------------------------------------

/// The value selector at `data[key]` (plain JSON) as strings; empty when unset.
List<String> selectorList(Object? v) => [for (final e in jsList(v)) jsKey(e)];

// ---- hooks/use-workflow.ts ---------------------------------------------------------------------------------------

/// `getAfterNodesInSameBranch`: [nodeId] and every node downstream of it.
List<Node> afterNodesInSameBranch(Document doc, String nodeId) {
  final current = doc.nodes[nodeId];
  if (current == null) return const [];
  final seen = <String>{nodeId};
  final list = [current];
  void traverse(String id) {
    for (final e in doc.edges.values) {
      if (e.source != id) continue;
      final n = doc.nodes[e.target];
      if (n == null || !seen.add(n.id)) continue;
      list.add(n);
      traverse(n.id);
    }
  }

  traverse(nodeId);
  return list;
}

/// `findUsedVarNodes`.
List<Node> findUsedVarNodes(List<String> selector, Iterable<Node> nodes) {
  final key = selector.join('.');
  return [
    for (final n in nodes)
      if (_usedVars(n).any((v) => v.join('.') == key)) n,
  ];
}

List<List<String>> _usedVars(Node n) {
  try {
    return getNodeUsedVars(n);
  } on StateError {
    return const [];
  }
}

/// `isVarUsedInNodes`.
bool isVarUsedInNodes(EditorController c, List<String> selector) =>
    findUsedVarNodes(selector, afterNodesInSameBranch(c.doc, selector.first)).isNotEmpty;

/// `removeUsedVarInNodes`: the downstream uses of [selector] are cleared.
void removeUsedVarInNodes(EditorController c, List<String> selector) {
  for (final n in findUsedVarNodes(selector, afterNodesInSameBranch(c.doc, selector.first))) {
    _rewrite(c, n, selector, const []);
  }
}

/// `handleOutVarRenameChange`: every use of [oldSelector] in the workflow now names [newSelector].
void handleOutVarRenameChange(EditorController c, List<String> oldSelector, List<String> newSelector) {
  for (final n in findUsedVarNodes(oldSelector, c.doc.nodes.values)) {
    _rewrite(c, n, oldSelector, newSelector);
  }
}

void _rewrite(EditorController c, Node n, List<String> oldSelector, List<String> newSelector) {
  try {
    writeNodeConfig(c, n, updateNodeVars(n, oldSelector, newSelector));
  } on StateError {
    // Dify's code would throw on this node's data; leave it.
  }
}

// ---- small widgets -----------------------------------------------------------------------------------------------

/// The `+` of a Field's operations (`cursor-pointer rounded-md p-1 hover:bg-state-base-hover`, `i-ri-add-line size-4
/// text-text-tertiary`), named "Add `field`".
///
/// [alone]: the button is all of the operations (Field's `<div>{operations}</div>`), so, an inline-block, it stands
/// on that block's text line, which ends [Css.inlineButtonLineGap] below it. In a flex row (not [alone]) it does not.
class FieldAddButton extends StatelessWidget {
  const FieldAddButton({super.key, required this.label, required this.onPressed, this.alone = true});
  final String label;
  final VoidCallback onPressed;
  final bool alone;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: alone ? Css.inlineButtonLineGap : 0),
    child: DifyPressable(
      semanticLabel: label,
      onPressed: onPressed,
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: hovered ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
          border: focused ? Border.all(color: DifyColors.componentsInputBorderActive) : null,
        ),
        child: const RemixIcon('add-line', size: 16, color: DifyColors.textTertiary),
      ),
    ),
  );
}

/// RemoveEffectVarConfirm (remove-effect-var-confirm.tsx): the "Remove Variable" alert dialog over the screen.
Future<void> showRemoveEffectVarConfirm(
  BuildContext context, {
  required VoidCallback onConfirm,
  VoidCallback? onCancel,
}) async {
  final ok = await showDifyConfirm(
    context,
    title: tw('common.effectVarConfirm.title'),
    content: tw('common.effectVarConfirm.content'),
  );
  (ok ? onConfirm : onCancel)?.call();
}

/// dify-ui's AlertDialog with Cancel / Confirm (`w-120 rounded-2xl p-6`, title `title-2xl-semi-bold`, content
/// `system-md-regular text-text-tertiary`, actions right aligned): true when confirmed.
Future<bool> showDifyConfirm(BuildContext context, {required String title, String? content}) async {
  final overlay = Overlay.of(context, rootOverlay: true);
  final done = Completer<bool>();
  late final OverlayEntry entry;
  void close(bool v) {
    entry.remove();
    done.complete(v);
  }

  entry = OverlayEntry(
    builder: (context) => _ConfirmDialog(title: title, content: content, onClose: close),
  );
  overlay.insert(entry);
  return done.future;
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({required this.title, required this.content, required this.onClose});
  final String title;
  final String? content;
  final ValueChanged<bool> onClose;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: GestureDetector(
          onTap: () => onClose(false),
          child: const ColoredBox(color: DifyColors.backgroundOverlay),
        ),
      ),
      Center(
        child: Container(
          width: 480,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: DifyColors.componentsPanelBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
            boxShadow: DifyShadows.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: difyTextStyle(DifyType.title2xlSemiBold, DifyColors.textPrimary)),
              if (content != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(content!, style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textTertiary)),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    DifyButton(onPressed: () => onClose(false), child: Text(tc('operation.cancel'))),
                    DifyButton(
                      variant: DifyButtonVariant.primary,
                      tone: DifyButtonTone.destructive,
                      onPressed: () => onClose(true),
                      child: Text(tc('operation.confirm')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

// ---- variable lists (Dify's `Variable[]`) ------------------------------------------------------------------------

/// The rows of a [VarList] for Dify's `Variable[]` [list]; each row's id is its index in [list].
List<VarListItem> varListItemsOf(Object? list) => [
  for (final (i, v) in jsList(list).indexed)
    VarListItem(
      variable: jsStr(jsGet(v, 'variable')) ?? '',
      valueSelector: selectorList(jsGet(v, 'value_selector')),
      valueType: jsStr(jsGet(v, 'value_type')),
      variableType: switch (jsGet(v, 'variable_type')) {
        'constant' => VarKindType.constant,
        'variable' => VarKindType.variable,
        _ => null,
      },
      value: jsStr(jsGet(v, 'value')),
      id: '$i',
    ),
];

/// [rows] back as Dify's `Variable[]`, each over the variable of [list] it came from (its other fields kept).
List<Map<String, Object?>> varListDataOf(List<VarListItem> rows, Object? list) {
  final orig = jsList(list);
  return [
    for (final r in rows)
      () {
        final i = int.tryParse(r.id ?? '');
        final o = i != null && i < orig.length && orig[i] is Map ? (orig[i]! as Map).cast<String, Object?>() : null;
        final m = {...?o, 'variable': r.variable, 'value_selector': r.valueSelector};
        if (r.valueType != null) {
          m['value_type'] = r.valueType;
        } else if (!jsonEquals(o?['value_selector'], r.valueSelector)) {
          m.remove('value_type');
        }
        if (r.variableType != null) m['variable_type'] = r.variableType!.name;
        if (r.value != null) m['value'] = r.value;
        return m;
      }(),
  ];
}
