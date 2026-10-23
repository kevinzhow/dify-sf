// dify-spec: web/app/components/workflow/nodes/trigger-webhook/__tests__/use-config.helpers.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_default.dart';
import 'package:flutter_test/flutter_test.dart';

Json variable(String name, String label, bool required, String type) => {
  'variable': name,
  'label': label,
  'required': required,
  'value_selector': <Object?>[],
  'value_type': type,
};

Json createInputs() => {
  'title': 'Webhook',
  'desc': '',
  'type': 'trigger-webhook',
  'method': 'POST',
  'content_type': 'application/json',
  'headers': <Object?>[],
  'params': <Object?>[],
  'body': <Object?>[],
  'async_mode': false,
  'status_code': 200,
  'response_body': '',
  'variables': [variable('existing_header', 'header', false, 'string'), variable('body_value', 'body', true, 'string')],
};

void main() {
  group('trigger webhook config helpers', () {
    test('syncs variables, updates existing ones and validates names', () {
      final errors = <String>[];
      final removed = <List<String>>[];
      bool used(List<String> s) => s[1] == 'old_param';
      final draft = {
        ...createInputs(),
        'variables': [
          variable('old_param', 'param', true, 'number'),
          variable('existing_header', 'header', false, 'string'),
        ],
      };

      expect(
        syncVariables(
          draft: draft,
          id: 'node-1',
          newData: [
            {'name': 'existing_header', 'type': 'string', 'required': true},
          ],
          sourceType: 'header',
          notifyError: errors.add,
          isVarUsedInNodes: used,
          removeUsedVarInNodes: removed.add,
        ),
        isTrue,
      );
      expect(
        (draft['variables']! as List).any(
          (v) => v['variable'] == 'existing_header' && v['label'] == 'header' && v['required'] == true,
        ),
        isTrue,
      );

      expect(
        syncVariables(
          draft: draft,
          id: 'node-1',
          newData: [
            {'name': '1invalid', 'type': 'string', 'required': true},
          ],
          sourceType: 'param',
          notifyError: errors.add,
          isVarUsedInNodes: used,
          removeUsedVarInNodes: removed.add,
        ),
        isFalse,
      );
      expect(errors, contains('varKeyError.notStartWithNumber'));

      expect(
        syncVariables(
          draft: createInputs(),
          id: 'node-1',
          newData: [
            {'name': 'x-request-id', 'type': 'string', 'required': true},
            {'name': 'x-request-id', 'type': 'string', 'required': false},
          ],
          sourceType: 'header',
          notifyError: errors.add,
          isVarUsedInNodes: used,
          removeUsedVarInNodes: removed.add,
        ),
        isFalse,
      );
      expect(errors, contains('variableConfig.varName'));

      errors.clear();
      expect(
        syncVariables(
          draft: {...createInputs(), 'variables': null},
          id: 'node-1',
          newData: [
            {'name': webhookRawVariableName, 'type': 'string', 'required': true},
          ],
          sourceType: 'body',
          notifyError: errors.add,
          isVarUsedInNodes: used,
          removeUsedVarInNodes: removed.add,
        ),
        isFalse,
      );
      expect(errors, contains('variableConfig.varName'));

      expect(
        syncVariables(
          draft: createInputs(),
          id: 'node-1',
          newData: [
            {'name': 'existing_header', 'type': 'string', 'required': true},
          ],
          sourceType: 'param',
          notifyError: errors.add,
          isVarUsedInNodes: used,
          removeUsedVarInNodes: removed.add,
        ),
        isFalse,
      );
      expect(errors, contains('existing_header'));

      final removableDraft = {
        ...createInputs(),
        'variables': [variable('old_param', 'param', true, 'number')],
      };
      expect(
        syncVariables(
          draft: removableDraft,
          id: 'node-1',
          newData: const [],
          sourceType: 'param',
          notifyError: errors.add,
          isVarUsedInNodes: used,
          removeUsedVarInNodes: removed.add,
        ),
        isTrue,
      );
      expect(removed, [
        ['node-1', 'old_param'],
      ]);
    });

    test('updates content, source fields and webhook urls', () {
      final removed = <List<String>>[];
      final nextContentType = updateContentType(
        inputs: createInputs(),
        id: 'node-1',
        contentType: 'text/plain',
        isVarUsedInNodes: (_) => true,
        removeUsedVarInNodes: removed.add,
      );
      expect(nextContentType['body'], isEmpty);
      expect((nextContentType['variables']! as List).every((v) => v['label'] != 'body'), isTrue);
      expect(removed, [
        ['node-1', 'body_value'],
      ]);

      expect(
        updateContentType(
          inputs: createInputs(),
          id: 'node-1',
          contentType: 'application/json',
          isVarUsedInNodes: (_) => false,
          removeUsedVarInNodes: removed.add,
        )['body'],
        isEmpty,
      );

      expect(
        updateContentType(
          inputs: {...createInputs(), 'variables': null},
          id: 'node-1',
          contentType: 'multipart/form-data',
          isVarUsedInNodes: (_) => false,
          removeUsedVarInNodes: removed.add,
        )['body'],
        isEmpty,
      );

      Json source(String sourceType, List<Json> data) => updateSourceFields(
        inputs: createInputs(),
        id: 'node-1',
        sourceType: sourceType,
        nextData: data,
        notifyError: (_) {},
        isVarUsedInNodes: (_) => false,
        removeUsedVarInNodes: (_) {},
      );
      expect(
        source('param', [
          {'name': 'page', 'type': 'number', 'required': true},
        ])['params'],
        [
          {'name': 'page', 'type': 'number', 'required': true},
        ],
      );
      expect(
        source('body', [
          {'name': 'payload', 'type': 'string', 'required': true},
        ])['body'],
        [
          {'name': 'payload', 'type': 'string', 'required': true},
        ],
      );
      expect(
        source('header', [
          {'name': 'x-request-id', 'required': true},
        ])['headers'],
        [
          {'name': 'x-request-id', 'required': true},
        ],
      );

      expect(updateMethod(createInputs(), 'GET')['method'], 'GET');
      expect(updateSimpleField(createInputs(), 'status_code', 204)['status_code'], 204);
      final urls = updateWebhookUrls(createInputs(), 'https://hook', 'https://debug');
      expect(urls['webhook_url'], 'https://hook');
      expect(urls['webhook_debug_url'], 'https://debug');
    });
  });
}
