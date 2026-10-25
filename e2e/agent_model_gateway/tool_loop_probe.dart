// Hermetic Genkit tool-loop probe over the production adapter. Input comes from stdin, never command-line credentials.
import 'dart:convert';
import 'dart:io';
import 'package:agent_service/src/gateway.dart';
import 'package:agent_service/src/model.dart';
import 'package:agent_service/src/protocol.dart';
import 'package:genkit/genkit.dart';
import 'package:schemantic/schemantic.dart';

Future<void> main() async {
  final body = (jsonDecode(await stdin.transform(utf8.decoder).join()) as Map).cast<String,Object?>();
  final request = OperationRequest.parse((body['operation'] as Map).cast<String,Object?>());
  final inner = InnerClient(baseUrl: Uri.parse(body['inner_url'] as String),
      serviceKey: body['service_key'] as String, runToken: body['run_token'] as String);
  final ai = Genkit(isDevEnv: false, promptDir: null);
  final calls = <Map<String,Object?>>[];
  final invocations = <String>[];
  try {
    final model = defineGatewayModel(ai, GatewayModelContext(inner: inner, request: request, runId: 'tool-probe-run',
        onReasoning: (_) {}, onModelCall: (id, _) {invocations.add(id);}));
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
      'messages':[for(final message in result.messages) message.toJson()]}));
  } finally {
    inner.close();
    await ai.shutdown();
  }
}
