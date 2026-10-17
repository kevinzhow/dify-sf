// dify-spec: web/app/components/header/account-setting/model-provider-page/provider-added-card/__tests__/use-trial-credits.spec.ts
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

/// The hook's result as a map, to compare like `toEqual`.
Map<String, Object?> asMap(TrialCredits c) => {
  'credits': c.credits,
  'usedCredits': c.usedCredits,
  'totalCredits': c.totalCredits,
  'isUnlimited': c.isUnlimited,
  'isExhausted': c.isExhausted,
  'isLoading': c.isLoading,
  'exhaustedAt': c.exhaustedAt,
  'nextCreditResetDate': c.nextCreditResetDate,
};

void main() {
  group('useTrialCredits', () {
    group('when workspace data is available', () {
      test('should return the remaining credits and reset date', () {
        final result = TrialCredits.select({
          'quota_limit': 100,
          'quota_used': 40,
          'remaining_credits': 60,
          'is_exhausted': false,
          'exhausted_at': null,
          'next_credit_reset_date': 1775001600,
        });
        expect(asMap(result), {
          'credits': 60,
          'usedCredits': 40,
          'totalCredits': 100,
          'isUnlimited': false,
          'isExhausted': false,
          'isLoading': false,
          'exhaustedAt': null,
          'nextCreditResetDate': 1775001600,
        });
      });

      test('should keep the hook out of loading state during a background refetch', () {
        final result = TrialCredits.select({
          'quota_limit': 80,
          'quota_used': 20,
          'remaining_credits': 60,
          'is_exhausted': false,
          'next_credit_reset_date': 1777593600,
        }, isPending: true);
        expect(result.isLoading, isFalse);
        expect(result.credits, 60);
        expect(result.usedCredits, 20);
        expect(result.isUnlimited, isFalse);
        expect(result.isExhausted, isFalse);
      });
    });

    group('when workspace data is missing or exhausted', () {
      test('should report loading while the first workspace request is pending', () {
        expect(asMap(TrialCredits.select(null, isPending: true)), {
          'credits': 0,
          'usedCredits': 0,
          'totalCredits': 0,
          'isUnlimited': false,
          'isExhausted': true,
          'isLoading': true,
          'exhaustedAt': null,
          'nextCreditResetDate': null,
        });
      });

      test('should use the backend exhausted state', () {
        final result = TrialCredits.select({
          'quota_limit': 10,
          'quota_used': 10,
          'remaining_credits': 0,
          'is_exhausted': true,
          'exhausted_at': 1772323200,
          'next_credit_reset_date': null,
        });
        expect(result.credits, 0);
        expect(result.usedCredits, 10);
        expect(result.isExhausted, isTrue);
        expect(result.exhaustedAt, 1772323200);
      });

      test('should preserve the unlimited state without interpreting sentinel credits as usage', () {
        final result = TrialCredits.select({
          'quota_limit': -1,
          'quota_used': 999,
          'remaining_credits': -1,
          'is_unlimited': true,
          'is_exhausted': false,
          'exhausted_at': null,
          'next_credit_reset_date': null,
        });
        expect(result.credits, -1);
        expect(result.usedCredits, 999);
        expect(result.totalCredits, -1);
        expect(result.isUnlimited, isTrue);
        expect(result.isExhausted, isFalse);
      });
    });
  });
}
