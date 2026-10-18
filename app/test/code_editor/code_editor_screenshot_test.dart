/// Renders the code editor to PNG at 2x for eyeballing against Dify, with the bundled Noto Sans and DejaVu Sans Mono.
/// Only runs when `SCREENSHOT_DIR` is set:
///
///     SCREENSHOT_DIR=/tmp/shots flutter test test/code_editor/code_editor_screenshot_test.dart
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';

const _python = '''
def main(arg1: str, arg2: str) -> dict:
    # Sum two strings, then wrap a long line to see how wrapping looks in a narrow panel.
    result = {"result": arg1 + arg2, "items": [x * 2 for x in range(10) if x % 2 == 0]}
    if not result:
        return {'empty': True, 'value': None, 'f': f"{arg1!r} and {arg2:>10}"}
    return result
''';

void main() {
  final out = Platform.environment['SCREENSHOT_DIR'];
  if (out == null) return;

  testWidgets('code editor screenshots', (t) async {
    await useAppFonts();
    final mono = FontLoader('DejaVu Sans Mono')..addFont(rootBundle.load('assets/fonts/DejaVuSansMono.ttf'));
    await mono.load();
    t.view.physicalSize = const Size(900, 1000);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final boundary = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(fontFamily: 'Noto Sans'),
          home: Scaffold(
            backgroundColor: Colors.white,
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DifyCodeEditor(title: 'Python3', language: CodeLanguage.python3, value: _python, onChange: (_) {}),
                  const SizedBox(height: 12),
                  const DifyCodeEditor(
                    title: 'JSON',
                    language: CodeLanguage.json,
                    readOnly: true,
                    height: 140,
                    value: {
                      'type': 'object',
                      'n': 1.5,
                      'ok': true,
                      'list': ['a', null],
                    },
                  ),
                  const SizedBox(height: 12),
                  const DifyCodeEditor(
                    title: 'Empty',
                    language: CodeLanguage.javascript,
                    placeholder: 'Placeholder',
                    height: 80,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    Future<void> shot(String name) async {
      await t.pump(const Duration(milliseconds: 50));
      await t.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    await shot('code_editor');
    // Focus with the cursor inside the dict literal: current line, bracket match, active guide, focused chrome.
    final editable = find.byType(EditableText).first;
    await t.tap(editable);
    await t.pump();
    final state = t.state<EditableTextState>(editable);
    state.userUpdateTextEditingValue(
      state.textEditingValue.copyWith(selection: const TextSelection.collapsed(offset: 175)),
      SelectionChangedCause.tap,
    );
    await shot('code_editor_focused');
    state.userUpdateTextEditingValue(
      state.textEditingValue.copyWith(selection: const TextSelection(baseOffset: 60, extentOffset: 240)),
      SelectionChangedCause.tap,
    );
    await shot('code_editor_selection');
  });
}
