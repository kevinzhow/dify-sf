// dify-spec: web/app/components/workflow/variable-inspect/__tests__/right.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/inspect_vars.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/panel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'inspect_harness.dart';

CurrentVar createCurrentNodeVar([DifyJson overrides = const {}]) => (
  nodeId: 'node-1',
  nodeType: 'code',
  title: 'Code',
  nodeData: const {'type': 'code', 'title': 'Code', 'desc': ''},
  varJson: createVariable(overrides),
  isSingRunRunning: false,
);

void main() {
  setUp(useDifyTestTranslator);

  group('VariableInspect Right', () {
    late RecordingServices services;
    late InspectHarness h;
    var menus = 0;

    setUp(() {
      services = RecordingServices();
      h = InspectHarness(services: services);
      menus = 0;
    });

    Future<void> renderRight(WidgetTester t, CurrentVar current, {double bottomPanelWidth = 560}) {
      h.store.setBottomPanelWidth(bottomPanelWidth);
      return h.pump(t, InspectRight(currentNodeVar: current, handleOpenMenu: () => menus++));
    }

    testWidgets('opens the variable menu from the named narrow-panel command', (t) async {
      await renderRight(t, createCurrentNodeVar(), bottomPanelWidth: 400);

      await t.tap(pressable('workflow.debug.variableInspect.title'));

      expect(menus, 1);
    });

    testWidgets('exposes the full-content download as a named link', (t) async {
      await renderRight(
        t,
        createCurrentNodeVar({
          'is_truncated': true,
          'full_content': {'size_bytes': 1024, 'download_url': 'https://example.com/result.txt'},
        }),
      );

      await t.tap(pressable('workflow.debug.variableInspect.exportToolTip'));

      expect(services.calls, ['open https://example.com/result.txt']);
    });

    testWidgets('resets an edited node variable from its named command', (t) async {
      await renderRight(t, createCurrentNodeVar({'edited': true}));

      await t.tap(pressable('workflow.debug.variableInspect.reset'));
      await t.pump();

      expect(services.calls, ['reset var-1']);
    });

    testWidgets('resets an edited conversation variable from its named command', (t) async {
      h.crud.conversationEdits.value = {'var-1': 'draft'};
      await renderRight(t, createCurrentNodeVar({'type': VarInInspectType.conversation, 'edited': true}));

      await t.tap(pressable('workflow.debug.variableInspect.resetConversationVar'));

      expect(h.crud.conversationEdits.value, isEmpty);
    });
  });
}
