/// The editor's features panel (workflow/features.tsx, shown by workflow-app's workflow-children.tsx while the
/// store's `showFeaturesPanel` is on) and how its changes reach the collaborative document.
///
/// Dify keeps the panel's features in a store of their own, saves them with `updateFeatures` after each change and
/// tells the other clients to reload them. Here the document is the truth (protocol 1.7: `$app` config `features`,
/// Dify's `workflow.features`): [FeaturesDocSync] shows what the document says and writes each change as the fewest
/// nested `setConfig` ops on `$app` (only the members the change touched, based on the version the user saw), so two
/// people changing different features both keep their change. As in Dify, these edits are not workflow history.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../design/widgets/toast.dart';
import '../../editor/editor_controller.dart';
import '../../workflow/dify_json.dart';
import '../header/header_data.dart' show nodesReadOnlyListenable, nodesReadOnlyOf;
import '../node_panel/bodies/core/start_config.dart' show StartConfig;
import '../node_panel/panel_edit.dart' show writeConfigAt, writeInputs;
import '../store/store.dart';
import 'features_services.dart';
import 'features_store.dart';
import 'new_feature_panel.dart';

/// Keeps a [FeaturesStore] on the document's features ([WorkflowStore.features], which AppRegistersSync keeps) and
/// writes the store's edits back.
///
/// The store is replaced by the document's features whenever they differ from what it shows (read back the way
/// `buildInitialFeatures` reads them), so this client's own write coming back changes nothing: an opener switched on
/// before it has a statement stays on, as in Dify, until someone else's change replaces it.
class FeaturesDocSync {
  FeaturesDocSync({required this.controller, required this.store, required this.features, this.fileUploadConfig}) {
    store.features.addListener(pull);
    pull();
  }

  final EditorController controller;
  final WorkflowStore store;
  final FeaturesStore features;
  final Json? fileUploadConfig;

  /// Shows the document's features unless the store already shows them.
  void pull() {
    final doc = buildInitialFeatures(store.features.value, fileUploadConfig: fileUploadConfig);
    final shown = buildInitialFeatures(serverFeatures(features.features.value), fileUploadConfig: fileUploadConfig);
    if (!featuresEqual(doc, shown)) features.replace(doc);
  }

  /// The panel's `onChange`: writes the store's edit since the last call (nothing when there is none), member by
  /// member, based on the version on screen.
  void save([Features? _]) {
    final edit = features.takeEdit();
    if (edit == null) return;
    final from = serverFeatures(edit.from), to = serverFeatures(edit.to);
    final base = controller.seenVersion;
    for (final key in {...from.keys, ...to.keys}) {
      writeConfigAt(
        controller,
        Document.appNode,
        [AppRegisters.features, key],
        shown: from[key],
        next: to[key],
        base: base,
      );
    }
  }

  void dispose() => store.features.removeListener(pull);
}

/// workflow/features.tsx: the features drawer while the store's `showFeaturesPanel` is on, for a chatflow
/// ([isChatMode]) or a workflow, disabled while the nodes are read-only. The opener's "add variables" adds the first
/// one to the Start node as a text input. Place it over the whole editor ([WorkflowEditor.modal]).
class WorkflowFeatures extends StatefulWidget {
  const WorkflowFeatures({
    super.key,
    required this.controller,
    required this.isChatMode,
    this.services = FeaturesServices.empty,
    this.canEdit = true,
  });

  final EditorController controller;
  final bool isChatMode;
  final FeaturesServices services;
  final bool canEdit;

  @override
  State<WorkflowFeatures> createState() => _WorkflowFeaturesState();
}

class _WorkflowFeaturesState extends State<WorkflowFeatures> {
  WorkflowStore? _store;
  FeaturesStore? _features;
  FeaturesDocSync? _sync;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = WorkflowStoreScope.of(context);
    if (identical(store, _store)) return;
    _dispose();
    _store = store;
    final config = widget.services.fileUploadConfig;
    final features = _features = FeaturesStore(
      features: buildInitialFeatures(store.features.value, fileUploadConfig: config),
    );
    _sync = FeaturesDocSync(controller: widget.controller, store: store, features: features, fileUploadConfig: config);
  }

  void _dispose() {
    _sync?.dispose();
    _features?.dispose();
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }

  Node? get _start => widget.controller.doc.nodes.values.where((n) => n.type == 'start').firstOrNull;

  /// `handleAddOpeningStatementVariable`: the first variable, as a text input of the Start node.
  void _addStartVariable(List<Json> variables) {
    final v = variables.firstOrNull, start = _start;
    if (v == null || start == null) return;
    final c = widget.controller;
    StartConfig(
      id: start.id,
      inputs: () => difyDataOf(c.doc.nodes[start.id] ?? start),
      setInputs: (next) => writeInputs(c, start.id, next),
      toastError: (m) => widget.services.toast?.call(DifyToastType.error, m),
    ).handleAddVariable({
      'variable': v['key'],
      'label': v['name'],
      'type': 'text-input',
      'max_length': ?v['max_length'],
      'required': v['required'] ?? false,
      'options': const <Object?>[],
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = _store!;
    return ValueListenableBuilder(
      valueListenable: store.showFeaturesPanel,
      builder: (context, show, _) {
        if (!show) return const SizedBox.shrink();
        return FeaturesServicesScope(
          services: widget.services,
          child: FeaturesScope(
            store: _features!,
            child: ListenableBuilder(
              listenable: Listenable.merge([nodesReadOnlyListenable(store), widget.controller]),
              builder: (context, _) {
                final start = _start;
                return NewFeaturePanel(
                  show: true,
                  isChatMode: widget.isChatMode,
                  disabled: nodesReadOnlyOf(store, canEdit: widget.canEdit),
                  onChange: _sync!.save,
                  onClose: () => store.setShowFeaturesPanel(false),
                  onAutoAddPromptVariable: _addStartVariable,
                  workflowVariables: [
                    if (start != null) ...((difyDataOf(start)['variables'] as List?) ?? const []).whereType<Json>(),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}
