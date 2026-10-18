// dify-spec: web/app/components/base/features/new-feature-panel/moderation/__tests__/moderation-content.spec.tsx
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

const defaultConfig = {'enabled': false, 'preset_response': ''};

final changes = <Json>[];

Future<void> renderContent(
  WidgetTester t, {
  String title = 'Test Title',
  String? info,
  bool showPreset = true,
  Json config = defaultConfig,
}) async {
  changes.clear();
  await render(
    t,
    ModerationContent(title: title, info: info, showPreset: showPreset, config: config, onConfigChange: changes.add),
  );
}

Finder get textbox => find.byType(TextField);

/// A translator answering '' for [empty] keys (the spec's `useTranslation` spy).
class _EmptyFor extends DifyTestTranslator {
  _EmptyFor(this.empty);
  final Set<String> empty;
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      empty.contains(key) ? '' : super.t(ns, key, params);
}

void main() {
  setUp(useDifyTestTranslator);

  group('ModerationContent', () {
    testWidgets('should render the title', (t) async {
      await renderContent(t, title: 'Input Content');
      expect(find.text('Input Content'), findsOneWidget);
    });

    testWidgets('should render info text when provided', (t) async {
      await renderContent(t, info: 'Some info text');
      expect(find.text('Some info text'), findsOneWidget);
    });

    testWidgets('should not render info when not provided', (t) async {
      await renderContent(t);
      expect(byText('Test Title'), findsOneWidget);
      expect(byText('Some info text'), findsNothing);
    });

    testWidgets('should render a switch toggle', (t) async {
      await renderContent(t);
      expect(switchAt(), findsOneWidget);
    });

    testWidgets('should call onConfigChange with enabled true when switch is toggled on', (t) async {
      await renderContent(t);
      await tap(t, switchAt());
      expect(changes.single, {...defaultConfig, 'enabled': true});
    });

    testWidgets('should show preset textarea when enabled and showPreset is true', (t) async {
      await renderContent(t, config: const {'enabled': true, 'preset_response': ''});
      expect(byText(r'feature\.moderation\.modal\.content\.preset'), findsOneWidget);
      expect(textbox, findsOneWidget);
    });

    testWidgets('should not show preset textarea when showPreset is false', (t) async {
      await renderContent(t, config: const {'enabled': true, 'preset_response': ''}, showPreset: false);
      expect(textbox, findsNothing);
    });

    testWidgets('should call onConfigChange when preset_response is changed', (t) async {
      await renderContent(t, config: const {'enabled': true, 'preset_response': ''});
      await t.enterText(textbox, 'test response');
      expect(changes.last, {'enabled': true, 'preset_response': 'test response'});
    });

    testWidgets('should truncate preset_response to 100 characters', (t) async {
      await renderContent(t, config: const {'enabled': true, 'preset_response': ''});
      await t.enterText(textbox, 'a' * 150);
      expect(changes.last, {'enabled': true, 'preset_response': 'a' * 100});
    });

    testWidgets('should display character count', (t) async {
      await renderContent(t, config: const {'enabled': true, 'preset_response': 'hello'});
      final counter = t.widgetList<Text>(find.byType(Text)).map((w) => w.textSpan?.toPlainText()).nonNulls;
      expect(counter, contains('5/100'));
    });

    testWidgets('should fallback to empty placeholder when translation is empty', (t) async {
      DifyI18n.current = _EmptyFor({'feature.moderation.modal.content.placeholder'});
      await renderContent(t, config: const {'enabled': true, 'preset_response': ''});
      expect(t.widget<TextField>(textbox).decoration!.hintText, '');
    });
  });
}
