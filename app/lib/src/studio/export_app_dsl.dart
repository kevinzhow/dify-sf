/// app/use-export-app-dsl.ts: `exportAppDsl` (the export behind a promise toast, saved as `<app name>.yml`) and
/// `exportWorkflowAppDsl` (a workflow / chatflow first reads its environment variables: with secrets the caller asks
/// whether to include them). [isExporting] covers the whole lifecycle, the draft check included.
library;

import 'package:flutter/foundation.dart';

import '../design/widgets/toast.dart';
import '../i18n/dify_i18n.dart';

/// `ExportWorkflowAppDslResult`: `downloaded`, `failed` or `confirmation-required` with the secret variables.
typedef ExportAppDslResult = ({String status, List<Map<String, Object?>> secretEnvList});

const ExportAppDslResult _downloaded = (status: 'downloaded', secretEnvList: []);
const ExportAppDslResult _failed = (status: 'failed', secretEnvList: []);

class AppDslExporter extends ChangeNotifier {
  AppDslExporter({required this.exportDsl, required this.environmentVariables, required this.saveDsl});

  /// `GET /apps/{id}/export?include_secret=`.
  Future<String> Function(String appId, {bool includeSecret}) exportDsl;

  /// The app's environment variables (Dify JSON).
  Future<List<Map<String, Object?>>> Function(String appId) environmentVariables;

  /// `downloadBlob`.
  Future<void> Function(String fileName, String yaml) saveDsl;

  int _pending = 0;

  /// A mutation is running (Dify's `isPending`).
  bool get isExporting => _pending > 0;

  Future<T> _run<T>(Future<T> Function() body) async {
    _pending++;
    notifyListeners();
    try {
      return await body();
    } finally {
      _pending--;
      notifyListeners();
    }
  }

  Future<ExportAppDslResult> _download(String appId, String appName, bool includeSecret) async {
    await toast.promise<void>(
      () async {
        final yaml = await exportDsl(appId, includeSecret: includeSecret);
        await saveDsl('$appName.yml', yaml);
      }(),
      loading: DifyI18n.tr('common', 'operation.exporting'),
      success: (_) => DifyToastUpdate(
        title: DifyI18n.tr('common', 'operation.downloadSuccess'),
        timeout: const Duration(seconds: 3),
      ),
      error: (_) => DifyToastUpdate(title: DifyI18n.tr('app', 'exportFailed')),
    );
    return _downloaded;
  }

  /// Exports Agent, Chat and Completion apps without reading a workflow draft; the promise toast owns errors.
  Future<ExportAppDslResult> exportAppDsl({
    required String appId,
    required String appName,
    bool includeSecret = false,
  }) async {
    try {
      return await _run(() => _download(appId, appName, includeSecret));
    } on Object {
      return _failed;
    }
  }

  /// Checks Workflow and Advanced Chat secrets before exporting their DSL.
  Future<ExportAppDslResult> exportWorkflowAppDsl({required String appId, required String appName}) async {
    try {
      return await _run(() async {
        final List<Map<String, Object?>> secrets;
        try {
          secrets = [
            for (final v in await environmentVariables(appId))
              if (v['value_type'] == 'secret') v,
          ];
        } on Object {
          toast.error(DifyI18n.tr('app', 'exportFailed'));
          rethrow;
        }
        if (secrets.isNotEmpty) return (status: 'confirmation-required', secretEnvList: secrets);
        return _download(appId, appName, false);
      });
    } on Object {
      return _failed;
    }
  }
}
