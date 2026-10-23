// dify-spec: web/app/components/app-sidebar/app-info/__tests__/app-mode-labels.spec.ts
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/app_sidebar.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_test_i18n.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('getAppModeLabel', () {
    test('should return advanced chat label', () {
      expect(getAppModeLabel(AppModes.advancedChat), 'app.types.advanced');
    });

    test('should return agent chat label', () {
      expect(getAppModeLabel(AppModes.agentChat), 'app.types.agent');
    });

    test('should return chatbot label', () {
      expect(getAppModeLabel(AppModes.chat), 'app.types.chatbot');
    });

    test('should return completion label', () {
      expect(getAppModeLabel(AppModes.completion), 'app.types.completion');
    });

    test('should return workflow label for unknown mode', () {
      expect(getAppModeLabel('unknown-mode'), 'app.types.workflow');
    });

    test('should return workflow label for workflow mode', () {
      expect(getAppModeLabel(AppModes.workflow), 'app.types.workflow');
    });
  });
}
