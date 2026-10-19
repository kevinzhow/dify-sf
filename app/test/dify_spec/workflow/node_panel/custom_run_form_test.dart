// dify-spec: web/app/components/workflow/nodes/_base/components/workflow-panel/__tests__/helpers.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/run/ui/node_run_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('workflow-panel helpers', () {
    group('custom run form fallback', () {
      test('should return null for unsupported custom run form nodes', () {
        var built = false;
        expect(
          getCustomRunForm(
            nodeType: 'code',
            dataSourceForm: () {
              built = true;
              return const Text('data source');
            },
          ),
          isNull,
        );
        expect(built, isFalse);
        expect(getCustomRunForm(nodeType: 'datasource', dataSourceForm: () => const Text('data source')), isA<Text>());
      });
    });
  });
}
