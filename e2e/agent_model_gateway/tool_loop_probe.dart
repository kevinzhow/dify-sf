// Hermetic Genkit tool-loop probe over the production adapter. Input comes from stdin, never command-line credentials.
import 'dart:convert';
import 'dart:io';
import 'package:agent_service/src/gateway.dart';
import 'package:agent_service/src/model.dart';
import 'package:agent_service/src/protocol.dart';
import 'package:genkit/genkit.dart';
import 'package:http/http.dart' as http;
import 'package:schemantic/schemantic.dart';

class WireRecorder extends http.BaseClient {
  final inner = http.Client();
  final requests = <Object?>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.Request && request.url.path.endsWith('/llm/invoke')) {
      requests.add(jsonDecode(request.body)); // Test prompt bodies only; authentication headers are never recorded.
    }
    return inner.send(request);
  }
  @override
  void close() => inner.close();
}

Future<void> main() async {
  final body = (jsonDecode(await stdin.transform(utf8.decoder).join()) as Map).cast<String,Object?>();
  final request = OperationRequest.parse((body['operation'] as Map).cast<String,Object?>());
  final wire = WireRecorder();
  final inner = InnerClient(client: wire, baseUrl: Uri.parse(body['inner_url'] as String),
      serviceKey: body['service_key'] as String, runToken: body['run_token'] as String);
  final ai = Genkit(isDevEnv: false, promptDir: null);
  final calls = <Map<String,Object?>>[];
  final invocations = <String>[];
  final reasoning = <String>[];
  try {
    final model = defineGatewayModel(ai, GatewayModelContext(inner: inner, request: request, runId: 'tool-probe-run',
        onReasoning: reasoning.add, onModelCall: (id, _) {invocations.add(id);}));
    for (final name in ['a', 'b']) {
      ai.defineTool<Object?,Object?>(name: name, description: 'Fixture '+name,
          inputSchema: SchemanticType.from<Object?>(jsonSchema: {'type':'object','properties':{name:{'type':'integer'}},'required':[name]}, parse:(j)=>j),
          fn: (input, _) {
            calls.add({'name':name,'input':input});
            return ToolResult.response(input);
          });
    }
    final result = await ai.generate<Object?,void>(model:model, prompt:'fixture-interleaved', toolNames:['a','b'], maxTurns:4, onChunk:(_) {});
    stdout.writeln(jsonEncode({'text':result.text,'calls':calls,'invocations':invocations,
      'reasoning':reasoning, 'requests':wire.requests, 'messages':[for(final message in result.messages) message.toJson()]}));
  } finally {
    inner.close();
    await ai.shutdown();
  }
}
