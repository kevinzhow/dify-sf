// dify-spec: web/app/components/app/app-publisher/__tests__/version-info-modal.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/header/publisher/summary_section.dart';
import 'package:dify_sf_app/src/workflow_editor/header/publisher/version_info_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// `render(<VersionInfoModal isOpen …/>)`: the dialog opened over an empty page.
Future<void> _open(
  WidgetTester t, {
  PublishedWorkflowInfo? versionInfo,
  ValueChanged<VersionInfoUpdate>? onPublish,
  VoidCallback? onClose,
  PublisherToast? onToast,
}) async {
  late BuildContext context;
  await render(
    t,
    Builder(
      builder: (c) {
        context = c;
        return const SizedBox();
      },
    ),
  );
  showVersionInfoModal(
    context,
    versionInfo: versionInfo,
    onPublish: onPublish ?? (_) {},
    onClose: onClose,
    onToast: onToast,
  );
  await t.pumpAndSettle();
}

final _textboxes = find.byType(EditableText);

Future<void> _save(WidgetTester t) async {
  await t.tap(find.text('common.operation.save'));
  await t.pumpAndSettle();
}

void main() {
  setUp(useDifyTestTranslator);

  group('VersionInfoModal', () {
    testWidgets('should prefill the fields from the current version info', (t) async {
      await _open(
        t,
        versionInfo: const PublishedWorkflowInfo(
          id: 'version-1',
          createdAt: 0,
          markedName: 'Release 1',
          markedComment: 'Initial release',
        ),
      );
      expect(find.text('Release 1'), findsOneWidget);
      expect(find.text('Initial release'), findsOneWidget);
    });

    testWidgets('should reject overlong titles', (t) async {
      final toasts = <(PublisherToastType, String)>[];
      final published = <VersionInfoUpdate>[];
      await _open(t, onPublish: published.add, onToast: (type, m) => toasts.add((type, m)));
      await t.enterText(_textboxes.first, 'a' * 16);
      await _save(t);
      expect(toasts.single.$1, PublisherToastType.error);
      expect(toasts.single.$2, startsWith('workflow.versionHistory.editField.titleLengthLimit'));
      expect(published, isEmpty);
    });

    testWidgets('should publish valid values and close the modal', (t) async {
      final published = <VersionInfoUpdate>[];
      var closes = 0;
      await _open(
        t,
        versionInfo: const PublishedWorkflowInfo(
          id: 'version-2',
          createdAt: 0,
          markedName: 'Old title',
          markedComment: 'Old notes',
        ),
        onPublish: published.add,
        onClose: () => closes++,
      );
      await t.enterText(_textboxes.at(0), 'Release 2');
      await t.enterText(_textboxes.at(1), 'Updated notes');
      await _save(t);
      expect(published, [(title: 'Release 2', releaseNotes: 'Updated notes', id: 'version-2')]);
      expect(closes, 1);
    });

    testWidgets('should close when the dialog requests close', (t) async {
      var closes = 0;
      await _open(t, onClose: () => closes++);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(closes, 1);
    });

    testWidgets('should close when the close button is clicked', (t) async {
      final semantics = t.ensureSemantics();
      var closes = 0;
      await _open(t, onClose: () => closes++);
      expect(isButton(named('common.operation.close')), isTrue);
      await t.tap(find.bySemanticsLabel('common.operation.close'));
      await t.pumpAndSettle();
      expect(closes, 1);
      semantics.dispose();
    });

    testWidgets('should validate release note length and clear previous errors before publishing', (t) async {
      final toasts = <String>[];
      final published = <VersionInfoUpdate>[];
      var closes = 0;
      await _open(
        t,
        versionInfo: const PublishedWorkflowInfo(
          id: 'version-3',
          createdAt: 0,
          markedName: 'Old title',
          markedComment: 'Old notes',
        ),
        onPublish: published.add,
        onClose: () => closes++,
        onToast: (_, m) => toasts.add(m),
      );
      await t.enterText(_textboxes.at(0), 'a' * 16);
      await _save(t);
      expect(toasts.last, startsWith('workflow.versionHistory.editField.titleLengthLimit'));

      await t.enterText(_textboxes.at(0), 'Release 3');
      await t.enterText(_textboxes.at(1), 'b' * 101);
      await _save(t);
      expect(toasts.last, startsWith('workflow.versionHistory.editField.releaseNotesLengthLimit'));

      await t.enterText(_textboxes.at(1), 'Stable release notes');
      await _save(t);
      expect(published, [(title: 'Release 3', releaseNotes: 'Stable release notes', id: 'version-3')]);
      expect(closes, 1);
    });
  });
}
