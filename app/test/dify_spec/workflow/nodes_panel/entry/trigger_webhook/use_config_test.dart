// dify-spec: web/app/components/workflow/nodes/trigger-webhook/__tests__/use-config.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_config.dart';
import 'package:flutter_test/flutter_test.dart';

Json createPayload([Json overrides = const {}]) => {
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
  'variables': <Object?>[],
  ...overrides,
};

Json variable(String name, String label, bool required) => {
  'variable': name,
  'label': label,
  'required': required,
  'value_selector': <Object?>[],
  'value_type': 'string',
};

/// useConfig over [payload] with recording mocks (Dify's mockSetInputs never feeds the data back).
class Mocks {
  Mocks(Json payload, {this.readOnly = false, this.fetch, bool Function(List<String>)? used})
    : _payload = payload,
      _used = used ?? ((_) => false);

  Json _payload;
  final bool readOnly;
  final Future<WebhookUrls> Function(String)? fetch;
  final bool Function(List<String>) _used;
  final setInputs = <Json>[];
  final removed = <List<String>>[];
  final toasts = <String>[];
  final fetched = <String>[];

  set payload(Json p) => _payload = p;

  WebhookTriggerConfig get config => WebhookTriggerConfig(
    id: 'webhook-node',
    inputs: () => _payload,
    setInputs: (next, {typed = false}) => setInputs.add(next),
    readOnly: readOnly,
    isVarUsedInNodes: _used,
    removeUsedVarInNodes: removed.add,
    notifyError: toasts.add,
    fetchWebhookUrl: fetch == null
        ? null
        : (id) {
            fetched.add(id);
            return fetch!(id);
          },
  );

  bool calledWith(bool Function(Json) matches) => setInputs.any(matches);
}

bool hasVar(Object? vars, String name, String label, [String? type]) => (vars! as List).any(
  (v) => v['variable'] == name && v['label'] == label && (type == null || v['value_type'] == type),
);

void main() {
  group('useConfig', () {
    test('should update simple fields and reset body variables when content type changes', () {
      final m = Mocks(
        createPayload({
          'content_type': 'application/json',
          'body': [
            {'name': 'payload', 'type': 'string', 'required': true},
          ],
          'variables': [variable('payload', 'body', true), variable('token', 'header', false)],
        }),
        used: (s) => s[1] == 'payload',
      );
      final c = m.config;
      c.handleMethodChange('GET');
      c.handleContentTypeChange('text/plain');
      c.handleAsyncModeChange(true);
      c.handleStatusCodeChange(204);
      c.handleResponseBodyChange('ok');

      expect(m.calledWith((d) => d['method'] == 'GET'), isTrue);
      expect(
        m.calledWith(
          (d) =>
              d['content_type'] == 'text/plain' &&
              (d['body']! as List).isEmpty &&
              (d['variables']! as List).length == 1 &&
              hasVar(d['variables'], 'token', 'header'),
        ),
        isTrue,
      );
      expect(m.removed, [
        ['webhook-node', 'payload'],
      ]);
      expect(m.calledWith((d) => d['async_mode'] == true), isTrue);
      expect(m.calledWith((d) => d['status_code'] == 204), isTrue);
      expect(m.calledWith((d) => d['response_body'] == 'ok'), isTrue);
    });

    test('should sync params, headers and body variables and reject conflicting names', () {
      final m = Mocks(
        createPayload({
          'variables': [variable('existing_header', 'header', false)],
        }),
      );
      final c = m.config;
      c.handleParamsChange([
        {'name': 'page', 'type': 'number', 'required': true},
      ]);
      c.handleHeadersChange([
        {'name': 'x-request-id', 'required': false},
      ]);
      c.handleBodyChange([
        {'name': 'body_field', 'type': 'string', 'required': true},
      ]);
      c.handleParamsChange([
        {'name': 'existing_header', 'type': 'string', 'required': true},
      ]);

      expect(
        m.calledWith((d) => (d['params']! as List).length == 1 && hasVar(d['variables'], 'page', 'param', 'number')),
        isTrue,
      );
      expect(
        m.calledWith(
          (d) =>
              (d['headers']! as List).firstOrNull?['name'] == 'x-request-id' &&
              hasVar(d['variables'], 'x_request_id', 'header'),
        ),
        isTrue,
      );
      expect(
        m.calledWith(
          (d) =>
              (d['body']! as List).firstOrNull?['name'] == 'body_field' && hasVar(d['variables'], 'body_field', 'body'),
        ),
        isTrue,
      );
      expect(m.toasts, hasLength(1));
    });

    test('should generate webhook urls once and fall back to empty url on request failure', () async {
      var calls = 0;
      final m = Mocks(
        createPayload(),
        fetch: (_) async {
          if (calls++ == 0) return (url: 'https://example.com/hook', debugUrl: 'https://example.com/debug');
          throw Exception('boom');
        },
      );

      await m.config.generateWebhookUrl();
      expect(m.fetched, ['webhook-node']);
      expect(
        m.calledWith(
          (d) =>
              d['webhook_url'] == 'https://example.com/hook' && d['webhook_debug_url'] == 'https://example.com/debug',
        ),
        isTrue,
      );

      m.payload = createPayload();
      await m.config.generateWebhookUrl();
      expect(m.calledWith((d) => d['webhook_url'] == ''), isTrue);

      m.payload = createPayload({'webhook_url': 'https://already-exists'});
      await m.config.generateWebhookUrl();
      expect(m.fetched, hasLength(2));
    });

    test('should expose readonly state and skip url generation without app id', () async {
      final m = Mocks(createPayload(), readOnly: true);
      final c = m.config;
      expect(c.readOnly, isTrue);

      await c.generateWebhookUrl();

      expect(m.fetched, isEmpty);
      expect(m.setInputs, isEmpty);
    });
  });
}
