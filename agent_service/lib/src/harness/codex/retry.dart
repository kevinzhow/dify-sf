// Portions derived from OpenAI Codex (https://github.com/openai/codex,
// rust-v0.163.0, codex-rs/async-utils/src/backoff.rs,
// codex-rs/codex-client/src/retry.rs, codex-rs/protocol/src/error.rs
// (`retry_delay`), codex-rs/codex-api/src/api_bridge.rs,
// codex-rs/core/src/responses_retry.rs and the defaults in
// codex-rs/model-provider-info/src/lib.rs), Copyright 2025 OpenAI, licensed
// under the Apache License 2.0. Modified for dify-sf: the errors are the
// inner gateway's (HTTP statuses, Dify error envelopes); see
// third_party/codex/PATCHES.md and docs/agent-v2.md, "Harness styles".

/// Codex's model-call retries: a request layer (HTTP 5xx and transport
/// failures, 4 retries) inside a stream layer (retryable errors, 5
/// retries), both with exponential backoff from 200 ms and ±10% jitter, a
/// server `Retry-After` taking precedence.
library;

import 'dart:math';

/// `DEFAULT_REQUEST_MAX_RETRIES`.
const requestMaxRetries = 4;

/// `DEFAULT_STREAM_MAX_RETRIES`.
const streamMaxRetries = 5;

/// The request layer's `base_delay` and the stream layer's initial delay.
const retryBaseDelay = Duration(milliseconds: 200);

/// `backoff` of `async-utils` (stream layer): 200 ms × 2^(attempt-1), ±10%
/// (attempts 0 and 1 use 200 ms).
Duration streamBackoff(int attempt, Random random) {
  final exp = pow(2, max(0, attempt - 1));
  final base = (200 * exp).toInt();
  final jitter = 0.9 + random.nextDouble() * 0.2;
  return Duration(milliseconds: (base * jitter).toInt());
}

/// `backoff` of `codex-client` (request layer): attempt 0 is the base;
/// then base × 2^(attempt-1), ±10%.
Duration requestBackoff(int attempt, Random random) {
  if (attempt == 0) return retryBaseDelay;
  final raw = retryBaseDelay.inMilliseconds * (1 << (attempt - 1));
  final jitter = 0.9 + random.nextDouble() * 0.2;
  return Duration(milliseconds: (raw * jitter).toInt());
}

/// The kind of a failed model call, after Codex's `CodexErrorDetails`.
enum ModelFailureKind {
  /// Connection refused, reset or timed out (`ConnectionFailed`): retried
  /// by both layers.
  connection,

  /// An HTTP 5xx answer other than an overload (`InternalServerError`,
  /// `UnexpectedStatus`): retried by both layers.
  serverError,

  /// `ServerOverloaded`: retried only when the server gave `Retry-After`.
  overloaded,

  /// The stream broke or ended without its final chunk, or the provider
  /// failed it (`Stream`): retried by the stream layer.
  stream,

  /// `RateLimitExceeded`: retried by the stream layer.
  rateLimited,

  /// Quota, usage limits (`QuotaExceeded`, `UsageLimitReached`): terminal.
  quota,

  /// The request itself is wrong (`InvalidRequest`, the gateway's refusals):
  /// terminal.
  invalidRequest,
}

/// A failed model call attempt.
class ModelCallFailure implements Exception {
  ModelCallFailure(
    this.kind,
    this.message, {
    this.errorType = 'model_error',
    this.retryAfter,
    this.status,
    this.beforeStream = false,
  });

  final ModelFailureKind kind;
  final String message;

  /// The run's `error_type` if this ends the run (`model_error`,
  /// `model_quota`, `file_error`).
  final String errorType;

  /// The server's `Retry-After`, if any.
  final Duration? retryAfter;

  /// The HTTP status of the gateway's answer, if it answered with one.
  final int? status;

  /// The failure happened before the response stream started (the request
  /// layer may retry it).
  final bool beforeStream;

  /// `RetryOn::should_retry` of the request layer (`retry_429: false`,
  /// `retry_5xx: true`, `retry_transport: true`).
  bool get requestRetryable =>
      beforeStream &&
      (kind == ModelFailureKind.connection ||
          kind == ModelFailureKind.serverError ||
          kind == ModelFailureKind.overloaded);

  /// `CodexErr::retry_delay` of the stream layer: null for a terminal
  /// error.
  Duration? streamRetryDelay(int retryCount, Random random) => switch (kind) {
    ModelFailureKind.quota || ModelFailureKind.invalidRequest => null,
    ModelFailureKind.overloaded => retryAfter,
    _ => retryAfter ?? streamBackoff(retryCount, random),
  };

  @override
  String toString() => 'ModelCallFailure(${kind.name}: $message)';
}

/// Dify error types (of the plugin daemon's error envelopes) that mean the
/// request cannot succeed as sent.
const terminalDifyErrorTypes = {
  'InvokeAuthorizationError',
  'InvokeBadRequestError',
  'CredentialsValidateFailedError',
};

/// Classifies an error envelope of the gateway's stream (`code` -429 or
/// -500, the Dify `error_type`).
ModelFailureKind classifyEnvelope(int code, String? difyErrorType) {
  final t = difyErrorType ?? '';
  if (t.contains('RateLimit')) return ModelFailureKind.rateLimited;
  if (t.contains('Quota')) return ModelFailureKind.quota;
  if (terminalDifyErrorTypes.contains(t)) {
    return ModelFailureKind.invalidRequest;
  }
  // Dify maps quota and rate limits to -429; without a rate-limit type it
  // is the quota (today's `model_quota`).
  if (code == -429) return ModelFailureKind.quota;
  return ModelFailureKind.stream;
}

/// Classifies a non-200 answer of the gateway. The gateway's own refusals
/// (400, 401, 403, 404, 409, 410, 413, 422, and 429 `agent_call_limit`)
/// are terminal; 5xx are retried as Codex retries them.
ModelFailureKind classifyHttpStatus(int status, {String? errorCode}) {
  if (status == 503 && errorCode == 'server_is_overloaded') {
    return ModelFailureKind.overloaded;
  }
  if (status >= 500) return ModelFailureKind.serverError;
  if (status == 429) return ModelFailureKind.quota;
  return ModelFailureKind.invalidRequest;
}

/// Parses `Retry-After` (seconds, possibly fractional).
Duration? parseRetryAfter(String? header) {
  if (header == null) return null;
  final seconds = double.tryParse(header.trim());
  if (seconds == null || seconds < 0) return null;
  return Duration(milliseconds: (seconds * 1000).round());
}
