// dify-spec: web/app/components/workflow/utils/__tests__/common.spec.ts
import 'package:dify_sf_app/src/workflow_editor/header/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatWorkflowRunIdentifier', () {
    test('should return fallback text when finishedAt is undefined', () {
      expect(formatWorkflowRunIdentifier(null), ' (Running)');
    });

    test('should return fallback text when finishedAt is 0', () {
      expect(formatWorkflowRunIdentifier(0), ' (Running)');
    });

    test('should capitalize custom fallback text', () {
      expect(formatWorkflowRunIdentifier(null, 'pending'), ' (Pending)');
    });

    test('should format a valid timestamp', () {
      const timestamp = 1704067200; // 2024-01-01 00:00:00 UTC
      expect(formatWorkflowRunIdentifier(timestamp), matches(RegExp(r'^ \(\d{2}:\d{2}:\d{2}( [AP]M)?\)$')));
    });

    test('should handle single-char fallback text', () {
      expect(formatWorkflowRunIdentifier(null, 'x'), ' (X)');
    });
  });
}
