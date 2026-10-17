/// What the Knowledge Base panel needs from the host (Dify's console queries and browser state).
library;

import 'package:flutter/widgets.dart';

import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/model_catalog.dart';
import '../../../../../workflow/output_vars.dart' show RagVariable;

/// The process-wide "dismissed" flag of the multimodal retrieval tip when the host keeps none (Dify keeps it in
/// local storage).
final _dismissed = ValueNotifier<bool>(false);

/// The host's data for the Knowledge Base panel below it; without one the panel works on an empty workspace.
class KnowledgeBaseHost extends InheritedWidget {
  KnowledgeBaseHost({
    super.key,
    required super.child,
    this.catalog = ModelCatalog.empty,
    this.providerModels,
    this.topKMax = 10,
    this.ragVariables = const [],
    ValueNotifier<bool>? multimodalTipDismissed,
    this.docLink,
  }) : multimodalTipDismissed = multimodalTipDismissed ?? _dismissed;

  /// The model lists by type (`text-embedding`, `rerank`, `llm`), the installed providers (summary) and the
  /// deployment edition (Summary Auto-Gen is for COMMUNITY and ENTERPRISE).
  final ModelCatalog catalog;

  /// `GET workspaces/current/model-providers/{provider}/models` (the embedding checks prefer it); null while unknown.
  final List<ModelItem>? Function(String provider)? providerModels;

  /// `NEXT_PUBLIC_TOP_K_MAX_VALUE`.
  final int topKMax;

  /// The pipeline's input fields (for the chunks picker's RAG variables).
  final List<RagVariable> ragVariables;

  /// Whether the multimodal retrieval tip was dismissed (persisted by the host).
  final ValueNotifier<bool> multimodalTipDismissed;

  /// useDocLink; the default is Dify's docs site in the UI language for [product].
  final String Function(String path)? docLink;

  static final _empty = KnowledgeBaseHost(child: const SizedBox.shrink());

  static KnowledgeBaseHost of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<KnowledgeBaseHost>() ?? _empty;

  bool get isNonCloudEdition => const {'COMMUNITY', 'ENTERPRISE'}.contains(catalog.deploymentEdition);

  /// The docs URL of [path] (`/use-dify/...`).
  String link(String path, {String product = 'self-host'}) {
    if (docLink != null) return docLink!(path);
    final language = switch (DifyI18n.current) {
      DifyI18n(:final language) => language,
      _ => DifyI18n.fallbackLanguage,
    };
    final docLanguage = const {'zh-Hans': 'zh', 'ja-JP': 'ja'}[language] ?? 'en';
    return 'https://docs.dify.ai/$docLanguage/$product$path';
  }

  @override
  bool updateShouldNotify(KnowledgeBaseHost old) =>
      catalog != old.catalog ||
      providerModels != old.providerModels ||
      topKMax != old.topKMax ||
      ragVariables != old.ragVariables ||
      multimodalTipDismissed != old.multimodalTipDismissed ||
      docLink != old.docLink;
}
