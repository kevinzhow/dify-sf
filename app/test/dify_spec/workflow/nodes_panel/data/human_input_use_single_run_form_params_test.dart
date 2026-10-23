// dify-spec: web/app/components/workflow/nodes/human-input/hooks/__tests__/use-single-run-form-params.spec.ts
//
// The hook's logic as plain functions and HumanInputSingleRun; Dify's `getInputVars` (the before-run form's) is the
// test's stand-in, as in the spec. The form's `values` / `onChange` belong to the host's single-run panel.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_model.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/single_run.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> createPayload([Map<String, Object?> overrides = const {}]) => {
  'title': 'Human Input',
  'type': 'human-input',
  'delivery_methods': <Object?>[],
  'form_content': 'Summary: {{#start.topic#}}',
  'inputs': [
    {
      'type': 'paragraph',
      'output_variable_name': 'summary',
      'default': {
        'type': 'variable',
        'selector': ['start', 'topic'],
        'value': '',
      },
    },
  ],
  'user_actions': <Object?>[],
  'timeout': 1,
  'timeout_unit': 'day',
  ...overrides,
};

RunInputVar createInputVar([Map<String, Object?> overrides = const {}]) => {
  'type': 'text-input',
  'label': 'Topic',
  'variable': '#start.topic#',
  'required': false,
  'value_selector': ['start', 'topic'],
  ...overrides,
};

void main() {
  group('human-input/hooks/use-single-run-form-params', () {
    test('should build a single before-run form, filter output vars, and expose dependent vars', () {
      final data = createPayload();
      expect(humanInputRunTexts(data), ['{{#start.topic#}}', 'Summary: {{#start.topic#}}']);

      final inputs = humanInputRunInputs([
        createInputVar(),
        createInputVar({
          'label': 'Output',
          'variable': '#\$output.answer#',
          'value_selector': [r'$output', 'answer'],
        }),
        {
          ...createInputVar({'label': 'Broken'}),
          'variable': null,
        },
      ]);
      expect([for (final i in inputs) i['label']], ['Topic', 'Broken']);
      expect(humanInputDependentVars(inputs), [
        ['start', 'topic'],
      ]);
    });

    test('should include variables referenced by dynamic select option sources', () {
      final data = createPayload({
        'inputs': [
          {
            'type': 'paragraph',
            'output_variable_name': 'summary',
            'default': {
              'type': 'variable',
              'selector': ['start', 'topic'],
              'value': '',
            },
          },
          {
            'type': 'select',
            'output_variable_name': 'choice',
            'option_source': {
              'type': 'variable',
              'selector': ['start', 'choices'],
              'value': <Object?>[],
            },
          },
        ],
      });
      expect(humanInputRunTexts(data), ['{{#start.topic#}}', '{{#start.choices#}}', 'Summary: {{#start.topic#}}']);
      final inputs = humanInputRunInputs([
        createInputVar(),
        createInputVar({
          'label': 'Choices',
          'variable': '#start.choices#',
          'value_selector': ['start', 'choices'],
        }),
      ]);
      expect([for (final i in inputs) i['variable']], ['#start.topic#', '#start.choices#']);
      expect(humanInputDependentVars(inputs), [
        ['start', 'topic'],
        ['start', 'choices'],
      ]);
    });

    test('should fetch and submit generated forms in workflow mode while keeping required inputs', () async {
      final fetched = <(String, Map<String, Object?>)>[], submitted = <(String, Map<String, Object?>)>[];
      final formData = <String, Object?>{
        'form_content': 'Rendered content',
        'inputs': [
          {
            'type': 'paragraph',
            'output_variable_name': 'answer',
            'default': {'type': 'constant', 'selector': <Object?>[], 'value': ''},
          },
          {'type': 'file', 'output_variable_name': 'attachment'},
          {'type': 'file-list', 'output_variable_name': 'references', 'number_limits': 3},
        ],
        'actions': <Object?>[],
      };
      final run = HumanInputSingleRun(
        nodeId: 'node-1',
        data: createPayload(),
        appId: 'app-1',
        fetch: (url, inputs) async {
          fetched.add((url, inputs));
          return formData;
        },
        submit: (url, body) async => submitted.add((url, body)),
      );

      await run.showForm({'topic': 'AI', 'ignored': null});
      expect(run.showGeneratedForm, isTrue);
      expect(fetched.single.$1, '/apps/app-1/workflows/draft/human-input/nodes/node-1/form');
      expect(fetched.single.$2, {'topic': 'AI'});
      expect(run.formData, formData);

      const uploaded = HumanInputFile(transferMethod: 'local_file', uploadedId: 'upload-file-1');
      const remote = HumanInputFile(transferMethod: 'remote_url', url: 'https://example.com/reference.pdf');
      await run.submitForm(
        inputs: {
          'answer': 'approved',
          'attachment': uploaded,
          'references': [uploaded, remote],
        },
        action: 'approve',
      );
      expect(submitted.single.$1, '/apps/app-1/workflows/draft/human-input/nodes/node-1/form');
      expect(submitted.single.$2, {
        'inputs': {'topic': 'AI'},
        'form_inputs': {
          'answer': 'approved',
          'attachment': {
            'type': 'document',
            'transfer_method': 'local_file',
            'url': '',
            'upload_file_id': 'upload-file-1',
          },
          'references': [
            {'type': 'document', 'transfer_method': 'local_file', 'url': '', 'upload_file_id': 'upload-file-1'},
            {
              'type': 'document',
              'transfer_method': 'remote_url',
              'url': 'https://example.com/reference.pdf',
              'upload_file_id': '',
            },
          ],
        },
        'action': 'approve',
      });

      run.hideForm();
      expect(run.showGeneratedForm, isFalse);
    });

    test('should use the advanced-chat endpoint and skip remote fetches when app detail is missing', () async {
      final fetched = <String>[];
      final run = HumanInputSingleRun(
        nodeId: 'node-9',
        data: createPayload(),
        appId: 'app-2',
        isWorkflowMode: false,
        fetch: (url, _) async {
          fetched.add(url);
          return const {};
        },
        submit: (_, _) async {},
      );
      await run.fetchFormContent({'topic': 'hello'});
      expect(fetched, ['/apps/app-2/advanced-chat/workflows/draft/human-input/nodes/node-9/form']);

      run.appId = null;
      expect(await run.fetchFormContent({'topic': 'skip'}), isNull);
      expect(fetched, hasLength(1));
      // The selectors of the form inputs are what getInputVars sees first.
      expect(humanInputFormDependencySelectors(jsonInputs), [
        ['start', 'topic'],
      ]);
    });
  });
}

const jsonInputs = [
  {
    'type': 'paragraph',
    'output_variable_name': 'summary',
    'default': {
      'type': 'variable',
      'selector': ['start', 'topic'],
      'value': '',
    },
  },
];
