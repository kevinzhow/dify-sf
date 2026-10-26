import 'package:dify_sf_app/src/workflow_editor/code_editor/editor_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart' as re;

/// Send replacement text through the native editor's real platform input client.
/// WidgetTester.enterText is only for EditableText; Re-Editor is its own client.
Future<void> enterCodeEditorText(WidgetTester tester, String text, {Finder? within}) async {
  final editor = within == null
      ? find.byType(CodeEditorView)
      : find.descendant(of: within, matching: find.byType(CodeEditorView));
  final state = tester.state<CodeEditorViewState>(editor);
  final native = tester.widget<re.CodeEditor>(find.descendant(of: editor, matching: find.byType(re.CodeEditor)));
  native.focusNode!.requestFocus();
  await tester.pump();
  state.controller.selection = TextSelection(baseOffset: 0, extentOffset: state.text.length);
  await tester.pump();
  final remote = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
  if (tester.testTextInput.setClientArgs?['enableDeltaModel'] == true) {
    await sendCodeEditorDelta(tester, {
      'oldText': remote.text,
      'deltaText': text,
      'deltaStart': remote.selection.start,
      'deltaEnd': remote.selection.end,
      'selectionBase': remote.selection.start + text.length,
      'selectionExtent': remote.selection.start + text.length,
      'selectionAffinity': 'TextAffinity.downstream',
      'selectionIsDirectional': false,
      'composingBase': -1,
      'composingExtent': -1,
    });
  } else {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: remote.text.replaceRange(remote.selection.start, remote.selection.end, text),
        selection: TextSelection.collapsed(offset: remote.selection.start + text.length),
      ),
    );
  }
  await tester.pump();
}

String codeEditorText(WidgetTester tester) => tester.state<CodeEditorViewState>(find.byType(CodeEditorView)).text;

/// Send the delta model advertised by the native controller, rather than a
/// legacy full-state message for its intentionally partial native-line buffer.
Future<void> sendCodeEditorDelta(WidgetTester tester, Map<String, Object?> delta) async {
  final call = tester.testTextInput.log.lastWhere((call) => call.method == 'TextInput.setClient');
  final id = (call.arguments as List).first;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(
      MethodCall(
        'TextInputClient.updateEditingStateWithDeltas',
        [
          id,
          {
            'deltas': [delta],
          },
        ],
      ),
    ),
    (_) {},
  );
}
