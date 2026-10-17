// dify-spec: web/app/components/app/app-publisher/__tests__/utils.spec.ts
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/header/publisher/utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // withSelectorKey((key) => key, 'app'): the bare key.
  setUp(() => DifyI18n.current = KeyEchoTranslator());

  group('app-publisher utils', () {
    group('getPublisherAppMode', () {
      test('should normalize chat-like apps to chat mode', () {
        expect(getPublisherAppMode('agent-chat'), 'chat');
      });

      test('should keep completion mode unchanged', () {
        expect(getPublisherAppMode('completion'), 'completion');
      });
    });

    group('getPublisherAppUrl', () {
      test('should build the published app url from site info', () {
        expect(
          getPublisherAppUrl(appBaseUrl: 'https://example.com', accessToken: 'token-1', mode: 'chat'),
          'https://example.com$publisherBasePath/chat/token-1',
        );
      });
    });

    group('getDisabledFunctionTooltip', () {
      test('should prioritize the unpublished hint', () {
        expect(getDisabledFunctionTooltip(missingStartNode: false, noAccessPermission: false), 'notPublishedYet');
      });

      test('should return the access error when the app is published but blocked', () {
        expect(
          getDisabledFunctionTooltip(
            publishedAt: DateTime.now().millisecondsSinceEpoch,
            missingStartNode: false,
            noAccessPermission: true,
          ),
          'noAccessPermission',
        );
      });
    });
  });
}
