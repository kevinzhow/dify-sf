/// The workflow editor on a phone (dify-sf, compact windows; Dify's editor has no phone mode): the state the phone
/// chrome keeps besides the document and the canvas, and the scopes that tell the editor's parts that they are laid
/// out for a phone.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../design/widgets/widgets.dart';
import '../store/workflow_store.dart' show WorkflowContextMenuTarget;

/// The phone editor's two presentations of the one document.
enum PhoneEditorView {
  /// The Steps list (the phone's main editing surface).
  steps,

  /// The canvas.
  canvas,
}

/// What the phone chrome remembers: the view (per app, stored like the editor's other preferences; Steps by default),
/// whether the canvas is in select mode, and whose settings panel is open. The canvas and the document keep the rest
/// (the selection, the run, the panels' store flags).
class PhoneEditorController extends ChangeNotifier {
  PhoneEditorController({required this.docId, Future<SharedPreferences>? preferences}) {
    unawaited(_load(preferences ?? SharedPreferences.getInstance()));
  }

  /// The app (document) the view is stored for.
  final String docId;

  /// The stored view's key: `dify-sf-phone-editor-view:<app id>`, `steps` or `canvas`.
  static String storageKey(String docId) => 'dify-sf-phone-editor-view:$docId';

  PhoneEditorView _view = PhoneEditorView.steps;

  /// The Steps view's "add at the end of the flow" while it shows (it registers itself); the toolbar's Add uses it
  /// when no step is selected.
  Future<bool> Function()? stepsAddAtEnd;

  /// The Steps view's reveal while it shows (it registers itself): the node settings sheet asks it to bring step
  /// [nodeId] above the window's y [coveredFromY] (the sheet's top at half).
  void Function(String nodeId, double coveredFromY)? stepsReveal;
  bool _viewChosen = false, _disposed = false;
  Future<SharedPreferences>? _prefs;

  PhoneEditorView get view => _view;

  /// Shows [value] and stores it for this app.
  set view(PhoneEditorView value) {
    _viewChosen = true;
    if (value == _view) return;
    _view = value;
    notifyListeners();
    unawaited(
      _prefs?.then((p) => p.setString(storageKey(docId), value.name), onError: (Object _) => false),
    );
  }

  Future<void> _load(Future<SharedPreferences> preferences) async {
    _prefs = preferences;
    try {
      final stored = (await preferences).getString(storageKey(docId));
      if (_disposed || _viewChosen) return;
      final view = PhoneEditorView.values.where((v) => v.name == stored).firstOrNull;
      if (view != null && view != _view) {
        _view = view;
        notifyListeners();
      }
    } on Object {
      // No preferences (some test hosts): Steps.
    }
  }

  bool _selectMode = false;

  /// Select mode: one finger on the canvas draws a selection box (pan mode otherwise).
  bool get selectMode => _selectMode;
  set selectMode(bool value) {
    if (value == _selectMode) return;
    _selectMode = value;
    notifyListeners();
  }

  String? _settingsNodeId;

  /// The node whose settings panel is open (null: none). Selecting a node on the phone shows its selection bar; its
  /// panel opens only through [openSettings].
  String? get settingsNodeId => _settingsNodeId;

  void openSettings(String nodeId) {
    if (_settingsNodeId == nodeId) return;
    _settingsNodeId = nodeId;
    notifyListeners();
  }

  void closeSettings() {
    if (_settingsNodeId == null) return;
    _settingsNodeId = null;
    notifyListeners();
  }

  /// A long press on the canvas (what is under the finger, and where on the canvas): the phone chrome opens an action
  /// sheet instead of the desktop context menu. Set by the phone chrome while it is shown.
  void Function(WorkflowContextMenuTarget target, Offset canvasPoint)? onCanvasLongPress;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Marks the workflow editor's subtree as laid out for a phone and hands it the [PhoneEditorController]. The editor's
/// parts (the panels, the canvas "+" buttons, the context menus) behave the desktop way where there is none.
class PhoneEditorScope extends InheritedNotifier<PhoneEditorController> {
  const PhoneEditorScope({super.key, required PhoneEditorController controller, required super.child})
    : super(notifier: controller);

  /// The phone editor's controller, rebuilding [context] when it changes; null outside a phone layout.
  static PhoneEditorController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PhoneEditorScope>()?.notifier;

  /// The same without a dependency (for event handlers).
  static PhoneEditorController? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PhoneEditorScope>()?.notifier;
}

/// Actions the page around the editor adds to the phone editor's overflow menu (the app detail page: its other pages
/// and the app's own operations), after the editor's own.
class PhoneEditorHostActions extends InheritedWidget {
  const PhoneEditorHostActions({super.key, required this.actions, required super.child});

  /// Built when the menu opens, so they reflect the app at that moment.
  final List<DifyActionSheetAction> Function() actions;

  static List<DifyActionSheetAction> of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PhoneEditorHostActions>()?.actions() ?? const [];

  @override
  bool updateShouldNotify(PhoneEditorHostActions oldWidget) => false;
}

/// What the workflow editor hands its phone layout: the canvas with its layers (the "+" buttons, the comments, the
/// presence, the selected note's editor, ...), the panels, the modal layer (the Features drawer, the DSL import) and
/// the confirm dialog layer. The layout places them; the canvas keeps its state when the window switches between the
/// phone and the desktop layouts.
@immutable
class PhoneEditorBody {
  const PhoneEditorBody({required this.canvas, required this.confirm, this.panels, this.modal});

  final Widget canvas;
  final Widget? panels;
  final Widget? modal;
  final Widget confirm;
}
