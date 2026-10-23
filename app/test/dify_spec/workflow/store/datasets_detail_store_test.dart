// dify-spec: web/app/components/workflow/store/__tests__/datasets-detail-store.spec.ts
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

DifyJson makeDataset(String id, String name) => {'id': id, 'name': name};

void main() {
  late DatasetsDetailStore store;
  setUp(() => store = DatasetsDetailStore());
  tearDown(() => store.dispose());

  group('DatasetsDetailStore', () {
    group('Initial State', () {
      test('should start with empty datasetsDetail', () {
        expect(store.datasetsDetail.value, isEmpty);
      });
    });

    group('updateDatasetsDetail', () {
      test('should add datasets by id', () {
        final ds1 = makeDataset('ds-1', 'Dataset 1');
        final ds2 = makeDataset('ds-2', 'Dataset 2');

        store.updateDatasetsDetail([ds1, ds2]);

        expect(store.datasetsDetail.value['ds-1'], ds1);
        expect(store.datasetsDetail.value['ds-2'], ds2);
      });

      test('should merge new datasets into existing ones', () {
        final ds1 = makeDataset('ds-1', 'First');
        final ds2 = makeDataset('ds-2', 'Second');
        final ds3 = makeDataset('ds-3', 'Third');

        store.updateDatasetsDetail([ds1, ds2]);
        store.updateDatasetsDetail([ds3]);

        final detail = store.datasetsDetail.value;
        expect(detail['ds-1'], ds1);
        expect(detail['ds-2'], ds2);
        expect(detail['ds-3'], ds3);
      });

      test('should overwrite existing datasets with same id', () {
        store.updateDatasetsDetail([makeDataset('ds-1', 'Version 1')]);
        store.updateDatasetsDetail([makeDataset('ds-1', 'Version 2')]);

        expect(store.datasetsDetail.value['ds-1']!['name'], 'Version 2');
      });

      test('should handle empty array without errors', () {
        store.updateDatasetsDetail([makeDataset('ds-1', 'Test')]);
        store.updateDatasetsDetail([]);

        expect(store.datasetsDetail.value['ds-1']!['name'], 'Test');
      });
    });
  });
}
