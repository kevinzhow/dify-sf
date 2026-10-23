import 'package:flutter/foundation.dart';

import 'workflow_store.dart';

/// workflow/datasets-detail-store/store.ts: the knowledge bases the workflow's nodes refer to, by id (Dify's
/// DataSet JSON).
class DatasetsDetailStore {
  final datasetsDetail = ValueNotifier<Map<String, DifyJson>>(const {});

  /// Adds [datasets] by id, replacing any with the same id and keeping the rest.
  void updateDatasetsDetail(List<DifyJson> datasets) =>
      datasetsDetail.value = {...datasetsDetail.value, for (final d in datasets) d['id'] as String: d};

  void dispose() => datasetsDetail.dispose();
}
