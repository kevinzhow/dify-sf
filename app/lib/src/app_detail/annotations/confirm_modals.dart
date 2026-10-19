/// remove-annotation-confirm-modal and clear-all-annotations-confirm-modal: AlertDialogs with Cancel and Confirm.
library;

import 'package:flutter/widgets.dart';

import '../../i18n/dify_i18n.dart';
import 'annotation_overlays.dart';

/// RemoveAnnotationConfirmModal: "Remove annotation?" (`appDebug` `feature.annotation.removeConfirm`).
class RemoveAnnotationConfirmModal extends StatelessWidget {
  const RemoveAnnotationConfirmModal({super.key, required this.isShow, required this.onHide, required this.onRemove});

  final bool isShow;
  final VoidCallback onHide, onRemove;

  @override
  Widget build(BuildContext context) => AnnotationAlertDialog(
    open: isShow,
    title: DifyI18n.tr('appDebug', 'feature.annotation.removeConfirm'),
    onCancel: onHide,
    onConfirm: onRemove,
  );
}

/// ClearAllAnnotationsConfirmModal: "Delete all annotations?" (`table.header.clearAllConfirm`).
class ClearAllAnnotationsConfirmModal extends StatelessWidget {
  const ClearAllAnnotationsConfirmModal({
    super.key,
    required this.isShow,
    required this.onHide,
    required this.onConfirm,
  });

  final bool isShow;
  final VoidCallback onHide, onConfirm;

  @override
  Widget build(BuildContext context) => AnnotationAlertDialog(
    open: isShow,
    title: DifyI18n.tr('appAnnotation', 'table.header.clearAllConfirm'),
    onCancel: onHide,
    onConfirm: onConfirm,
  );
}
