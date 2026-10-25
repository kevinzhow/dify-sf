import 'package:collab_client/collab_client.dart';

import '../workflow/dify_json.dart' show plainOf;

import '../workflow_editor/header/checklist/use_checklist.dart';

/// The editor's rules over one atomic server snapshot. No DSL re-import and no
/// collaborative client registration or write is needed for either tool.
typedef DraftSnapshot = ({int seq, Document doc, String mode});
typedef CheckContext = ({ChecklistEnv env, List<String> unavailable});

class ReadonlyWorkflowReader {
  ReadonlyWorkflowReader({required this.snapshot, required this.context});
  final Future<DraftSnapshot> Function(String id) snapshot;
  final Future<CheckContext> Function(String appId, Document doc, String mode) context;

  Future<Map<String, Object?>> read(String id, {int? expectedRevision, bool check = false}) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) throw const FormatException('invalid_workflow_id');
    final draft = await snapshot(id);
    if (expectedRevision != null && expectedRevision != draft.seq) {
      return {'workflow_id': id, 'draft_revision': draft.seq, 'complete': false, 'error': 'revision_changed'};
    }
    if (!check) {
      // Same graph projection as the editor; never include session or catalog credentials.
      final graph = difyGraphOf(draft.doc);
      return {
        'workflow_id': id,
        'draft_revision': draft.seq,
        'complete': true,
        'mode': draft.mode,
        'nodes': [
          for (final n in graph.nodes)
            {
              ...?(plainOf(n.node?.config['_dify_node']) as Map<String, Object?>?),
              'id': n.id,
              'type': n.type,
              'parentId': ?n.parentId,
              'position': {'x': n.node!.x, 'y': n.node!.y},
              'data': n.data,
            },
        ],
        'edges': [
          for (final e in draft.doc.edges.values)
            {
              'id': e.id,
              'source': e.source,
              'target': e.target,
              'sourceHandle': e.sourceHandle,
              'targetHandle': e.targetHandle,
            },
        ],
        'document': draft.doc.toJson(),
        'features': AppRegisters.featuresOf(draft.doc),
        'environment_variables': AppRegisters.variables(draft.doc, AppRegisters.environmentVariables),
        'conversation_variables': AppRegisters.variables(draft.doc, AppRegisters.conversationVariables),
      };
    }
    final loaded = await context(id, draft.doc, draft.mode);
    final items = computeChecklist(draft.doc, loaded.env);
    final publishError = checkBeforePublish(draft.doc, loaded.env);
    final complete = loaded.unavailable.isEmpty;
    return {
      'workflow_id': id,
      'draft_revision': draft.seq,
      'complete': complete,
      'unavailable_context': loaded.unavailable,
      'warning_count': complete ? items.length : null,
      if (!complete) 'partial_warning_count': items.length,
      'items': [for (final item in items) item.toJson()],
      // An incomplete check can never authorize the import/publish gate.
      'gate_passed': complete && items.isEmpty && publishError == null,
      'publish_error': publishError,
      'rules': 'dify-sf/editor-checklist',
    };
  }
}
