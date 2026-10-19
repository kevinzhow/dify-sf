// dify-spec: web/app/components/integrations/__tests__/page.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/settings/integrations_page.dart';
import 'package:dify_sf_app/src/settings/model_provider/model_provider_page.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/model_fakes.dart';
import '../model_provider/_settings_harness.dart';

Future<void> renderIntegrationsPage(WidgetTester t) => renderSettings(
  t,
  const SizedBox(width: 1400, height: 900, child: IntegrationsPage()),
  env: envOf(RecordingModelsApi()..summaryData = [summaryJson()]),
);

void main() {
  group('IntegrationsPage', () {
    testWidgets('defaults to the model provider section when no query is provided', (t) async {
      await renderIntegrationsPage(t);
      expect(find.byType(ModelProviderPage), findsOneWidget);
      // The sidebar entry and the section's title.
      expect(find.text('common.settings.provider'), findsNWidgets(2));
      expect(find.text('common.settings.integrations'), findsOneWidget);
    });

    testWidgets('renders the model provider section from the section query', (t) async {
      await renderIntegrationsPage(t);
      expect(find.byType(ModelProviderPage), findsOneWidget);
      expect(find.byKey(const ValueKey('integrations-section-title')), findsOneWidget);
      expect(find.text('common.settings.provider'), findsNWidgets(2));
      final nav = find.semantics.byPredicate(
        (n) => n.label == 'common.settings.provider' && n.getSemanticsData().flagsCollection.isButton,
      );
      expect(nav, findsOneWidget);
      // The current section (Dify's `aria-current`): the active background.
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && (w.decoration as BoxDecoration?)?.color == DifyColors.stateBaseActive,
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('model-provider-search')), findsOneWidget);
    });

    testWidgets('aligns model provider headers to the unified content frame', (t) async {
      await renderIntegrationsPage(t);
      expect(find.text('common.modelProvider.pageDesc'), findsOneWidget);
      final link = find.semantics.byPredicate(
        (n) => n.label == 'common.modelProvider.learnMore' && n.getSemanticsData().flagsCollection.isLink,
      );
      expect(link, findsOneWidget);
    });
  });
}
