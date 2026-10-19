// dify-spec: web/app/components/base/features/new-feature-panel/moderation/__tests__/moderation-setting-modal.spec.tsx
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

const configuredOpenai = [
  {
    'provider': 'langgenius/openai/openai',
    'system_configuration': {
      'enabled': true,
      'current_quota_type': 'paid',
      'quota_configurations': [
        {'quota_type': 'paid', 'is_valid': true},
      ],
    },
    'custom_configuration': {'status': 'active'},
  },
];

const unconfiguredOpenai = [
  {
    'provider': 'langgenius/openai/openai',
    'system_configuration': {'enabled': false, 'current_quota_type': 'free', 'quota_configurations': <Object?>[]},
    'custom_configuration': {'status': 'no-configure'},
  },
];

const defaultData = {
  'enabled': true,
  'type': 'keywords',
  'config': {
    'keywords': 'bad\nword',
    'inputs_config': {'enabled': true, 'preset_response': 'Input blocked'},
    'outputs_config': {'enabled': false, 'preset_response': ''},
  },
};

Json customExt({String placeholder = '', String defaultValue = ''}) => {
  'name': 'custom-ext',
  'label': {'en-US': 'Custom Extension', 'zh-Hans': '自定义扩展'},
  'form_schema': [
    {
      'variable': 'api_url',
      'label': {'en-US': 'API URL', 'zh-Hans': 'API 地址'},
      'type': 'text-input',
      'required': true,
      'default': defaultValue,
      'placeholder': placeholder,
      'options': <Object?>[],
      'max_length': 200,
    },
  ],
};

final saved = <Json>[];
var cancelled = 0;
final destinations = <String>[];

Future<void> renderModal(
  WidgetTester t,
  Json data, {
  List<Json> providers = configuredOpenai,
  List<Json> extensions = const [],
}) async {
  saved.clear();
  cancelled = 0;
  destinations.clear();
  await render(
    t,
    ModerationSettingModal(data: data, onCancel: () => cancelled++, onSave: saved.add),
    services: FeaturesServices(
      modelProviders: providers,
      codeBasedExtensions: extensions,
      apiBasedExtensions: const [
        {'id': 'api-ext-1', 'name': 'Ext 1', 'api_endpoint': 'https://ext.example.com'},
      ],
      openAccountSettings: destinations.add,
    ),
    fill: true,
  );
  await settle(t);
}

Json config(Json saved) => featureMap(saved, 'config');
bool get errorToast => toasts.any((x) => x.type.name == 'error');
Finder get keywordsTextarea => byPlaceholder(r'feature\.moderation\.modal\.keywords\.placeholder');
Finder get presetTextareas => byPlaceholder(r'feature\.moderation\.modal\.content\.placeholder');
Finder get save => byText(r'operation\.save');
Finder get apiSelector => find.byType(ApiBasedExtensionSelector);
String textOf(WidgetTester t, Finder f) => t.widget<TextField>(f).controller!.text;

Json kwData(Json cfg) => {...defaultData, 'config': cfg};

class _EmptyFor extends DifyTestTranslator {
  _EmptyFor(this.empty);
  final Set<String> empty;
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      empty.contains(key) ? '' : super.t(ns, key, params);
}

void main() {
  setUp(useDifyTestTranslator);

  group('ModerationSettingModal', () {
    testWidgets('should render the modal title', (t) async {
      await renderModal(t, defaultData);
      expect(byText(r'feature\.moderation\.modal\.title'), findsOneWidget);
    });

    testWidgets('should render provider options', (t) async {
      await renderModal(t, defaultData);
      expect(byText(r'feature\.moderation\.modal\.provider\.openai'), findsOneWidget);
      expect(byText(r'feature\.moderation\.modal\.provider\.keywords').evaluate().length, greaterThanOrEqualTo(1));
      expect(byText(r'apiBasedExtension\.selector\.title'), findsOneWidget);
    });

    testWidgets('should show keywords textarea when keywords type is selected', (t) async {
      await renderModal(t, defaultData);
      expect(keywordsTextarea, findsOneWidget);
      expect(textOf(t, keywordsTextarea), 'bad\nword');
    });

    testWidgets('should render cancel and save buttons', (t) async {
      await renderModal(t, defaultData);
      expect(byText(r'operation\.cancel'), findsOneWidget);
      expect(save, findsOneWidget);
    });

    testWidgets('should call onCancel when cancel is clicked', (t) async {
      await renderModal(t, defaultData);
      await tap(t, byText(r'operation\.cancel'));
      expect(cancelled, 1);
    });

    testWidgets('should call onCancel when close icon receives Enter key', (t) async {
      await renderModal(t, defaultData);
      await focusOn(t, button('common.operation.close'));
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(cancelled, 1);
    });

    testWidgets('should call onCancel when close icon receives Space key', (t) async {
      await renderModal(t, defaultData);
      await focusOn(t, button('common.operation.close'));
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      expect(cancelled, 1);
    });

    testWidgets('should not call onCancel when close icon receives non-action key', (t) async {
      await renderModal(t, defaultData);
      await focusOn(t, button('common.operation.close'));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(cancelled, 0);
    });

    testWidgets('should show error when saving without inputs or outputs enabled', (t) async {
      await renderModal(
        t,
        kwData({
          'keywords': 'test',
          'inputs_config': {'enabled': false, 'preset_response': ''},
          'outputs_config': {'enabled': false, 'preset_response': ''},
        }),
      );
      await tap(t, save);
      expect(errorToast, isTrue);
    });

    testWidgets('should show error when keywords type has no keywords', (t) async {
      await renderModal(
        t,
        kwData({
          'keywords': '',
          'inputs_config': {'enabled': true, 'preset_response': 'blocked'},
          'outputs_config': {'enabled': false, 'preset_response': ''},
        }),
      );
      await tap(t, save);
      expect(errorToast, isTrue);
    });

    testWidgets('should call onSave with formatted data when valid', (t) async {
      await renderModal(
        t,
        kwData({
          'keywords': 'bad\nword',
          'inputs_config': {'enabled': true, 'preset_response': 'blocked'},
          'outputs_config': {'enabled': false, 'preset_response': ''},
        }),
      );
      await tap(t, save);
      expect(saved.single['type'], 'keywords');
      expect(saved.single['enabled'], true);
      expect(config(saved.single)['keywords'], 'bad\nword');
      expect(featureMap(config(saved.single), 'inputs_config')['enabled'], true);
    });

    testWidgets('should save the latest preset response when content textarea changes', (t) async {
      await renderModal(
        t,
        kwData({
          'keywords': 'bad',
          'inputs_config': {'enabled': true, 'preset_response': 'blocked'},
          'outputs_config': {'enabled': false, 'preset_response': ''},
        }),
      );
      await t.enterText(presetTextareas, 'updated blocked response');
      await tap(t, save);
      expect(featureMap(config(saved.single), 'inputs_config')['preset_response'], 'updated blocked response');
    });

    testWidgets('should show api selector when api type is selected', (t) async {
      await renderModal(t, {
        ...defaultData,
        'type': 'api',
        'config': {
          'inputs_config': {'enabled': true, 'preset_response': ''},
        },
      });
      expect(apiSelector, findsOneWidget);
    });

    testWidgets('should switch provider type when clicked', (t) async {
      await renderModal(t, defaultData);
      await tap(t, byText(r'feature\.moderation\.modal\.provider\.openai'));
      expect(keywordsTextarea, findsNothing);
    });

    testWidgets('should update keywords on textarea change', (t) async {
      await renderModal(t, defaultData);
      await t.enterText(keywordsTextarea, 'new\nkeywords');
      await t.pump();
      expect(textOf(t, keywordsTextarea), 'new\nkeywords');
    });

    testWidgets('should render moderation content sections', (t) async {
      await renderModal(t, defaultData);
      expect(byText(r'feature\.moderation\.modal\.content\.input'), findsOneWidget);
      expect(byText(r'feature\.moderation\.modal\.content\.output'), findsOneWidget);
    });

    testWidgets('should show error when inputs enabled but no preset_response for keywords type', (t) async {
      await renderModal(
        t,
        kwData({
          'keywords': 'test',
          'inputs_config': {'enabled': true, 'preset_response': ''},
          'outputs_config': {'enabled': false, 'preset_response': ''},
        }),
      );
      await tap(t, save);
      expect(errorToast, isTrue);
    });

    testWidgets('should show error when api type has no api_based_extension_id', (t) async {
      await renderModal(t, {
        'enabled': true,
        'type': 'api',
        'config': {
          'inputs_config': {'enabled': true, 'preset_response': ''},
          'outputs_config': {'enabled': false, 'preset_response': ''},
        },
      });
      await tap(t, save);
      expect(errorToast, isTrue);
    });

    testWidgets('should save with api_based_extension_id in formatted data for api type', (t) async {
      await renderModal(t, {
        'enabled': true,
        'type': 'api',
        'config': {
          'api_based_extension_id': 'ext-1',
          'inputs_config': {'enabled': true, 'preset_response': ''},
          'outputs_config': {'enabled': false, 'preset_response': ''},
        },
      });
      await tap(t, save);
      expect(saved.single['type'], 'api');
      expect(config(saved.single)['api_based_extension_id'], 'ext-1');
    });

    testWidgets('should show error when outputs enabled but no preset_response for keywords type', (t) async {
      await renderModal(
        t,
        kwData({
          'keywords': 'test',
          'inputs_config': {'enabled': false, 'preset_response': ''},
          'outputs_config': {'enabled': true, 'preset_response': ''},
        }),
      );
      await tap(t, save);
      expect(errorToast, isTrue);
    });

    testWidgets('should toggle input moderation content', (t) async {
      await renderModal(t, defaultData);
      expect(presetTextareas, findsOneWidget);
      await tap(t, find.byType(DifySwitch).at(0));
      expect(presetTextareas, findsNothing);
    });

    testWidgets('should toggle output moderation content', (t) async {
      await renderModal(t, defaultData);
      expect(presetTextareas, findsOneWidget);
      await tap(t, find.byType(DifySwitch).at(1));
      expect(presetTextareas, findsNWidgets(2));
    });

    testWidgets('should select api extension via api selector', (t) async {
      await renderModal(t, {
        ...defaultData,
        'type': 'api',
        'config': {
          'inputs_config': {'enabled': true, 'preset_response': ''},
        },
      });
      await tap(t, apiSelector);
      await tap(t, find.text('Ext 1'));
      await tap(t, save);
      expect(config(saved.single)['api_based_extension_id'], 'api-ext-1');
    });

    testWidgets('should save with openai_moderation type when configured', (t) async {
      await renderModal(t, {
        'enabled': true,
        'type': 'openai_moderation',
        'config': {
          'inputs_config': {'enabled': true, 'preset_response': 'blocked'},
          'outputs_config': {'enabled': false, 'preset_response': ''},
        },
      });
      await tap(t, save);
      expect(saved.single['type'], 'openai_moderation');
    });

    testWidgets('should handle keyword truncation to 100 chars per line and 100 lines', (t) async {
      await renderModal(t, defaultData);
      await t.enterText(keywordsTextarea, 'a' * 150);
      await t.pump();
      expect(textOf(t, keywordsTextarea).length, lessThanOrEqualTo(100));
    });

    testWidgets('should save with formatted outputs_config when both enabled', (t) async {
      await renderModal(
        t,
        kwData({
          'keywords': 'test',
          'inputs_config': {'enabled': true, 'preset_response': 'input blocked'},
          'outputs_config': {'enabled': true, 'preset_response': 'output blocked'},
        }),
      );
      await tap(t, save);
      expect(featureMap(config(saved.single), 'inputs_config')['enabled'], true);
      expect(featureMap(config(saved.single), 'outputs_config')['enabled'], true);
    });

    testWidgets('should switch from keywords to api type', (t) async {
      await renderModal(t, defaultData);
      await tap(t, byText(r'apiBasedExtension\.selector\.title'));
      expect(apiSelector, findsOneWidget);
      expect(keywordsTextarea, findsNothing);
    });

    testWidgets('should handle empty lines in keywords', (t) async {
      await renderModal(t, defaultData);
      await t.enterText(keywordsTextarea, 'word1\n\nword2\n\n');
      await t.pump();
      expect(textOf(t, keywordsTextarea), 'word1\n\nword2\n');
    });

    testWidgets('should show OpenAI not configured warning when OpenAI provider is not set up', (t) async {
      await renderModal(t, {
        ...defaultData,
        'type': 'openai_moderation',
        'config': {
          'inputs_config': {'enabled': true, 'preset_response': ''},
        },
      }, providers: unconfiguredOpenai);
      expect(byText(r'feature\.moderation\.modal\.openaiNotConfig\.before'), findsOneWidget);
    });

    testWidgets('should open settings modal when provider link is clicked in OpenAI warning', (t) async {
      await renderModal(t, {
        ...defaultData,
        'type': 'openai_moderation',
        'config': {
          'inputs_config': {'enabled': true, 'preset_response': ''},
        },
      }, providers: unconfiguredOpenai);
      await tap(t, byText(r'settings\.provider'));
      expect(destinations, ['provider']);
    });

    testWidgets('should not save when OpenAI type is selected but not configured', (t) async {
      await renderModal(t, {
        ...defaultData,
        'type': 'openai_moderation',
        'config': {
          'inputs_config': {'enabled': true, 'preset_response': 'blocked'},
          'outputs_config': {'enabled': false, 'preset_response': ''},
        },
      }, providers: unconfiguredOpenai);
      await tap(t, save);
      expect(saved, isEmpty);
    });

    testWidgets('should render code-based extension providers', (t) async {
      await renderModal(t, defaultData, extensions: [customExt(placeholder: 'Enter URL')]);
      expect(find.text('Custom Extension'), findsOneWidget);
    });

    testWidgets('should show form generation when code-based extension is selected', (t) async {
      await renderModal(
        t,
        {
          ...defaultData,
          'type': 'custom-ext',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': ''},
          },
        },
        extensions: [customExt(placeholder: 'Enter URL')],
      );
      expect(find.text('API URL'), findsOneWidget);
      expect(byPlaceholder('Enter URL'), findsOneWidget);
    });

    testWidgets('should initialize config from form schema when switching to code-based extension', (t) async {
      await renderModal(t, defaultData, extensions: [customExt(defaultValue: 'https://default.com')]);
      await tap(t, find.text('Custom Extension'));
      expect(byDisplayValue('https://default.com'), findsOneWidget);
    });

    testWidgets('should show error when required form schema field is empty on save', (t) async {
      await renderModal(
        t,
        {
          ...defaultData,
          'type': 'custom-ext',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': 'blocked'},
          },
        },
        extensions: [customExt()],
      );
      await tap(t, save);
      expect(errorToast, isTrue);
    });

    testWidgets('should save with code-based extension config when valid', (t) async {
      await renderModal(
        t,
        {
          ...defaultData,
          'type': 'custom-ext',
          'config': {
            'api_url': 'https://example.com',
            'inputs_config': {'enabled': true, 'preset_response': 'blocked'},
            'outputs_config': {'enabled': false, 'preset_response': ''},
          },
        },
        extensions: [customExt()],
      );
      await tap(t, save);
      expect(saved.single['type'], 'custom-ext');
      expect(config(saved.single)['api_url'], 'https://example.com');
    });

    testWidgets('should update code-based extension form value and save updated config', (t) async {
      await renderModal(
        t,
        {
          ...defaultData,
          'type': 'custom-ext',
          'config': {
            'inputs_config': {'enabled': true, 'preset_response': 'blocked'},
            'outputs_config': {'enabled': false, 'preset_response': ''},
          },
        },
        extensions: [customExt(placeholder: 'Enter URL')],
      );
      await t.enterText(byPlaceholder('Enter URL'), 'https://changed.com');
      await tap(t, save);
      expect(saved.single['type'], 'custom-ext');
      expect(config(saved.single)['api_url'], 'https://changed.com');
    });

    testWidgets('should show doc link for api type', (t) async {
      await renderModal(t, {
        ...defaultData,
        'type': 'api',
        'config': {
          'inputs_config': {'enabled': true, 'preset_response': ''},
        },
      });
      expect(byText(r'apiBasedExtension\.link'), findsOneWidget);
    });

    testWidgets('should fallback missing inputs_config to disabled in formatted save data', (t) async {
      await renderModal(t, {
        'enabled': true,
        'type': 'api',
        'config': {
          'api_based_extension_id': 'ext-fallback',
          'outputs_config': {'enabled': true, 'preset_response': ''},
        },
      });
      await tap(t, save);
      expect(saved.single['type'], 'api');
      expect(featureMap(config(saved.single), 'inputs_config')['enabled'], false);
      expect(featureMap(config(saved.single), 'outputs_config')['enabled'], true);
    });

    testWidgets('should fallback to empty translated strings for optional placeholders and titles', (t) async {
      DifyI18n.current = _EmptyFor({
        'feature.moderation.modal.keywords.placeholder',
        'feature.moderation.modal.content.input',
        'feature.moderation.modal.content.output',
      });
      await renderModal(t, defaultData);
      expect(t.widgetList<TextField>(find.byType(TextField)).first.decoration!.hintText, '');
    });
  });
}
