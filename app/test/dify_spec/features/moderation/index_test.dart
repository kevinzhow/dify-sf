// dify-spec: web/app/components/base/features/new-feature-panel/moderation/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

/// setShowModerationSettingModal.
final modalCalls = <ModerationModalRequest>[];

Future<void> renderModeration(
  WidgetTester t, {
  bool disabled = false,
  OnFeaturesChange? onChange,
  Json? moderation,
  List<Json> extensions = const [],
}) => render(
  t,
  Moderation(disabled: disabled, onChange: onChange),
  features: {...specDefaultFeatures, 'moderation': ?moderation},
  services: FeaturesServices(
    codeBasedExtensions: extensions,
    showModerationSettingModal: (_, r) => modalCalls.add(r),
  ),
);

const title = r'feature\.moderation\.title';

Future<void> openSettings(WidgetTester t) async {
  await hover(t, card(title));
  await tap(t, byText(r'operation\.settings'));
}

void main() {
  setUp(() {
    useDifyTestTranslator();
    modalCalls.clear();
  });

  group('Moderation', () {
    testWidgets('should render the moderation title', (t) async {
      await renderModeration(t);
      expect(byText(title), findsOneWidget);
    });

    testWidgets('should render description when not enabled', (t) async {
      await renderModeration(t);
      expect(byText(r'feature\.moderation\.description'), findsOneWidget);
    });

    testWidgets('should render a switch toggle', (t) async {
      await renderModeration(t);
      expect(switchAt(), findsOneWidget);
    });

    testWidgets('should open moderation setting modal when enabled without type', (t) async {
      await renderModeration(t);
      await tap(t, switchAt());
      expect(modalCalls, isNotEmpty);
    });

    testWidgets('should show provider info when enabled with openai_moderation type', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'openai_moderation',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
            'outputs_config': {'enabled': false, 'preset_response': ''},
          },
        },
      );
      expect(byText(r'feature\.moderation\.modal\.provider\.openai'), findsOneWidget);
    });

    testWidgets('should show provider info when enabled with keywords type', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
            'outputs_config': {'enabled': false, 'preset_response': ''},
          },
        },
      );
      expect(byText(r'feature\.moderation\.modal\.provider\.keywords'), findsOneWidget);
    });

    testWidgets('should show allEnabled when both inputs and outputs are enabled', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
            'outputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      expect(byText(r'feature\.moderation\.allEnabled'), findsOneWidget);
    });

    testWidgets('should show inputEnabled when only inputs are enabled', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
            'outputs_config': {'enabled': false, 'preset_response': ''},
          },
        },
      );
      expect(byText(r'feature\.moderation\.inputEnabled'), findsOneWidget);
    });

    testWidgets('should show outputEnabled when only outputs are enabled', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': false, 'preset_response': ''},
            'outputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      expect(byText(r'feature\.moderation\.outputEnabled'), findsOneWidget);
    });

    testWidgets('should show settings button when hovering over enabled feature', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      await hover(t, card(title));
      expect(byText(r'operation\.settings'), findsOneWidget);
    });

    testWidgets('should open moderation modal when settings button is clicked', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      await openSettings(t);
      expect(modalCalls, isNotEmpty);
    });

    testWidgets('should not open modal when disabled', (t) async {
      await renderModeration(
        t,
        disabled: true,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      await openSettings(t);
      expect(modalCalls, isEmpty);
    });

    testWidgets('should show api provider label when type is api', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'api',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      expect(byText(r'apiBasedExtension\.selector\.title'), findsOneWidget);
    });

    testWidgets('should disable moderation and call onChange when switch is toggled off', (t) async {
      final onChange = OnChangeSpy();
      await renderModeration(
        t,
        onChange: onChange.call,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      await tap(t, switchAt());
      expect(onChange.called, isTrue);
      expect(featureMap(featuresStore.features.value, 'moderation'), {'enabled': false});
    });

    testWidgets('should open modal with default config when enabling without existing type', (t) async {
      final onChange = OnChangeSpy();
      await renderModeration(t, onChange: onChange.call);
      await tap(t, switchAt());
      expect(modalCalls.single.payload['enabled'], true);
      expect(modalCalls.single.payload['type'], 'keywords');
    });

    testWidgets('should invoke onSaveCallback from modal and update features', (t) async {
      await renderModeration(t);
      await tap(t, switchAt());
      expect(modalCalls.single.onSaveCallback, isNotNull);
      expect(modalCalls.single.onCancelCallback, isNotNull);
    });

    testWidgets('should invoke onCancelCallback from settings modal', (t) async {
      final onChange = OnChangeSpy();
      await renderModeration(
        t,
        onChange: onChange.call,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      await openSettings(t);
      modalCalls.single.onCancelCallback();
      expect(onChange.called, isTrue);
    });

    testWidgets('should invoke onCancelCallback from settings modal without onChange', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      await openSettings(t);
      modalCalls.single.onCancelCallback();
      expect(t.takeException(), isNull);
    });

    testWidgets('should invoke onSaveCallback from settings modal', (t) async {
      final onChange = OnChangeSpy();
      await renderModeration(
        t,
        onChange: onChange.call,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      await openSettings(t);
      modalCalls.single.onSaveCallback({'enabled': true, 'type': 'keywords', 'config': <String, Object?>{}});
      expect(onChange.called, isTrue);
    });

    testWidgets('should invoke onSaveCallback from settings modal without onChange', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      await openSettings(t);
      modalCalls.single.onSaveCallback({'enabled': true, 'type': 'keywords', 'config': <String, Object?>{}});
      expect(t.takeException(), isNull);
    });

    testWidgets('should show code-based extension label for custom type', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'custom-ext',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      expect(find.text('-'), findsOneWidget);
    });

    testWidgets('should show code-based extension label when custom type is configured', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'custom-ext',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
            'outputs_config': {'enabled': false, 'preset_response': ''},
          },
        },
        extensions: [
          {
            'name': 'custom-ext',
            'label': {'en-US': 'Custom Moderation', 'zh-Hans': '自定义审核'},
          },
        ],
      );
      expect(find.text('Custom Moderation'), findsOneWidget);
    });

    testWidgets('should not show enable content text when both input and output moderation are disabled', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': false, 'preset_response': ''},
            'outputs_config': {'enabled': false, 'preset_response': ''},
          },
        },
      );
      expect(byText(r'feature\.moderation\.(allEnabled|inputEnabled|outputEnabled)'), findsNothing);
    });

    testWidgets('should not open setting modal when clicking settings button while disabled', (t) async {
      await renderModeration(
        t,
        disabled: true,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      await openSettings(t);
      expect(modalCalls, isEmpty);
    });

    testWidgets('should invoke onSaveCallback from enable modal and update features', (t) async {
      final onChange = OnChangeSpy();
      await renderModeration(t, onChange: onChange.call);
      await tap(t, switchAt());
      modalCalls.single.onSaveCallback({'enabled': true, 'type': 'keywords', 'config': <String, Object?>{}});
      expect(onChange.called, isTrue);
      expect(featureMap(featuresStore.features.value, 'moderation')['type'], 'keywords');
    });

    testWidgets('should invoke onSaveCallback from enable modal without onChange', (t) async {
      await renderModeration(t);
      await tap(t, switchAt());
      modalCalls.single.onSaveCallback({'enabled': true, 'type': 'keywords', 'config': <String, Object?>{}});
      expect(t.takeException(), isNull);
    });

    testWidgets('should invoke onCancelCallback from enable modal and set enabled false', (t) async {
      final onChange = OnChangeSpy();
      await renderModeration(t, onChange: onChange.call);
      await tap(t, switchAt());
      modalCalls.single.onCancelCallback();
      expect(onChange.called, isTrue);
      expect(featureMap(featuresStore.features.value, 'moderation'), {'enabled': false});
    });

    testWidgets('should invoke onCancelCallback from enable modal without onChange', (t) async {
      await renderModeration(t);
      await tap(t, switchAt());
      modalCalls.single.onCancelCallback();
      expect(t.takeException(), isNull);
    });

    testWidgets('should disable moderation when toggled off without onChange', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      await tap(t, switchAt());
      expect(t.takeException(), isNull);
    });

    testWidgets('should not show modal when enabling with existing type', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': false,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
      );
      await tap(t, switchAt());
      expect(modalCalls, isEmpty);
    });

    testWidgets('should hide info display when hovering over enabled feature', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
            'outputs_config': {'enabled': false, 'preset_response': ''},
          },
        },
      );
      expect(byText(r'feature\.moderation\.modal\.provider\.keywords'), findsOneWidget);
      await hover(t, card(title));
      expect(byText(r'operation\.settings'), findsOneWidget);
    });

    testWidgets('should show info display again when mouse leaves', (t) async {
      await renderModeration(
        t,
        moderation: {
          'enabled': true,
          'type': 'keywords',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
            'outputs_config': {'enabled': false, 'preset_response': ''},
          },
        },
      );
      await hover(t, card(title));
      await unhover(t);
      expect(byText(r'feature\.moderation\.modal\.provider\.keywords'), findsOneWidget);
    });
  });
}
