// dify-spec: web/app/components/workflow/nodes/_base/components/editor/code-editor/__tests__/index.spec.tsx
import 'dart:convert';

import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _jsonObjectSchema = {
  'type': 'object',
  'properties': {
    'id': {'type': 'string'},
    'name': {'type': 'string'},
  },
  'required': ['id', 'name'],
};

void main() {
  group('CodeEditor', () {
    testWidgets('serializes object JSON values so Monaco receives text instead of a buffer factory', (t) async {
      await t.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 400,
              child: DifyCodeEditor(language: CodeLanguage.json, value: _jsonObjectSchema, noWrapper: true),
            ),
          ),
        ),
      );

      final editable = t.widget<EditableText>(find.byType(EditableText));
      expect(editable.controller.text, const JsonEncoder.withIndent('  ').convert(_jsonObjectSchema));
    });
  });
}
