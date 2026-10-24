import 'dart:convert';
import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/public_app/public_app_page.dart';
import 'package:dify_sf_app/src/launch_options.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dify_spec/dify_test_i18n.dart';

void main() {
  test('published paths remain distinct from console app and mail form routes', () {
    expect(LaunchOptions.fromQuery({}, path: '/workflow/code').publicAppCode, 'code');
    expect(LaunchOptions.fromQuery({}, path: '/chat/another').publicAppCode, 'another');
    expect(LaunchOptions.fromQuery({}, path: '/form/mail-token').publicAppCode, isNull);
    expect(LaunchOptions.fromQuery({'app': 'console-id'}).publicAppCode, isNull);
  });
  testWidgets('a visitor runs without console login and a refused start stays retryable', (t) async {
    SharedPreferences.setMockInitialValues({'access_token': 'must-not-be-borrowed'});
    useDifyTestTranslator();
    var attempts = 0;
    final api = HttpPublicAppApi(
      Uri.parse('https://fixture.invalid'),
      code: 'code',
      client: MockClient((r) async {
        if (r.url.path == '/v1/passport') {
          expect(r.headers['Authorization'], isNull);
          return http.Response('{"access_token":"visitor-only"}', 200);
        }
        expect(r.headers['Authorization'], 'Bearer visitor-only');
        if (r.url.path == '/v1/site') {
          return http.Response(
            jsonEncode({
              'title': 'Published echo',
              'mode': 'workflow',
              'parameters': {'user_input_form': []},
            }),
            200,
          );
        }
        if (r.url.path == '/v1/workflows/run') {
          attempts++;
          if (attempts == 1) {
            return http.Response('{"error":{"code":"runtime_unavailable","message":"Retry fixture"}}', 503);
          }
          return http.Response(
            'data: {"event":"workflow_started","workflow_run_id":"run"}\n\ndata: {"event":"workflow_finished","data":{"status":"succeeded","outputs":{"text":"visitor result"}}}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        throw StateError('Unexpected path ${r.url.path}');
      }),
    );
    await t.pumpWidget(
      MaterialApp(
        home: PublicAppPage(code: 'code', server: Uri.parse('https://fixture.invalid'), apiFor: (_, _, _) => api),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Published echo'), findsOneWidget);
    await t.tap(find.widgetWithText(DifyButton, 'share.generation.run'));
    await t.pumpAndSettle();
    expect(find.text('Retry fixture'), findsOneWidget);
    expect(t.widget<DifyButton>(find.widgetWithText(DifyButton, 'share.generation.run')).disabled, isFalse);
    await t.tap(find.widgetWithText(DifyButton, 'common.operation.retry'));
    await t.pump(const Duration(milliseconds: 50));
    await t.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('visitor result'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString('public-app:https://fixture.invalid:code:passport'),
      'visitor-only',
    );
    await t.pumpWidget(const SizedBox());
  });
  for (final revoked in [false, true]) {
    testWidgets(
      'saved public run ${revoked ? "stops following revoked access" : "reconnects without starting a duplicate run"}',
      (t) async {
        const prefix = 'public-app:https://fixture.invalid:code';
        SharedPreferences.setMockInitialValues({'$prefix:passport': 'visitor-only', '$prefix:run': 'saved-run'});
        useDifyTestTranslator();
        var follows = 0, runs = 0;
        http.StreamedResponse jsonResponse(Object value, [int status = 200]) =>
            http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(value))), status);
        final api = HttpPublicAppApi(
          Uri.parse('https://fixture.invalid'),
          code: 'code',
          passport: 'visitor-only',
          client: MockClient.streaming((r, _) async {
            expect(r.headers['Authorization'], 'Bearer visitor-only');
            if (r.url.path == '/v1/passport') return jsonResponse({'access_token': 'visitor-only'});
            if (r.url.path == '/v1/site') {
              return jsonResponse({
                'title': 'Saved app',
                'mode': 'workflow',
                'parameters': {'user_input_form': []},
              });
            }
            if (r.url.path == '/v1/workflows/run/saved-run') {
              return jsonResponse({'id': 'saved-run', 'status': 'running', 'outputs': {}});
            }
            if (r.url.path == '/v1/workflows/run') {
              runs++;
              throw StateError('A reconnect must not start another run');
            }
            if (r.url.path == '/v1/workflow/saved-run/events') {
              follows++;
              expect(r.url.queryParameters['include_state_snapshot'], 'true');
              if (revoked) {
                return jsonResponse({
                  'error': {'code': 'unauthorized', 'message': 'Access revoked'},
                }, 401);
              }
              if (follows == 1) {
                return http.StreamedResponse(Stream.error(http.ClientException('Connection lost')), 200);
              }
              return http.StreamedResponse(
                Stream.value(
                  utf8.encode(
                    'data: {"event":"workflow_finished","workflow_run_id":"saved-run","data":{"status":"succeeded","outputs":{"text":"reconnected result"}}}\n\n',
                  ),
                ),
                200,
              );
            }
            throw StateError('Unexpected path ${r.url.path}');
          }),
        );
        await t.pumpWidget(
          MaterialApp(
            home: PublicAppPage(code: 'code', server: Uri.parse('https://fixture.invalid'), apiFor: (_, _, _) => api),
          ),
        );
        await t.pumpAndSettle();
        await t.pump(const Duration(seconds: 10));
        await t.pumpAndSettle();
        expect(runs, 0);
        if (revoked) {
          expect(follows, 1);
          expect(find.text('Access revoked'), findsOneWidget);
        } else {
          expect(follows, 2);
          expect(find.text('reconnected result'), findsOneWidget);
        }
        expect((await SharedPreferences.getInstance()).getString('$prefix:run'), 'saved-run');
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('restoring chat history blocks a new run and a late history reply preserves the next query', (t) async {
    const prefix = 'public-app:https://fixture.invalid:chat';
    SharedPreferences.setMockInitialValues({
      '$prefix:passport': 'visitor-only',
      '$prefix:conversation': 'conversation',
    });
    useDifyTestTranslator();
    final restore = Completer<http.Response>(), refresh = Completer<http.Response>();
    var histories = 0, starts = 0;
    final api = HttpPublicAppApi(
      Uri.parse('https://fixture.invalid'),
      code: 'chat',
      passport: 'visitor-only',
      client: MockClient((r) async {
        if (r.url.path == '/v1/passport') return http.Response('{"access_token":"visitor-only"}', 200);
        if (r.url.path == '/v1/site') {
          return http.Response(
            '{"title":"Restored chat","mode":"advanced-chat","parameters":{"user_input_form":[]}}',
            200,
          );
        }
        if (r.url.path == '/v1/messages') return ++histories == 1 ? restore.future : refresh.future;
        if (r.url.path == '/v1/chat-messages') {
          starts++;
          expect(jsonDecode(r.body)['query'], 'first question');
          return http.Response(
            'data: {"event":"workflow_started","workflow_run_id":"run","conversation_id":"conversation","message_id":"message"}\n\ndata: {"event":"workflow_finished","data":{"status":"succeeded","outputs":{}}}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        throw StateError('Unexpected ${r.url}');
      }),
    );
    await t.pumpWidget(
      MaterialApp(
        home: PublicAppPage(code: 'chat', server: Uri.parse('https://fixture.invalid'), apiFor: (_, _, _) => api),
      ),
    );
    for (var i = 0; i < 20 && histories == 0; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
    await t.pump(const Duration(milliseconds: 20));
    final run = find.widgetWithText(DifyButton, 'share.generation.run');
    expect(
      histories,
      1,
      reason:
          'History must load before controls enable; errors: ${t.widgetList<DifyTextLine>(find.byType(DifyTextLine)).map((w) => w.toString()).join()}',
    );
    expect(t.widget<DifyButton>(run).disabled, isTrue);
    expect(starts, 0);
    restore.complete(http.Response('{"data":[]}', 200));
    await t.pumpAndSettle();
    expect(t.widget<DifyButton>(run).disabled, isFalse);
    await t.enterText(find.byType(EditableText), 'first question');
    await t.tap(run);
    await t.pumpAndSettle();
    expect(histories, 2);
    await t.enterText(find.byType(EditableText), 'next question');
    refresh.complete(
      http.Response('{"data":[{"id":"message","query":"first question","answer":"first answer"}]}', 200),
    );
    await t.pumpAndSettle();
    expect(t.widget<EditableText>(find.byType(EditableText)).controller.text, 'next question');
    expect(starts, 1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('failed public chat keeps the question and retries from the last successful parent', (t) async {
    const prefix = 'public-app:https://fixture.invalid:chat';
    SharedPreferences.setMockInitialValues({'$prefix:passport': 'visitor', '$prefix:conversation': 'conversation'});
    useDifyTestTranslator();
    var attempts = 0;
    final api = HttpPublicAppApi(
      Uri.parse('https://fixture.invalid'),
      code: 'chat',
      passport: 'visitor',
      client: MockClient((r) async {
        if (r.url.path == '/v1/passport') {
          return http.Response('{"access_token":"visitor"}', 200);
        }
        if (r.url.path == '/v1/site') {
          return http.Response('{"mode":"advanced-chat","title":"Chat","parameters":{"user_input_form":[]}}', 200);
        }
        if (r.url.path == '/v1/messages') {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'previous', 'query': 'previous question', 'answer': 'previous answer'},
                if (attempts >= 1)
                  {
                    'id': 'failed',
                    'parent_message_id': 'previous',
                    'query': 'retry this',
                    'answer': '',
                    'status': 'error',
                  },
                if (attempts >= 2)
                  {
                    'id': 'recovered',
                    'parent_message_id': 'previous',
                    'query': 'retry this',
                    'answer': 'Recovered answer',
                  },
              ],
            }),
            200,
          );
        }
        if (r.url.path == '/v1/chat-messages') {
          final body = jsonDecode(r.body);
          expect(body['query'], 'retry this');
          expect(body['parent_message_id'], 'previous');
          attempts++;
          final frames = [
            {
              'event': 'workflow_started',
              'workflow_run_id': 'run$attempts',
              'conversation_id': 'conversation',
              'message_id': attempts == 1 ? 'failed' : 'recovered',
            },
            if (attempts > 1) {'event': 'message', 'answer': 'Recovered answer'},
            {
              'event': 'workflow_finished',
              'data': {
                'status': attempts == 1 ? 'failed' : 'succeeded',
                if (attempts == 1) 'error': 'Provider refused',
                'outputs': {},
              },
            },
          ];
          return http.Response(
            frames.map((frame) => 'data: ${jsonEncode(frame)}\n\n').join(),
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        throw StateError('Unexpected ${r.url}');
      }),
    );
    await t.pumpWidget(
      MaterialApp(
        home: PublicAppPage(code: 'chat', server: Uri.parse('https://fixture.invalid'), apiFor: (_, _, _) => api),
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(EditableText), 'retry this');
    await t.tap(find.widgetWithText(DifyButton, 'share.generation.run'));
    await t.pumpAndSettle();
    expect(find.text('Provider refused'), findsOneWidget);
    expect(t.widget<EditableText>(find.byType(EditableText)).controller.text, 'retry this');
    await t.tap(find.widgetWithText(DifyButton, 'common.operation.retry'));
    await t.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Recovered answer'), findsOneWidget);
    expect(find.text('Provider refused'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('retrying a failed history restore reloads state without starting another run', (t) async {
    const prefix = 'public-app:https://fixture.invalid:chat';
    SharedPreferences.setMockInitialValues({'$prefix:passport': 'visitor', '$prefix:conversation': 'conversation'});
    useDifyTestTranslator();
    var reads = 0, runs = 0;
    HttpPublicAppApi apiFor(Uri server, String code, String? passport) => HttpPublicAppApi(
      server,
      code: code,
      passport: passport,
      client: MockClient((r) async {
        if (r.url.path == '/v1/passport') {
          return http.Response('{"access_token":"visitor"}', 200);
        }
        if (r.url.path == '/v1/site') {
          return http.Response('{"mode":"advanced-chat","title":"Chat","parameters":{"user_input_form":[]}}', 200);
        }
        if (r.url.path == '/v1/messages') {
          reads++;
          if (reads == 1) {
            return http.Response('{"error":{"code":"unavailable","message":"History unavailable"}}', 503);
          }
          return http.Response(
            '{"data":[{"id":"previous","query":"Restored question","answer":"Restored answer"}]}',
            200,
          );
        }
        if (r.url.path == '/v1/chat-messages') {
          runs++;
        }
        throw StateError('Unexpected ${r.url}');
      }),
    );
    await t.pumpWidget(
      MaterialApp(
        home: PublicAppPage(code: 'chat', server: Uri.parse('https://fixture.invalid'), apiFor: apiFor),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('History unavailable'), findsOneWidget);
    expect(t.widget<DifyButton>(find.widgetWithText(DifyButton, 'share.generation.run')).disabled, isTrue);
    await t.tap(find.widgetWithText(DifyButton, 'common.operation.retry'));
    await t.pumpAndSettle();
    expect(reads, 2);
    expect(runs, 0);
    expect(find.text('Restored answer'), findsOneWidget);
    expect(find.text('History unavailable'), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('public chat file cards survive the live stream and persisted history', (t) async {
    SharedPreferences.setMockInitialValues({});
    useDifyTestTranslator();
    final stream = StreamController<List<int>>();
    final file = {
      'related_id': 'file',
      'filename': 'answer.txt',
      'mime_type': 'text/plain',
      'size': 12,
      'type': 'document',
      'transfer_method': 'tool_file',
      'url': 'https://fixture.invalid/files/answer.txt',
    };
    http.StreamedResponse json(Object body) => http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), 200);
    final api = HttpPublicAppApi(
      Uri.parse('https://fixture.invalid'),
      code: 'chat',
      client: MockClient.streaming((r, _) async {
        if (r.url.path == '/v1/passport') {
          return json({'access_token': 'visitor'});
        }
        if (r.url.path == '/v1/site') {
          return json({
            'mode': 'advanced-chat',
            'title': 'Files',
            'parameters': {'user_input_form': []},
          });
        }
        if (r.url.path == '/v1/chat-messages') {
          return http.StreamedResponse(stream.stream, 200, headers: {'content-type': 'text/event-stream'});
        }
        if (r.url.path == '/v1/messages') {
          return json({
            'data': [
              {
                'id': 'message',
                'query': 'a file',
                'answer': 'Here',
                'files': [file],
              },
            ],
          });
        }
        throw StateError('Unexpected ${r.url}');
      }),
    );
    await t.pumpWidget(
      MaterialApp(
        home: PublicAppPage(code: 'chat', server: Uri.parse('https://fixture.invalid'), apiFor: (_, _, _) => api),
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(EditableText), 'a file');
    await t.tap(find.widgetWithText(DifyButton, 'share.generation.run'));
    await t.pump();
    for (final frame in [
      {
        'event': 'workflow_started',
        'workflow_run_id': 'run',
        'conversation_id': 'conversation',
        'message_id': 'message',
      },
      {'event': 'message', 'answer': 'Here'},
      {
        'event': 'workflow_finished',
        'data': {'status': 'succeeded', 'outputs': {}},
      },
      {
        'event': 'message_end',
        'files': [file],
      },
    ]) {
      stream.add(utf8.encode('data: ${jsonEncode(frame)}\n\n'));
    }
    await t.pumpAndSettle();
    expect(find.text('answer.txt'), findsOneWidget);
    unawaited(stream.close());
    await t.pumpAndSettle();
    expect(find.text('answer.txt'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
