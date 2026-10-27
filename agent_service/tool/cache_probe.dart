// Prompt cache measurement for OpenAI-compatible providers (DeepSeek).
//
// Today no cache count reaches the agent service: Dify's `LLMUsage` has no
// such field, so the langgenius/deepseek plugin (dify_plugin 0.10.2) and the
// plugin daemon drop DeepSeek's `prompt_cache_hit_tokens`. Two ways to see
// them anyway (docs/agent-v2.md, "Prompt cache"):
//
//   dart run tool/cache_probe.dart proxy --listen 0.0.0.0:8790 \
//       --upstream https://api.deepseek.com --log /var/tmp/<you>/cache.jsonl
//
//     A pass-through proxy. Point the DeepSeek credential's "API endpoint"
//     (`endpoint_url`) at it. For every `POST …/chat/completions` it writes
//     one JSON line: the model, the number of messages and images, the
//     request size, whether the request repeats the previous request of the
//     same conversation (same first two messages) byte for byte before
//     appending (`prefix_stable`, `first_changed_message`), and the
//     response's `usage` (hits, misses, prompt tokens). It never logs headers
//     (the API key), message text or image bytes.
//
//   DEEPSEEK_API_KEY=… dart run tool/cache_probe.dart probe \
//       --image some.png [--model deepseek-flash] [--base https://api.deepseek.com]
//
//     Three requests against the provider: A = system + user(text, image);
//     B = A + assistant + user (append-only); C = B with the image's detail
//     changed (a changed early message). Prints prompt tokens, hits and
//     misses of each: B's hits show whether an image prefix is cached, C's
//     where a change in an early message cuts the cache. Use your own key.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty || !{'proxy', 'probe'}.contains(args.first)) {
    stderr.writeln('usage: cache_probe.dart proxy|probe [options]');
    exit(64);
  }
  final opts = <String, String>{};
  for (var i = 1; i + 1 < args.length; i += 2) {
    opts[args[i].replaceFirst(RegExp('^--'), '')] = args[i + 1];
  }
  if (args.first == 'proxy') return proxy(opts);
  return probe(opts);
}

/// Per message JSON texts and the tools' JSON text of a chat request.
({List<String> messages, String tools, int images}) shape(Map body) {
  final messages = (body['messages'] as List? ?? const []);
  var images = 0;
  for (final m in messages) {
    final c = m is Map ? m['content'] : null;
    if (c is List) {
      images += c.where((p) => p is Map && p['type'] == 'image_url').length;
    }
  }
  return (
    messages: [for (final m in messages) jsonEncode(m)],
    tools: jsonEncode(body['tools']),
    images: images,
  );
}

Future<void> proxy(Map<String, String> opts) async {
  final listen = (opts['listen'] ?? '127.0.0.1:8790').split(':');
  final upstream = Uri.parse(opts['upstream'] ?? 'https://api.deepseek.com');
  final log = File(opts['log'] ?? 'cache-probe.jsonl')
      .openWrite(mode: FileMode.append);
  final previous = <String, ({List<String> messages, String tools})>{};
  final client = HttpClient();
  final server = await HttpServer.bind(listen[0], int.parse(listen[1]));
  stderr.writeln('cache probe proxy on ${listen.join(':')} -> $upstream');
  await for (final req in server) {
    unawaited(() async {
      try {
        final body = await req.fold<List<int>>([], (a, b) => a..addAll(b));
        final target = upstream.replace(
          path: '${upstream.path}${req.uri.path}'.replaceAll('//', '/'),
          query: req.uri.hasQuery ? req.uri.query : null,
        );
        final out = await client.openUrl(req.method, target);
        req.headers.forEach((name, values) {
          if (const {'host', 'content-length'}.contains(name)) return;
          for (final v in values) {
            out.headers.add(name, v);
          }
        });
        out.contentLength = body.length;
        out.add(body);
        final res = await out.close();
        req.response.statusCode = res.statusCode;
        res.headers.forEach((name, values) {
          if (const {'content-length', 'transfer-encoding'}.contains(name)) {
            return;
          }
          for (final v in values) {
            req.response.headers.add(name, v);
          }
        });
        final copy = <int>[];
        await for (final chunk in res) {
          copy.addAll(chunk);
          req.response.add(chunk);
          await req.response.flush();
        }
        await req.response.close();
        if (req.method == 'POST' && req.uri.path.endsWith('chat/completions')) {
          log.writeln(
            jsonEncode(_record(body, copy, res.statusCode, previous)),
          );
          await log.flush();
        }
      } catch (e) {
        stderr.writeln('proxy error: $e');
        try {
          req.response.statusCode = 502;
          await req.response.close();
        } catch (_) {}
      }
    }());
  }
}

Map<String, Object?> _record(
  List<int> requestBytes,
  List<int> responseBytes,
  int status,
  Map<String, ({List<String> messages, String tools})> previous,
) {
  final Map body;
  try {
    body = jsonDecode(utf8.decode(requestBytes)) as Map;
  } catch (_) {
    return {'error': 'request is not JSON', 'status': status};
  }
  final s = shape(body);
  final key = s.messages.take(2).join('\n').hashCode.toRadixString(16);
  final before = previous[key];
  int? firstChanged;
  bool? stable;
  if (before != null) {
    stable = true;
    for (var i = 0; i < before.messages.length; i++) {
      if (i >= s.messages.length || before.messages[i] != s.messages[i]) {
        stable = false;
        firstChanged = i;
        break;
      }
    }
    if (stable == true && before.tools != s.tools) {
      stable = false;
      firstChanged = -1;
    }
  }
  previous[key] = (messages: s.messages, tools: s.tools);
  return {
    'at': DateTime.now().toUtc().toIso8601String(),
    'status': status,
    'model': body['model'],
    'stream': body['stream'],
    'conversation': key,
    'messages': s.messages.length,
    'images': s.images,
    'request_bytes': requestBytes.length,
    'prefix_stable': stable,
    'first_changed_message': firstChanged,
    'usage': usageOf(responseBytes),
  };
}

/// The `usage` object of a JSON or SSE chat completion response.
Object? usageOf(List<int> bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  Object? usage;
  void take(String json) {
    try {
      final j = jsonDecode(json);
      if (j is Map && j['usage'] != null) usage = j['usage'];
    } catch (_) {}
  }

  if (text.trimLeft().startsWith('{')) {
    take(text);
  } else {
    for (final line in const LineSplitter().convert(text)) {
      if (line.startsWith('data:')) take(line.substring(5).trim());
    }
  }
  return usage;
}

Future<void> probe(Map<String, String> opts) async {
  final key = Platform.environment[opts['key-env'] ?? 'DEEPSEEK_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('set DEEPSEEK_API_KEY (your own key)');
    exit(64);
  }
  final imagePath = opts['image'];
  if (imagePath == null) {
    stderr.writeln('--image <png|jpeg> is required');
    exit(64);
  }
  final bytes = File(imagePath).readAsBytesSync();
  final mime = imagePath.toLowerCase().endsWith('.png')
      ? 'image/png'
      : 'image/jpeg';
  final url = 'data:$mime;base64,${base64.encode(bytes)}';
  final model = opts['model'] ?? 'deepseek-flash';
  final base = Uri.parse(opts['base'] ?? 'https://api.deepseek.com');
  // Long enough system text that several 64-token cache units exist.
  final system =
      'You are a careful assistant. ${List.filled(60, 'Answer briefly and precisely.').join(' ')}';
  Map<String, Object?> user(String detail) => {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': 'Describe this image in one sentence.'},
      {
        'type': 'image_url',
        'image_url': {'url': url, 'detail': detail},
      },
    ],
  };
  final a = [
    {'role': 'system', 'content': system},
    user('high'),
  ];
  final client = HttpClient();
  Future<Map> call(String name, List<Object?> messages) async {
    final req = await client.postUrl(base.resolve('chat/completions'));
    req.headers.set('authorization', 'Bearer $key');
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode({
        'model': model,
        'messages': messages,
        'max_tokens': 64,
        'stream': false,
      }),
    );
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    final j = jsonDecode(text) as Map;
    final u = j['usage'] as Map? ?? {};
    stdout.writeln(
      '$name: status ${res.statusCode} prompt ${u['prompt_tokens']} '
      'hit ${u['prompt_cache_hit_tokens']} miss ${u['prompt_cache_miss_tokens']} '
      'details ${jsonEncode(u['prompt_tokens_details'])}',
    );
    return j;
  }

  final ra = await call('A (system + image)', a);
  final answer = ((ra['choices'] as List?)?.first as Map?)?['message'] as Map?;
  final b = [
    ...a,
    {'role': 'assistant', 'content': answer?['content'] ?? 'ok'},
    {'role': 'user', 'content': 'Now name its main colour.'},
  ];
  // Cache construction takes seconds (DeepSeek's guide).
  await Future<void>.delayed(const Duration(seconds: 5));
  await call('B (A + 2 appended)', b);
  await Future<void>.delayed(const Duration(seconds: 5));
  await call('C (B, image detail low)', [b[0], user('low'), ...b.skip(2)]);
  client.close();
}
