/// What the model-node panels (LLM, Question Classifier, Parameter Extractor, Knowledge Retrieval, Agent) share: the
/// variable filters of their pickers and small JSON readers. Writes and the variable scope are the shared
/// `node_panel/panel_edit.dart`'s.
library;

import '../../../../workflow/dify_json.dart';
import '../../../../workflow/var_types.dart';
import '../../../panel_fields/node_config.dart' show Json;
import '../../../panel_fields/var_picker_model.dart';

/// `x` as a JSON object (an empty one for anything else).
Json jsMap(Object? x) => x is Map<String, Object?> ? x : (x is Map ? x.cast<String, Object?>() : const {});

/// `x` as a list of strings (a value selector).
List<String> jsSelector(Object? x) => [for (final e in jsList(x)) jsKey(e)];

// ---- filters (llm/panel.tsx, utils) ------------------------------------------------------------------------------

bool _typeIn(PickerVar v, Set<String> types) => types.contains(v.type);

/// `filterInputVar` (LLM prompt).
bool filterInputVar(PickerVar v, List<String> _) => _typeIn(v, const {
  VarType.number,
  VarType.string,
  VarType.secret,
  VarType.arrayString,
  VarType.arrayNumber,
  VarType.file,
  VarType.arrayFile,
});

/// `filterJinja2InputVar`.
bool filterJinja2InputVar(PickerVar v, List<String> _) => _typeIn(v, const {
  VarType.number,
  VarType.string,
  VarType.secret,
  VarType.arrayString,
  VarType.arrayNumber,
  VarType.arrayBoolean,
  VarType.arrayObject,
  VarType.object,
  VarType.array,
  VarType.boolean,
});

/// `filterMemoryPromptVar` (the LLM context, the agent's variables).
bool filterMemoryPromptVar(PickerVar v, List<String> _) => _typeIn(v, const {
  VarType.arrayObject,
  VarType.array,
  VarType.number,
  VarType.string,
  VarType.secret,
  VarType.arrayString,
  VarType.arrayNumber,
  VarType.file,
  VarType.arrayFile,
});

/// `filterVar` of string-only pickers (query variables).
bool filterStringVar(PickerVar v, List<String> _) => v.type == VarType.string;

/// Number and string variables (the model parameters' and instructions' variable lists).
bool filterNumberStringVar(PickerVar v, List<String> _) => v.type == VarType.number || v.type == VarType.string;

/// `filterFileVar`.
bool filterFileVar(PickerVar v, List<String> _) => v.type == VarType.file || v.type == VarType.arrayFile;
