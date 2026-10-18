// dify-spec: web/app/components/base/features/__tests__/store.spec.ts
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter_test/flutter_test.dart';

bool? enabled(FeaturesStore s, String key) => featureMap(s.features.value, key)['enabled'] as bool?;
Map<String, Object?> image(FeaturesStore s) => featureMap(featureMap(s.features.value, 'file'), 'image');

void main() {
  group('createFeaturesStore', () {
    group('Default State', () {
      test('should create a store with moreLikeThis disabled by default', () {
        expect(enabled(FeaturesStore(), 'moreLikeThis'), false);
      });
      test('should create a store with opening disabled by default', () {
        expect(enabled(FeaturesStore(), 'opening'), false);
      });
      test('should create a store with suggested disabled by default', () {
        expect(enabled(FeaturesStore(), 'suggested'), false);
      });
      test('should create a store with text2speech disabled by default', () {
        expect(enabled(FeaturesStore(), 'text2speech'), false);
      });
      test('should create a store with speech2text disabled by default', () {
        expect(enabled(FeaturesStore(), 'speech2text'), false);
      });
      test('should create a store with citation disabled by default', () {
        expect(enabled(FeaturesStore(), 'citation'), false);
      });
      test('should create a store with moderation disabled by default', () {
        expect(enabled(FeaturesStore(), 'moderation'), false);
      });
      test('should create a store with annotationReply disabled by default', () {
        expect(enabled(FeaturesStore(), 'annotationReply'), false);
      });
    });

    group('File Image Initialization', () {
      test('should initialize file image enabled as false', () {
        expect(image(FeaturesStore())['enabled'], false);
      });
      test('should initialize file image detail as high resolution', () {
        expect(image(FeaturesStore())['detail'], 'high');
      });
      test('should initialize file image number_limits as 3', () {
        expect(image(FeaturesStore())['number_limits'], 3);
      });
      test('should initialize file image transfer_methods with local and remote options', () {
        expect(image(FeaturesStore())['transfer_methods'], [TransferMethod.localFile, TransferMethod.remoteUrl]);
      });
    });

    group('Feature Merging', () {
      test('should merge initial moreLikeThis enabled state', () {
        final s = FeaturesStore(
          features: {
            'moreLikeThis': {'enabled': true},
          },
        );
        expect(enabled(s, 'moreLikeThis'), true);
      });
      test('should merge initial opening enabled state', () {
        final s = FeaturesStore(
          features: {
            'opening': {'enabled': true},
          },
        );
        expect(enabled(s, 'opening'), true);
      });
      test('should preserve additional properties when merging', () {
        final s = FeaturesStore(
          features: {
            'opening': {'enabled': true, 'opening_statement': 'Hello!'},
          },
        );
        expect(enabled(s, 'opening'), true);
        expect(featureMap(s.features.value, 'opening')['opening_statement'], 'Hello!');
      });
    });

    group('setFeatures', () {
      test('should update moreLikeThis feature via setFeatures', () {
        final s = FeaturesStore()
          ..setFeatures({
            'moreLikeThis': {'enabled': true},
          });
        expect(enabled(s, 'moreLikeThis'), true);
      });
      test('should update multiple features via setFeatures', () {
        final s = FeaturesStore()
          ..setFeatures({
            'moreLikeThis': {'enabled': true},
            'opening': {'enabled': true},
          });
        expect(enabled(s, 'moreLikeThis'), true);
        expect(enabled(s, 'opening'), true);
      });
    });

    group('showFeaturesModal', () {
      test('should initialize showFeaturesModal as false', () {
        expect(FeaturesStore().showFeaturesModal.value, false);
      });
      test('should toggle showFeaturesModal to true', () {
        final s = FeaturesStore()..setShowFeaturesModal(true);
        expect(s.showFeaturesModal.value, true);
      });
      test('should toggle showFeaturesModal to false', () {
        final s = FeaturesStore()
          ..setShowFeaturesModal(true)
          ..setShowFeaturesModal(false);
        expect(s.showFeaturesModal.value, false);
      });
    });
  });
}
