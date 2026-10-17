// dify-spec: web/app/components/workflow/nodes/_base/components/editor/__tests__/base.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';

void main() {
  String? copied;
  setUp(() {
    useDifyTestTranslator();
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      },
    );
  });

  group('Base editor', () {
    testWidgets('copies the editor value from its named icon command', (t) async {
      await t.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Overlay.wrap(
            child: const CodeEditorBase(
              title: 'Code',
              value: 'const answer = 42',
              isFocus: false,
              child: Text('Editor'),
            ),
          ),
        ),
      );

      final button = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.button == true && w.properties.label == 'common.operation.copy',
      );
      expect(button, findsOneWidget);
      await t.tap(button);
      await t.pump();

      expect(copied, 'const answer = 42');
      await t.pump(const Duration(seconds: 2));
    });
  });
}
