// dify-spec: web/app/components/header/account-setting/model-provider-page/__tests__/atoms.spec.tsx
import 'package:dify_sf_app/src/workflow/workspace_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// The atoms are WorkspaceModels' expanded state: isExpanded (useModelProviderListExpanded), setExpanded
/// (useSetModelProviderListExpanded) and setExpanded(true) (useExpandModelProviderList); one store per Provider.
void main() {
  group('atoms', () {
    late WorkspaceModels store;
    setUp(() => store = WorkspaceModels(null, fixedLanguage: 'en_US'));
    tearDown(() => store.dispose());

    group('useModelProviderListExpanded', () {
      test('should return false when provider has not been expanded', () {
        expect(store.isExpanded('openai'), isFalse);
      });

      test('should return false for any unknown provider name', () {
        expect(store.isExpanded('nonexistent-provider'), isFalse);
      });

      test('should return true when provider has been expanded via setter', () {
        store.setExpanded('openai', true);
        expect(store.isExpanded('openai'), isTrue);
      });
    });

    group('useSetModelProviderListExpanded', () {
      test('should expand a provider when called with true', () {
        store.setExpanded('anthropic', true);
        expect(store.isExpanded('anthropic'), isTrue);
      });

      test('should collapse a provider when called with false', () {
        store.setExpanded('anthropic', true);
        store.setExpanded('anthropic', false);
        expect(store.isExpanded('anthropic'), isFalse);
      });

      test('should not affect other providers when setting one', () {
        store.setExpanded('openai', true);
        expect(store.isExpanded('openai'), isTrue);
        expect(store.isExpanded('anthropic'), isFalse);
      });
    });

    group('useExpandModelProviderList', () {
      test('should expand the specified provider', () {
        store.setExpanded('google', true);
        expect(store.isExpanded('google'), isTrue);
      });

      test('should expand multiple providers independently', () {
        store.setExpanded('openai', true);
        store.setExpanded('anthropic', true);
        expect(store.isExpanded('openai'), isTrue);
        expect(store.isExpanded('anthropic'), isTrue);
      });

      test('should not collapse already expanded providers when expanding another', () {
        store.setExpanded('openai', true);
        store.setExpanded('anthropic', true);
        expect(store.isExpanded('openai'), isTrue);
      });
    });

    group('Cross-hook interaction', () {
      test('should reflect state set by useSetModelProviderListExpanded in useModelProviderListExpanded', () {
        store.setExpanded('openai', true);
        expect(store.isExpanded('openai'), isTrue);
      });

      test('should reflect state set by useExpandModelProviderList in useModelProviderListExpanded', () {
        store.setExpanded('anthropic', true);
        expect(store.isExpanded('anthropic'), isTrue);
      });

      test(
        'should allow useSetModelProviderListExpanded to collapse a provider expanded by useExpandModelProviderList',
        () {
          store.setExpanded('openai', true);
          expect(store.isExpanded('openai'), isTrue);
          store.setExpanded('openai', false);
          expect(store.isExpanded('openai'), isFalse);
        },
      );
    });

    group('selectAtom granularity', () {
      test('should not cause unrelated provider reads to change when one provider is toggled', () {
        final anthropicBefore = store.isExpanded('anthropic');
        final googleBefore = store.isExpanded('google');
        store.setExpanded('openai', true);
        expect(store.isExpanded('openai'), isTrue);
        expect(store.isExpanded('anthropic'), anthropicBefore);
        expect(store.isExpanded('google'), googleBefore);
      });

      test('should keep individual provider states independent across multiple expansions and collapses', () {
        store
          ..setExpanded('openai', true)
          ..setExpanded('anthropic', true)
          ..setExpanded('openai', false);
        expect(store.isExpanded('openai'), isFalse);
        expect(store.isExpanded('anthropic'), isTrue);
      });
    });

    group('Provider isolation', () {
      test('should have independent state across different Provider instances', () {
        final other = WorkspaceModels(null, fixedLanguage: 'en_US');
        addTearDown(other.dispose);
        store.setExpanded('openai', true);
        expect(store.isExpanded('openai'), isTrue);
        expect(other.isExpanded('openai'), isFalse);
      });
    });
  });
}
