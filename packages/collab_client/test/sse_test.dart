import 'package:collab_client/collab_client.dart';
import 'package:test/test.dart';

void main() {
  List<SseMessage> parseAll(Iterable<String> chunks) {
    final p = SseParser();
    return [for (final c in chunks) ...p.add(c)];
  }

  test('parses id/event/data frames, ignores comments and retry', () {
    final msgs = parseAll([
      'retry: 1000\n\n',
      ': ping\n\n',
      'id: 7\nevent: commit\ndata: {"seq":7}\n\n',
      'event: ready\ndata: {"head":7}\n\n',
    ]);
    // The last event id sticks to later messages, as the SSE spec says.
    expect(msgs.map((m) => (m.event, m.data, m.id)), [('commit', '{"seq":7}', '7'), ('ready', '{"head":7}', '7')]);
  });

  test('is independent of how the bytes are chunked', () {
    const text = 'retry: 1000\n\nid: 1\nevent: commit\ndata: a\ndata: b\n\n: ping\n\nevent: ready\ndata: {}\n\n';
    final whole = parseAll([text]);
    expect(whole.map((m) => m.data), ['a\nb', '{}']);
    for (var size = 1; size < 12; size++) {
      final chunks = [
        for (var i = 0; i < text.length; i += size) text.substring(i, i + size > text.length ? text.length : i + size),
      ];
      expect(parseAll(chunks).map((m) => (m.event, m.data)), whole.map((m) => (m.event, m.data)), reason: 'size $size');
    }
  });

  test('handles CRLF and lone CR line endings, even split across chunks', () {
    expect(parseAll(['event: a\r\ndata: 1\r\n\r\n']).single.data, '1');
    expect(parseAll(['event: a\rdata: 2\r\r']).single.data, '2');
    expect(parseAll(['event: a\r', '\ndata: 3\r', '\n\r', '\n']).single.data, '3');
  });

  test('strips exactly one leading space, keeps the rest', () {
    expect(parseAll(['data:  two spaces\n\n']).single.data, ' two spaces');
    expect(parseAll(['data:nospace\n\n']).single.data, 'nospace');
    expect(parseAll(['data\n\n']).single.data, '');
  });

  test('a block without data produces no message; default event name is "message"', () {
    expect(parseAll(['event: x\n\n']), isEmpty);
    expect(parseAll(['data: 1\n\n']).single.event, 'message');
  });
}
