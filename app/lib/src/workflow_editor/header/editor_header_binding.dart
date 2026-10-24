import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';

import '../../editor/editor_controller.dart';
import '../store/workflow_store.dart';
import 'checklist/use_checklist.dart' as checklist;
import 'graph_facts.dart';
import 'header_data.dart';

/// dify-sf's side of the header: what Dify reads from its draft-sync hooks and stores, taken from the collaborative
/// session behind an [EditorController].
///
/// * "Auto-Saved HH:mm:ss" ([WorkflowStore.draftUpdatedAt]) is when the server last acknowledged one of our edits
///   (initially, when the document first loaded); "Syncing data…" ([WorkflowStore.isSyncingWorkflowDraft]) shows
///   for sustained unacknowledged edits. Brief per-operation acknowledgements must not flash the header.
/// * [graph] holds the nodes and the checklist (Dify's useChecklist over the document, also mirrored to the store's
///   `checklistItems`), recomputed when the document changes.
/// * [syncWorkflowDraft] is Dify's draft-save barrier before publishing: it waits until every edit is acknowledged.
class EditorHeaderBinding {
  EditorHeaderBinding({required this.controller, required this.store, checklist.ChecklistEnv Function()? checklistEnv})
    : _env = checklistEnv ?? checklist.ChecklistEnv.new {
    controller.addListener(_update);
    _events = controller.session.events.listen((e) {
      if (e is OpCommitted) _saved();
    });
    _update();
  }

  final EditorController controller;
  final WorkflowStore store;
  final checklist.ChecklistEnv Function() _env;
  late final StreamSubscription<ClientEvent> _events;

  final graph = ValueNotifier(WorkflowGraphFacts.empty);
  Document? _doc;
  final _idle = <Completer<bool>>[];
  Timer? _showSync, _hideSync;

  // Presentation only: the save barrier below always reads the actual pending operations.
  // A fast acknowledgement stays silent; short gaps in a longer transfer keep one stable status.
  void _syncPresentation(bool pending) {
    if (pending) {
      _hideSync?.cancel();
      _hideSync = null;
      if (!store.isSyncingWorkflowDraft.value && _showSync == null) {
        _showSync = Timer(const Duration(milliseconds: 500), () {
          _showSync = null;
          if (controller.status.pending > 0) store.setIsSyncingWorkflowDraft(true);
        });
      }
    } else {
      _showSync?.cancel();
      _showSync = null;
      if (store.isSyncingWorkflowDraft.value && _hideSync == null) {
        _hideSync = Timer(const Duration(milliseconds: 250), () {
          _hideSync = null;
          if (controller.status.pending == 0) store.setIsSyncingWorkflowDraft(false);
        });
      }
    }
  }

  // QA fixture only: keep the saved label deterministic without changing the
  // browser clock, which also drives Dart timers. Normal builds use real time.
  void _saved() => store.setDraftUpdatedAt(
    (const bool.fromEnvironment('VISUAL_FIXED_SAVE_TIME') ? DateTime.utc(2026, 10, 24) : DateTime.now())
            .millisecondsSinceEpoch ~/
        1000,
  );

  void _update() {
    if (!controller.ready) return;
    if (store.draftUpdatedAt.value == 0) _saved();
    final pending = controller.status.pending > 0;
    _syncPresentation(pending);
    if (!pending) {
      for (final c in _idle) {
        c.complete(true);
      }
      _idle.clear();
    }
    final doc = controller.doc;
    if (identical(doc, _doc)) return;
    _doc = doc;
    final items = checklist.computeChecklist(doc, _env());
    checklist.syncChecklistItems(store, items);
    graph.value = graphFactsOf(doc, checklist: items);
  }

  /// Recomputes the checklist after its environment changed (the app metadata arrived).
  void refreshChecklist() {
    _doc = null;
    _update();
  }

  /// Dify's `handleSyncWorkflowDraft(true)` before publishing: true once all our edits are saved, false when they are
  /// not within [timeout].
  Future<bool> syncWorkflowDraft({Duration timeout = const Duration(seconds: 15)}) {
    if (controller.ready && controller.status.pending == 0) return Future.value(true);
    final c = Completer<bool>();
    _idle.add(c);
    return c.future.timeout(
      timeout,
      onTimeout: () {
        _idle.remove(c);
        return false;
      },
    );
  }

  /// Dify's `handleCheckBeforePublish`: false (after toasting why) when the workflow can't be published.
  Future<bool> checkBeforePublish(HeaderToast? toast) async {
    final message = checklist.checkBeforePublish(controller.doc, _env());
    if (message == null) return true;
    toast?.call(HeaderToastType.error, message);
    return false;
  }

  /// useNodesInteractions' handleNodeSelect: selects the node, or clears the selection with [cancelSelection].
  void selectNode(String nodeId, {bool cancelSelection = false}) =>
      controller.selectNode(cancelSelection ? null : nodeId);

  void cancelSelection() => controller.selectNode(null);

  void dispose() {
    _showSync?.cancel();
    _hideSync?.cancel();
    controller.removeListener(_update);
    unawaited(_events.cancel());
    for (final c in _idle) {
      c.complete(false);
    }
    graph.dispose();
  }
}
