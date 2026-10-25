// Opt-in real-server differential. Supply the private acceptance directory with
// *.snapshot.json (DocsApi.snapshot wire answer) and *.actual.json (MCP result).
// Private workflows are deliberately not checked into this repository.
import 'dart:convert';
import 'dart:io';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/use_checklist.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['MCP_DIFFERENTIAL_DIR'];
  if (path == null) {
    test('real-server snapshot differential (opt-in)', () {}, skip: 'Set MCP_DIFFERENTIAL_DIR to acceptance captures');
    return;
  }
  final snapshots = Directory(path)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.snapshot.json'))
      .toList();
  test('real-server differential has acceptance captures', () => expect(snapshots, isNotEmpty));
  for (final file in snapshots) {
    test('editor and MCP are identical at the captured server revision: ${file.uri.pathSegments.last}', () async {
      await DifyI18n.load('zh-Hans');
      expect(DifyI18n.tr('workflow', 'errorMsg.duplicateOutputVariable', {'variable': 'probe'}), contains('重复'));
      final snapshot = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final mcp = jsonDecode(File(file.path.replaceFirst('.snapshot.json', '.actual.json')).readAsStringSync()) as Map;
      final doc = Document.fromJson(snapshot['doc']);
      final env = ChecklistEnv(
        appMode: 'workflow',
        language: 'zh_Hans',
        environmentVariables: AppRegisters.variables(doc, AppRegisters.environmentVariables),
        conversationVariables: AppRegisters.variables(doc, AppRegisters.conversationVariables),
      );
      // These captures have no external catalog dependencies. Other graphs must
      // also supply the actual catalog context rather than assuming an empty one.
      final items = [for (final item in computeChecklist(doc, env)) item.toJson()];
      expect(mcp['draft_revision'], snapshot['seq']);
      expect(jsonEncode(mcp['items']), jsonEncode(items));
      expect(mcp['publish_error'], checkBeforePublish(doc, env));
    });
  }
}
