// dify-spec: web/app/components/header/account-setting/model-provider-page/__tests__/index.non-cloud.spec.tsx
import 'package:dify_sf_app/src/settings/model_provider/model_provider_page.dart';
import 'package:dify_sf_app/src/settings/model_provider/system_model_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/model_fakes.dart';
import '../_settings_harness.dart';

void main() {
  group('ModelProviderPage non-cloud branch', () {
    testWidgets('should skip the quota panel when cloud edition is disabled', (t) async {
      final api = RecordingModelsApi()..summaryData = [summaryJson()];
      await renderSettings(
        t,
        const SingleChildScrollView(
          child: SizedBox(width: 1400, child: ModelProviderPage(searchText: '')),
        ),
        env: envOf(api),
      );
      expect(find.byType(SystemModelSelector), findsOneWidget);
      // dify-sf is self-hosted: the page has no quota panel at all.
      expect(find.textContaining('quota', findRichText: true), findsNothing);
    });
  });
}
