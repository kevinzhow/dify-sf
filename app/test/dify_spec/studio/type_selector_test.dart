// dify-spec: web/app/components/app/type-selector/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/studio/app_icons.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_test_i18n.dart';
import 'harness.dart';

void main() {
  group('AppTypeLabel', () {
    setUp(useDifyTestTranslator);
    for (final (type, expected) in const [
      ('chat', 'app.typeSelector.chatbot'),
      ('agent-chat', 'app.typeSelector.agent'),
      ('completion', 'app.typeSelector.completion'),
      ('advanced-chat', 'app.typeSelector.advanced'),
      ('workflow', 'app.typeSelector.workflow'),
    ]) {
      test('should render label %s for type %s', () => expect(appTypeLabel(type), expected));
    }
    test('should render empty label for unknown type', () => expect(appTypeLabel('unknown'), ''));
  });

  group('AppTypeIcon', () {
    for (final type in const ['chat', 'agent-chat', 'completion', 'advanced-chat', 'workflow']) {
      testWidgets('should render icon for type %s', (t) async {
        await renderMembers(t, Center(child: AppTypeIcon(type: type)));
        expect(find.byKey(ValueKey('app-type-icon-$type')), findsOneWidget);
        expect(find.descendant(of: find.byType(AppTypeIcon), matching: find.byType(SvgPicture)), findsOneWidget);
      });
    }
    testWidgets('should render nothing for unknown type', (t) async {
      await renderMembers(t, const Center(child: AppTypeIcon(type: 'unknown')));
      expect(find.descendant(of: find.byType(AppTypeIcon), matching: find.byType(SvgPicture)), findsNothing);
      expect(t.getSize(find.byType(AppTypeIcon)), Size.zero);
    });
  });
}
