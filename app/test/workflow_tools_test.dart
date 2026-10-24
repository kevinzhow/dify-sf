import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow/workspace_tools.dart';
import 'package:dify_sf_app/src/workflow/workflow_tool_publisher.dart';
import 'package:flutter/widgets.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'dify_spec/base_form/_harness.dart';
import 'dify_spec/workflow/nodes_panel/data/harness.dart' as panel;

import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_panel.dart';

void main() {
  for (final useDefault in [false, true]) {
    testWidgets('deleting ${useDefault ? "default" : "selected"} authorization preserves its unavailable identity', (
      tester,
    ) async {
      var deleted = false;
      final selections = <String?>[];
      String? selectedId = useDefault ? null : 'selected';
      final api = ToolsApi(
        Uri.parse('https://fixture.invalid'),
        client: MockClient((request) async {
          if (request.url.path.endsWith('/delete')) {
            expect(jsonDecode(request.body), {'credential_id': 'selected'});
            deleted = true;
            return http.Response('{"result":"success"}', 200);
          }
          return http.Response(
            jsonEncode([
              if (!deleted) {'id': 'selected', 'name': 'Chosen key', 'can_manage': true},
              {'id': 'other', 'name': 'Another key', 'can_manage': true},
            ]),
            200,
          );
        }),
      );
      addTearDown(api.close);
      await renderForm(
        tester,
        WorkflowToolsScope(
          api: api,
          reload: () async {},
          child: StatefulBuilder(
            builder: (context, setState) => ToolCredentialControl(
              providerId: 'fixture/tools/echo',
              provider: const {
                'credentials_schema': {
                  'api_key': {'type': 'secret-input', 'required': true},
                },
              },
              selectedId: selectedId,
              onSelected: (id) {
                selections.add(id);
                setState(() => selectedId = id);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(DifyButton, 'common.operation.delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(DifyButton, 'common.operation.delete').last);
      await tester.pumpAndSettle();
      expect(deleted, isTrue);
      expect(selections, useDefault ? ['selected'] : isEmpty);
      expect(tester.widget<DifySelect<String>>(find.byType(DifySelect<String>)).value, 'selected');
      expect(find.text('plugin.auth.credentialUnavailable'), findsOneWidget);
      expect(find.text('Another key'), findsNothing);
    });
  }
  testWidgets('authorization refuses then retries without losing the secret or disabling Save', (tester) async {
    var saves = 0;
    final api = ToolsApi(
      Uri.parse('https://fixture.invalid'),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/credentials')) return http.Response('[]', 200);
        if (request.url.path.endsWith('/add')) {
          saves++;
          final value = jsonDecode(request.body) as Map;
          expect(value['credentials'], {'api_key': 'fixture-secret'});
          if (saves == 1) {
            return http.Response('{"error":{"code":"credential_validation_failed","message":"Fixture refused"}}', 400);
          }
          return http.Response('{"id":"new"}', 200);
        }
        return http.Response('[]', 200);
      }),
    );
    addTearDown(api.close);
    await renderForm(
      tester,
      WorkflowToolsScope(
        api: api,
        reload: () async {},
        child: ToolCredentialControl(
          providerId: 'fixture/tools/echo',
          provider: {
            'credentials_schema': {
              'api_key': {
                'type': 'secret-input',
                'required': true,
                'label': {'en_US': 'API Key'},
              },
            },
          },
          selectedId: null,
          onSelected: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    final add = find.widgetWithText(DifyButton, 'common.operation.add');
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.enterText(input('__name'), 'Private');
    await tester.enterText(input('api_key'), 'fixture-secret');
    final save = find.widgetWithText(DifyButton, 'common.operation.save');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.textContaining('Fixture refused'), findsOneWidget);
    expect(inputText(tester, 'api_key'), 'fixture-secret');
    expect(tester.widget<DifyButton>(save).loading, isFalse);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saves, 2);
    expect(find.byType(DifyDialogSurface), findsNothing);
  });
  testWidgets('runtime fields follow the selected credential without repeated fetches', (tester) async {
    final fetched = <Object?>[];
    final api = ToolsApi(
      Uri.parse('https://fixture.invalid'),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/credentials')) return http.Response('[]', 200);
        final body = jsonDecode(request.body) as Map;
        final id = body['credential_id'];
        fetched.add(id);
        return http.Response(
          jsonEncode([
            {
              'name': 'prompt',
              'label': {'en_US': id == 'second' ? 'Second runtime label' : 'First runtime label'},
              'human_description': {'en_US': 'Dynamic schema'},
              'type': 'string',
              'form': 'llm',
              'required': false,
            },
          ]),
          200,
        );
      }),
    );
    addTearDown(api.close);
    final harness = await panel.Harness.start(tester, [
      panel.difyNode('tool', {
        'type': 'tool',
        'title': 'Echo',
        'provider_type': 'builtin',
        'provider_id': 'fixture/tools/echo',
        'tool_name': 'echo',
        'tool_parameters': <String, Object?>{},
        'tool_configurations': <String, Object?>{},
      }),
    ]);
    harness.store.buildInTools.value = [
      {
        'id': 'fixture/tools/echo',
        'name': 'echo',
        'is_team_authorization': true,
        'tools': [
          {'name': 'echo', 'has_runtime_parameters': true, 'parameters': <Object?>[]},
        ],
      },
    ];
    await panel.renderBody(
      tester,
      harness,
      'tool',
      toolPanelBody,
      host: (child) => WorkflowToolsScope(api: api, reload: () async {}, child: child),
    );
    await tester.pumpAndSettle();
    expect(find.text('First runtime label'), findsOneWidget);
    expect(fetched, [null]);
    harness.controller.setConfig('tool', ['credential_id'], const VString('second'));
    await panel.Harness.settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Second runtime label'), findsOneWidget);
    expect(find.text('First runtime label'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(fetched, [null, 'second']);
    await harness.dispose(tester);
  });
  testWidgets('workflow tool uses published inputs and keeps rejected configuration retryable', (tester) async {
    var saves = 0;
    final api = ToolsApi(
      Uri.parse('https://fixture.invalid'),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/preview')) {
          expect(request.url.queryParameters['workflow_app_id'], 'published-app');
          return http.Response(
            jsonEncode({
              'version_id': 'fixed-published-version',
              'parameters': [
                {'name': 'published_input', 'type': 'string'},
              ],
              'outputs': [
                {'name': 'result', 'type': 'string'},
              ],
            }),
            200,
          );
        }
        final body = jsonDecode(request.body) as Map;
        expect(body['workflow_app_id'], 'published-app');
        expect(body['name'], 'echo_published');
        expect((body['parameters'] as List).single['name'], 'published_input');
        if (++saves == 1) {
          return http.Response('{"error":{"code":"temporary_failure","message":"Retry fixture"}}', 503);
        }
        return http.Response('{"id":"saved"}', 200);
      }),
    );
    addTearDown(api.close);
    await renderForm(
      tester,
      SizedBox(
        height: 800,
        child: WorkflowToolPublisher(
          api: api,
          appId: 'published-app',
          appName: 'Echo app',
          close: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('result · string'), findsOneWidget);
    await tester.enterText(input('name'), 'echo_published');
    await tester.enterText(input('description'), 'Echoes the published input');
    final save = find.widgetWithText(DifyButton, 'common.operation.save');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saves, 1);
    expect(find.textContaining('Retry fixture'), findsOneWidget);
    expect(inputText(tester, 'name'), 'echo_published');
    expect(tester.widget<DifyButton>(save).loading, isFalse);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(saves, 2);
  });
}
