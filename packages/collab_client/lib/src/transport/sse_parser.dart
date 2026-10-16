/// One Server-Sent Events message (a block of lines ended by a blank line).
final class SseMessage {
  const SseMessage({required this.event, required this.data, this.id});

  /// The `event:` name; `message` when absent (per the SSE spec).
  final String event;

  /// The `data:` lines joined with `\n`.
  final String data;
  final String? id;

  @override
  String toString() => 'SseMessage($event, id=$id, ${data.length} chars)';
}

/// Incremental parser for the `text/event-stream` format (WHATWG HTML, section 9.2): feed it decoded text
/// in arbitrary chunks, get complete messages back. Comment lines (`: ping`) and `retry:` are consumed and
/// produce nothing; the reconnect delay is the client's business (exponential backoff with jitter).
class SseParser {
  final StringBuffer _line = StringBuffer();
  bool _skipLf = false;

  String? _event;
  String? _id;
  final List<String> _data = [];

  /// Completed messages from [chunk] (possibly none; partial frames are kept for the next call).
  List<SseMessage> add(String chunk) {
    final out = <SseMessage>[];
    for (var i = 0; i < chunk.length; i++) {
      final ch = chunk.codeUnitAt(i);
      if (_skipLf) {
        _skipLf = false;
        if (ch == 0x0A) continue; // the LF of a CRLF pair
      }
      if (ch == 0x0D || ch == 0x0A) {
        _skipLf = ch == 0x0D;
        final msg = _endOfLine(_line.toString());
        _line.clear();
        if (msg != null) out.add(msg);
      } else {
        _line.writeCharCode(ch);
      }
    }
    return out;
  }

  SseMessage? _endOfLine(String line) {
    if (line.isEmpty) {
      // Blank line: dispatch the message, if it has data.
      final hadData = _data.isNotEmpty;
      final msg = hadData ? SseMessage(event: _event ?? 'message', data: _data.join('\n'), id: _id) : null;
      _event = null;
      _data.clear();
      return msg;
    }
    if (line.startsWith(':')) return null; // comment / keep-alive
    final colon = line.indexOf(':');
    final String field;
    String value;
    if (colon < 0) {
      field = line;
      value = '';
    } else {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
    }
    switch (field) {
      case 'event':
        _event = value;
      case 'data':
        _data.add(value);
      case 'id':
        if (!value.contains('\u0000')) _id = value;
      // `retry` and unknown fields are ignored.
    }
    return null;
  }
}
