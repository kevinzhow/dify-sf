// dify-spec: web/app/components/app/create-from-dsl-modal/__tests__/dsl-import-warning-description.spec.tsx
import 'package:dify_sf_app/src/studio/create_from_dsl_modal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DSLImportWarningDescription', () {
    // The rows become the import toast's description lines.
    test('should render each distinct warning on its own row', () {
      expect(
        dslImportWarningLines([
          {'message': "Agent skill 'market-research-methodology' was not included."},
          {'message': "Agent skill 'market-research-methodology' was not included."},
          {'message': "Agent skill 'source-backed-market-reporting' was not included."},
          {'message': "Agent tool 'jina_search' requires authorization."},
          {'message': "Agent secret 'SEARCH_TOKEN' must be configured."},
        ]),
        [
          "Agent skill 'market-research-methodology' was not included.",
          "Agent skill 'source-backed-market-reporting' was not included.",
          "Agent tool 'jina_search' requires authorization.",
          '…',
        ],
      );
    });
  });
}
