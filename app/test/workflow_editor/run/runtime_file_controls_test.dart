import 'dart:async';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/files/file_links.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/run_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/single_run.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_model.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/value_content.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_spec/workflow/run/run_harness.dart';

const picked = <String, Object?>{
  'uploadedId': 'actual-record-id', 'upload_file_id': 'actual-record-id',
  'transferMethod': 'local_file', 'transfer_method': 'local_file',
  'supportFileType': 'document', 'type': 'document',
  'name': 'notes.txt', 'size': 4, 'progress': 100,
};

void main() {
  testWidgets('run upload serializes attempts and recovers from failure without losing selected files', (t) async {
    final first = Completer<Map<String, Object?>?>();
    var calls = 0;
    final selected = <Map<String, Object?>>[];
    await renderRun(t, RunFilePickerScope(
      pickFile: (_) { calls++; return calls == 1 ? first.future : Future.value(picked); },
      child: RunFileInput(files: selected, limit: 2, onChange: (v) => selected.addAll(v)),
    ));
    final upload = find.byType(DifyButton).first;
    await t.tap(upload); await t.pump();
    expect(t.widget<DifyButton>(upload).disabled, isTrue);
    await t.tap(upload); await t.pump();
    expect(calls, 1);
    first.completeError(StateError('network disconnected')); await t.pumpAndSettle();
    expect(t.widget<DifyButton>(upload).disabled, isFalse);
    expect(selected, isEmpty);
    await t.tap(upload); await t.pumpAndSettle();
    expect(calls, 2); expect(selected.single['uploadedId'], 'actual-record-id');
    expect(t.takeException(), isNull);
  });

  testWidgets('generated Human Input form picks a file and preserves it across a rejected answer', (t) async {
    final submitted = <Map<String, Object?>>[];
    final definition = <String, Object?>{
      'form_content': '{{#\$output.attachment#}}',
      'inputs': [ {'type': 'file', 'output_variable_name': 'attachment', 'allowed_file_upload_methods': ['local_file']} ],
      'actions': [ {'id': 'approve', 'title': 'Approve'} ],
    };
    await renderRun(t, RunFilePickerScope(pickFile: (_) async => picked, child: HumanInputRunForm(
      nodeName: 'File approval', data: definition,
      onSubmit: (inputs, action) async {
        expect(action, 'approve');
        submitted.add(inputs);
        if (submitted.length == 1) throw StateError('retry');
      }, onError: (_) {},
    )));
    final uploader = find.descendant(of: find.byType(RunFileInput), matching: find.byType(DifyButton)).first;
    await t.tap(uploader); await t.pumpAndSettle();
    expect(find.text('notes.txt'), findsOneWidget);
    final approve = find.widgetWithText(DifyButton, 'Approve');
    await t.tap(approve); await t.pumpAndSettle();
    expect(t.widget<DifyButton>(approve).disabled, isFalse);
    expect((submitted.first['attachment'] as HumanInputFile).uploadedId, 'actual-record-id');
    expect(find.text('notes.txt'), findsOneWidget);
    await t.tap(approve); await t.pumpAndSettle();
    expect(submitted.length, 2); expect(t.takeException(), isNull);
  });

  testWidgets('inspect variable uploader reaches the same scoped picker', (t) async {
    final selected = <Map<String, Object?>>[];
    await renderRun(t, RunFilePickerScope(pickFile: (_) async => picked,
      child: FileEditorSection(currentVar: const {'value_type': 'file'}, fileValue: const [], textEditorDisabled: false,
        onChange: (v) => selected.addAll(v))));
    await t.tap(find.byType(DifyButton).first); await t.pumpAndSettle();
    expect(selected.single['uploadedId'], 'actual-record-id');
  });

  testWidgets('file result opens its signed preview and blocks executable URLs', (t) async {
    final opened = <String>[];
    await renderRun(t, RunFileList(files: const [
      {'name': 'ready.png', 'url': 'https://files.test/files/id/file-preview?timestamp=1&sign=x'},
      {'name': 'unsafe.txt', 'url': 'javascript:alert(1)'},
    ], onOpen: opened.add));
    await t.tap(find.text('ready.png')); await t.pump();
    expect(opened, ['https://files.test/files/id/file-preview?timestamp=1&sign=x']);
    await t.tap(find.text('unsafe.txt')); await t.pump();
    expect(opened.length, 1);
    expect(runtimeFileLink('data:text/html,bad'), isNull);
    expect(runtimeFileLink('https://user:password@files.test/x'), isNull);
    expect(t.takeException(), isNull);
  });
}
