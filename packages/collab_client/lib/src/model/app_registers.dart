import 'document.dart';
import 'value.dart';

/// Protocol 1.7: the document-level registers ([Document.app], addressed by ops as node [Document.appNode]) that the
/// server's Dify mapping uses, and Dify's mask for secret environment variables.
///
/// * `environment_variables`, `conversation_variables`: keyed lists; item id = the variable's `id`, item value = the
///   Dify variable object unchanged.
/// * `features`: a map, Dify's `workflow.features` unchanged.
///
/// A secret environment variable (`value_type: secret`) never carries its plaintext in the document: its `value` is
/// the mask and `secret_ref` names the plaintext the server stores (`POST /v1/docs/{doc}/secrets`).
abstract final class AppRegisters {
  static const environmentVariables = 'environment_variables';
  static const conversationVariables = 'conversation_variables';
  static const features = 'features';

  /// Item member of a secret environment variable that names its stored plaintext.
  static const secretRef = 'secret_ref';

  /// Dify's `formatSecret` (web/app/components/workflow/panel/env-panel): longer than 8 (UTF-16 units) -> the first 6,
  /// twelve `*`, the last 2; otherwise twenty `*`. The same mask the server answers.
  static String maskSecret(String secret) =>
      secret.length > 8 ? '${secret.substring(0, 6)}${'*' * 12}${secret.substring(secret.length - 2)}' : '*' * 20;

  /// The variables of the keyed list [key] (`environment_variables` or `conversation_variables`) as Dify JSON, in
  /// order. Empty when the document has no such list.
  static List<Map<String, Object?>> variables(Document doc, String key) => switch (doc.app[key]) {
    VItems(:final items) => [
      for (final i in items)
        if (i.value.toJson() case final Map<String, Object?> m) m,
    ],
    _ => const [],
  };

  /// Dify's `workflow.features` as JSON (empty when absent).
  static Map<String, Object?> featuresOf(Document doc) => switch (doc.app[features]) {
    VMap() && final v => v.toJson()! as Map<String, Object?>,
    _ => const {},
  };
}
