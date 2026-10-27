// Portions derived from OpenAI Codex (https://github.com/openai/codex,
// rust-v0.163.0, codex-rs/utils/string/src/truncate.rs,
// codex-rs/utils/output-truncation/src/lib.rs and `TruncationPolicy` in
// codex-rs/protocol/src/protocol.rs), Copyright 2025 OpenAI, licensed under
// the Apache License 2.0. Modified for dify-sf: ported to Dart (lengths are
// UTF-8 byte counts, as in Rust).

/// Codex's output truncation: a byte or token budget, the middle cut with a
/// `…N tokens truncated…` marker, and the `Warning: truncated output` header.
library;

import 'dart:convert';

/// Codex estimates one token per 4 bytes.
const approxBytesPerToken = 4;

/// `approx_token_count`: UTF-8 bytes / 4, rounded up.
int approxTokenCount(String text) =>
    approxTokensFromByteCount(utf8.encode(text).length);

int approxTokensFromByteCount(int bytes) =>
    (bytes + approxBytesPerToken - 1) ~/ approxBytesPerToken;

int approxBytesForTokens(int tokens) => tokens * approxBytesPerToken;

/// `TruncationPolicy`: `Bytes(n)` or `Tokens(n)`.
class TruncationPolicy {
  const TruncationPolicy.bytes(this.limit) : tokens = false;
  const TruncationPolicy.tokens(this.limit) : tokens = true;

  final bool tokens;
  final int limit;

  int get tokenBudget => tokens ? limit : approxTokensFromByteCount(limit);
  int get byteBudget => tokens ? approxBytesForTokens(limit) : limit;

  /// `policy * multiplier` (rounded up).
  TruncationPolicy operator *(double multiplier) {
    final n = (limit * multiplier).ceil();
    return tokens ? TruncationPolicy.tokens(n) : TruncationPolicy.bytes(n);
  }

  Map<String, Object?> toJson() => {
    'mode': tokens ? 'tokens' : 'bytes',
    'limit': limit,
  };

  @override
  bool operator ==(Object other) =>
      other is TruncationPolicy &&
      other.tokens == tokens &&
      other.limit == limit;
  @override
  int get hashCode => Object.hash(tokens, limit);
  @override
  String toString() => tokens ? 'Tokens($limit)' : 'Bytes($limit)';
}

/// The policy of every model in Codex 0.163.0's bundled catalog
/// (`truncation_policy: {"mode": "tokens", "limit": 10000}`).
const catalogTruncationPolicy = TruncationPolicy.tokens(10000);

/// The policy of a model Codex does not know (`model_info.rs`, fallback
/// metadata: `bytes 10000`).
const fallbackTruncationPolicy = TruncationPolicy.bytes(10000);

/// `with_serialization_allowance`: the policy plus 20% for headers and
/// serialization.
TruncationPolicy withSerializationAllowance(TruncationPolicy p) => p * 1.2;

// UTF-8 boundaries over the encoded bytes.
bool _isBoundary(List<int> b, int i) =>
    i <= 0 || i >= b.length || (b[i] & 0xC0) != 0x80;

int _floorBoundary(List<int> b, int i) {
  if (i >= b.length) return b.length;
  var j = i;
  while (j > 0 && !_isBoundary(b, j)) {
    j--;
  }
  return j;
}

int _ceilBoundary(List<int> b, int i) {
  if (i <= 0) return 0;
  var j = i;
  while (j < b.length && !_isBoundary(b, j)) {
    j++;
  }
  return j;
}

String _decode(List<int> b) => utf8.decode(b, allowMalformed: true);

(int, int) _splitBudget(int budget) {
  final left = budget ~/ 2;
  return (left, budget - left);
}

String _marker(bool tokens, int removed) =>
    tokens ? '…$removed tokens truncated…' : '…$removed chars truncated…';

/// `truncate_middle_chars`: keeps at most [maxBytes] from both ends and puts
/// a `…N chars truncated…` marker between them.
String truncateMiddleChars(String s, int maxBytes) =>
    _truncateWithByteEstimate(s, maxBytes, tokens: false);

/// `truncate_middle_with_token_budget`: the text and, when it was cut, the
/// original token count.
(String, int?) truncateMiddleWithTokenBudget(String s, int maxTokens) {
  if (s.isEmpty) return ('', null);
  final bytes = utf8.encode(s);
  if (maxTokens > 0 && bytes.length <= approxBytesForTokens(maxTokens)) {
    return (s, null);
  }
  final truncated = _truncateWithByteEstimate(
    s,
    approxBytesForTokens(maxTokens),
    tokens: true,
  );
  if (truncated == s) return (truncated, null);
  return (truncated, approxTokensFromByteCount(bytes.length));
}

String _truncateWithByteEstimate(
  String s,
  int maxBytes, {
  required bool tokens,
}) {
  if (s.isEmpty) return '';
  final b = utf8.encode(s);
  if (maxBytes == 0) {
    final removed = tokens
        ? approxTokensFromByteCount(b.length)
        : s.runes.length;
    return _marker(tokens, removed);
  }
  if (b.length <= maxBytes) return s;
  final (leftBudget, rightBudget) = _splitBudget(maxBytes);
  final String left;
  final String right;
  int removedChars = 0;
  if (tokens) {
    left = _decode(b.sublist(0, _floorBoundary(b, leftBudget)));
    right = _decode(b.sublist(_ceilBoundary(b, b.length - rightBudget)));
  } else {
    // `split_string`: whole characters that end within the head budget, and
    // those that start at or after the tail start; the rest is counted.
    final tailStartTarget = b.length - rightBudget;
    var prefixEnd = 0;
    var suffixStart = b.length;
    var suffixStarted = false;
    var idx = 0;
    while (idx < b.length) {
      var end = idx + 1;
      while (end < b.length && !_isBoundary(b, end)) {
        end++;
      }
      if (end <= leftBudget) {
        prefixEnd = end;
      } else if (idx >= tailStartTarget) {
        if (!suffixStarted) {
          suffixStart = idx;
          suffixStarted = true;
        }
      } else {
        removedChars++;
      }
      idx = end;
    }
    if (suffixStart < prefixEnd) suffixStart = prefixEnd;
    left = _decode(b.sublist(0, prefixEnd));
    right = _decode(b.sublist(suffixStart));
  }
  final removed = tokens
      ? approxTokensFromByteCount(b.length - maxBytes)
      : removedChars;
  return '$left${_marker(tokens, removed)}$right';
}

/// `truncate_text`.
String truncateText(String content, TruncationPolicy policy) => policy.tokens
    ? truncateMiddleWithTokenBudget(content, policy.limit).$1
    : truncateMiddleChars(content, policy.limit);

/// Rust's `str::lines().count()`.
int rustLineCount(String s) {
  if (s.isEmpty) return 0;
  final n = '\n'.allMatches(s).length;
  return s.endsWith('\n') ? n : n + 1;
}

/// `formatted_truncate_text`: unchanged within the budget, else the
/// warning header, the line count and the middle-truncated text.
String formattedTruncateText(String content, TruncationPolicy policy) {
  if (utf8.encode(content).length <= policy.byteBudget) return content;
  final original = approxTokenCount(content);
  final lines = rustLineCount(content);
  final result = truncateText(content, policy);
  return 'Warning: truncated output (original token count: $original)\n'
      'Total output lines: $lines\n\n$result';
}
