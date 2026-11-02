/// Tells an editor panel that it shows in a phone bottom sheet (dify-sf, compact windows): the phone editor's sheets
/// put the variable panels, the version list, the comment list, variable inspect and the run panels in sheets instead
/// of the desktop's right panel row (raft-flutter's presented content builds per form the same way).
library;

import 'package:flutter/widgets.dart';

/// Above a panel shown in a phone sheet. The panel leaves out its desktop frame (fixed width, rounded left edge,
/// border, shadow, resize handle) and its own title row: it shows its title and header actions in a
/// `DifySheetHeader` whose close button calls [onClose] (what the panel's close does in that sheet).
class PanelSheetScope extends InheritedWidget {
  const PanelSheetScope({super.key, required this.onClose, required super.child});

  /// Closes the sheet the panel is in.
  final VoidCallback onClose;

  /// The scope of the sheet [context]'s panel is in; null on the desktop (and in a phone's full-area panel).
  static PanelSheetScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PanelSheetScope>();

  @override
  bool updateShouldNotify(PanelSheetScope oldWidget) => false;
}
