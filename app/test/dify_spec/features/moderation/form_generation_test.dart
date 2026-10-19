// dify-spec: web/app/components/base/features/new-feature-panel/moderation/__tests__/form-generation.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

Json i18n(String en, [String? zh]) => {'en-US': en, 'zh-Hans': zh ?? en};

Json createForm([Json overrides = const {}]) => {
  'type': 'text-input',
  'variable': 'api_key',
  'label': i18n('API Key', 'API 密钥'),
  'placeholder': 'Enter API key',
  'required': true,
  'options': const <Object?>[],
  'default': '',
  'max_length': 100,
  ...overrides,
};

final changes = <Map<String, Object?>>[];

Future<void> renderForms(WidgetTester t, List<Json> forms, {Json value = const {}, String locale = 'en-US'}) async {
  changes.clear();
  await render(t, FormGeneration(forms: forms, value: value, locale: locale, onChange: changes.add));
}

final selectForm = createForm({
  'type': 'select',
  'variable': 'model',
  'label': i18n('Model', '模型'),
  'options': [
    {'label': i18n('GPT-4'), 'value': 'gpt-4'},
    {'label': i18n('GPT-3.5'), 'value': 'gpt-3.5'},
  ],
});

Finder option(String name) =>
    find.descendant(of: find.byWidgetPredicate((w) => w is DifyMenuRadioItem<String>), matching: find.text(name));

void main() {
  setUp(useDifyTestTranslator);

  group('FormGeneration', () {
    testWidgets('should render text-input form fields', (t) async {
      await renderForms(t, [createForm()]);
      expect(find.text('API Key'), findsOneWidget);
      expect(byPlaceholder('Enter API key'), findsOneWidget);
    });

    testWidgets('should call onChange when text input value changes', (t) async {
      await renderForms(t, [createForm()]);
      await t.enterText(byPlaceholder('Enter API key'), 'my-key');
      expect(changes.last, {'api_key': 'my-key'});
    });

    testWidgets('should render paragraph form fields', (t) async {
      await renderForms(t, [
        createForm({
          'type': 'paragraph',
          'variable': 'description',
          'label': i18n('Description', '描述'),
          'placeholder': 'Enter description',
        }),
      ]);
      expect(find.text('Description'), findsOneWidget);
      expect(byPlaceholder('Enter description'), findsOneWidget);
    });

    testWidgets('should render select form fields', (t) async {
      await renderForms(t, [selectForm]);
      expect(find.text('Model'), findsOneWidget);
    });

    testWidgets('should render multiple forms', (t) async {
      await renderForms(t, [
        createForm({'variable': 'key1', 'label': i18n('Field 1', '字段1')}),
        createForm({'variable': 'key2', 'label': i18n('Field 2', '字段2'), 'type': 'paragraph'}),
      ]);
      expect(find.text('Field 1'), findsOneWidget);
      expect(find.text('Field 2'), findsOneWidget);
    });

    testWidgets('should display existing values', (t) async {
      await renderForms(t, [createForm()], value: {'api_key': 'existing-key'});
      expect(byDisplayValue('existing-key'), findsOneWidget);
    });

    testWidgets('should call onChange when paragraph textarea value changes', (t) async {
      await renderForms(t, [
        createForm({
          'type': 'paragraph',
          'variable': 'description',
          'label': i18n('Description', '描述'),
          'placeholder': 'Enter description',
        }),
      ]);
      await t.enterText(byPlaceholder('Enter description'), 'my description');
      expect(changes.last, {'description': 'my description'});
    });

    testWidgets('should call onChange when select option is chosen', (t) async {
      await renderForms(t, [selectForm]);
      await tap(t, find.byType(DifySelect<String>));
      await tap(t, option('GPT-4'));
      expect(changes.last, {'model': 'gpt-4'});
    });

    testWidgets('should render zh-Hans labels for select field and options', (t) async {
      await renderForms(t, [
        createForm({
          'type': 'select',
          'variable': 'model',
          'label': i18n('Model', '模型'),
          'options': [
            {'label': i18n('GPT-4', '智谱-4'), 'value': 'gpt-4'},
            {'label': i18n('GPT-3.5', '智谱-3.5'), 'value': 'gpt-3.5'},
          ],
        }),
      ], locale: 'zh-Hans');
      expect(find.text('模型'), findsOneWidget);
      await tap(t, find.byType(DifySelect<String>));
      expect(option('智谱-4'), findsOneWidget);
    });
  });
}
