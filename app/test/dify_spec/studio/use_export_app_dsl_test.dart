// dify-spec: web/app/components/app/__tests__/use-export-app-dsl.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/studio/export_app_dsl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_test_i18n.dart';

/// The exporter over recording fakes (Dify's mocked console client, `downloadBlob` and toast).
class _Rig {
  final order = <String>[];
  final exports = <({String id, bool includeSecret})>[];
  final downloads = <({String name, String yaml})>[];
  final envCalls = <String>[];
  Future<String> Function() exportAnswer = () async => 'kind: app\n';
  Future<List<Map<String, Object?>>> Function() envAnswer = () async => const [];

  late final exporter = AppDslExporter(
    exportDsl: (id, {includeSecret = false}) {
      order.add('export');
      exports.add((id: id, includeSecret: includeSecret));
      return exportAnswer();
    },
    environmentVariables: (id) {
      order.add('env');
      envCalls.add(id);
      return envAnswer();
    },
    saveDsl: (name, yaml) async => downloads.add((name: name, yaml: yaml)),
  );
}

void main() {
  setUp(useDifyTestTranslator);
  tearDown(() => defaultToastManager.close());

  group('useExportAppDsl', () {
    test('exports through the generated client and hands the YAML file to the browser', () async {
      final rig = _Rig()..exportAnswer = () async => 'kind: app\nversion: 0.1.5\n';
      final result = await rig.exporter.exportAppDsl(
        appId: '4f6ae8f8-86c8-4ec8-82ef-e27f5932692b',
        appName: 'Support Agent',
      );
      expect(result.status, 'downloaded');
      expect(rig.exports.single, (id: '4f6ae8f8-86c8-4ec8-82ef-e27f5932692b', includeSecret: false));
      expect(rig.envCalls, isEmpty);
      expect(rig.downloads.single, (name: 'Support Agent.yml', yaml: 'kind: app\nversion: 0.1.5\n'));
    });

    test('exposes pending state until the export command settles', () async {
      final rig = _Rig();
      final answer = Completer<String>();
      rig.exportAnswer = () => answer.future;
      final pending = rig.exporter.exportAppDsl(
        appId: '4f6ae8f8-86c8-4ec8-82ef-e27f5932692b',
        appName: 'Support Agent',
        includeSecret: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(rig.exporter.isExporting, isTrue);
      answer.complete('kind: app\n');
      await pending;
      expect(rig.exporter.isExporting, isFalse);
      expect(rig.exports.single.includeSecret, isTrue);
    });

    test('lets the promise toast own errors without triggering a download', () async {
      final rig = _Rig()..exportAnswer = () async => throw Exception('Export failed');
      final result = await rig.exporter.exportAppDsl(
        appId: '4f6ae8f8-86c8-4ec8-82ef-e27f5932692b',
        appName: 'Support Agent',
      );
      expect(result.status, 'failed');
      expect(rig.downloads, isEmpty);
    });
  });

  group('useExportWorkflowAppDsl', () {
    test('checks generated workflow environment variables before exporting', () async {
      final rig = _Rig();
      final result = await rig.exporter.exportWorkflowAppDsl(appId: 'workflow-app-id', appName: 'Support Workflow');
      expect(result.status, 'downloaded');
      expect(rig.envCalls, ['workflow-app-id']);
      expect(rig.order, ['env', 'export']);
      expect(rig.downloads.single.name, 'Support Workflow.yml');
    });

    test('returns generated secret variables without starting a download', () async {
      const secretEnvList = [
        {'id': 'secret-id', 'name': 'API_KEY', 'value': 'secret', 'value_type': 'secret'},
      ];
      final rig = _Rig()..envAnswer = () async => secretEnvList;
      final result = await rig.exporter.exportWorkflowAppDsl(appId: 'workflow-app-id', appName: 'Support Workflow');
      expect(result.status, 'confirmation-required');
      expect(result.secretEnvList, secretEnvList);
      expect(rig.exports, isEmpty);
      expect(rig.downloads, isEmpty);
    });

    testWidgets('owns workflow preflight errors without starting a download', (t) async {
      final rig = _Rig()..envAnswer = () async => throw Exception('Draft unavailable');
      await t.pumpWidget(
        const MaterialApp(
          home: Stack(children: [DifyToastHost(timeout: Duration.zero)]),
        ),
      );
      final result = await rig.exporter.exportWorkflowAppDsl(appId: 'workflow-app-id', appName: 'Support Workflow');
      await t.pump();
      expect(result.status, 'failed');
      expect(find.text('app.exportFailed'), findsOneWidget);
      expect(rig.exports, isEmpty);
    });

    test('keeps one pending lifecycle across the draft check and export', () async {
      final rig = _Rig();
      final env = Completer<List<Map<String, Object?>>>();
      final answer = Completer<String>();
      rig
        ..envAnswer = (() => env.future)
        ..exportAnswer = (() => answer.future);
      final pending = rig.exporter.exportWorkflowAppDsl(appId: 'workflow-app-id', appName: 'Support Workflow');
      await Future<void>.delayed(Duration.zero);
      expect(rig.exporter.isExporting, isTrue);
      expect(rig.exports, isEmpty);
      env.complete(const []);
      await Future<void>.delayed(Duration.zero);
      expect(rig.exports, hasLength(1));
      expect(rig.exporter.isExporting, isTrue);
      answer.complete('kind: app\n');
      await pending;
      expect(rig.exporter.isExporting, isFalse);
    });
  });
}
