// dify-spec: web/app/components/workflow/nodes/_base/components/before-run-form/__tests__/helpers.spec.ts
// dify-spec: web/app/components/workflow/nodes/_base/components/before-run-form/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart' show DifyJson;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../run/run_harness.dart';

RunFormProps form({List<DifyJson> inputs = const [], Map<String, Object?> values = const {}}) =>
    RunFormProps(inputs: inputs, values: values, onChange: (_) {});

DifyJson input([DifyJson o = const {}]) => {
  'variable': 'field',
  'label': 'Field',
  'type': InputVarType.textInput,
  'required': false,
  ...o,
};

String t(String ns, String key, Map<String, Object?> params) => '$key:${params['field'] ?? ''}';

void main() {
  group('before-run-form helpers', () {
    test('should format values by input type', () {
      expect(formatValue('12.5', InputVarType.number), 12.5);
      expect(formatValue('{"foo":1}', InputVarType.json), {'foo': 1});
      expect(formatValue('', InputVarType.checkbox), false);
      expect(formatValue(['{"foo":1}'], InputVarType.contexts), [
        {'foo': 1},
      ]);
      expect(formatValue(null, InputVarType.singleFile), isNull);
      expect(
        formatValue([
          {'transfer_method': TransferMethod.remoteUrl, 'related_id': '3'},
        ], InputVarType.singleFile),
        isA<List<Object?>>(),
      );
      expect(formatValue('', InputVarType.singleFile), isNull);
    });

    test('should detect when file uploads are still in progress', () {
      expect(isFilesLoaded([]), isTrue);
      expect(isFilesLoaded([form()]), isTrue);
      expect(
        isFilesLoaded([
          form(
            values: {
              '#files#': [
                {'transfer_method': TransferMethod.localFile},
              ],
            },
          ),
        ]),
        isFalse,
      );
    });

    test('should report required and uploading file errors', () {
      expect(
        getFormErrorMessage(
          [
            form(
              inputs: [
                input({'variable': 'query', 'label': 'Query', 'required': true}),
              ],
              values: {'query': ''},
            ),
          ],
          [{}],
          t,
        ),
        contains('errorMsg.fieldRequired'),
      );
      expect(
        getFormErrorMessage(
          [
            form(
              inputs: [
                input({'variable': 'file', 'label': 'File', 'type': InputVarType.singleFile, 'required': true}),
              ],
              values: {'file': <Object?>[]},
            ),
          ],
          [{}],
          t,
        ),
        contains('errorMsg.fieldRequired'),
      );
      expect(
        getFormErrorMessage(
          [
            form(
              inputs: [
                input({'variable': 'files', 'label': 'Files', 'type': InputVarType.multiFiles, 'required': true}),
              ],
              values: {'files': <Object?>[]},
            ),
          ],
          [{}],
          t,
        ),
        contains('errorMsg.fieldRequired'),
      );
      expect(
        getFormErrorMessage(
          [
            form(
              inputs: [
                input({'variable': 'file', 'label': 'File', 'type': InputVarType.singleFile}),
              ],
              values: {
                'file': {'transferMethod': TransferMethod.localFile},
              },
            ),
          ],
          [{}],
          t,
        ),
        contains('errorMessage.waitForFileUpload'),
      );
      expect(
        getFormErrorMessage(
          [
            form(
              inputs: [
                input({'variable': 'files', 'label': 'Files', 'type': InputVarType.multiFiles}),
              ],
              values: {
                'files': [
                  {'transferMethod': TransferMethod.localFile},
                ],
              },
            ),
          ],
          [{}],
          t,
        ),
        contains('errorMessage.waitForFileUpload'),
      );
      expect(
        getFormErrorMessage(
          [
            form(
              inputs: [
                input({
                  'variable': 'config',
                  'label': {'nodeType': 'tool', 'nodeName': 'Tool', 'variable': 'Config'},
                  'required': true,
                }),
              ],
              values: {'config': ''},
            ),
          ],
          [{}],
          t,
        ),
        contains('Config'),
      );
    });

    test('should build submit data and keep parse errors', () {
      final r = buildSubmitData([
        form(
          inputs: [
            input({'variable': 'query'}),
          ],
          values: {'query': 'hello'},
        ),
      ]);
      expect(r.submitData, {'query': 'hello'});
      expect(r.parseErrorJsonField, '');
      expect(
        buildSubmitData([
          form(
            inputs: [
              input({'variable': 'payload', 'type': InputVarType.json}),
            ],
            values: {'payload': '{'},
          ),
        ]).parseErrorJsonField,
        'payload',
      );
      final files = buildSubmitData([
        form(
          inputs: [
            input({'variable': 'files', 'type': InputVarType.multiFiles}),
            input({'variable': 'file', 'type': InputVarType.singleFile}),
          ],
          values: {
            'files': [
              {'transfer_method': TransferMethod.remoteUrl, 'related_id': '1'},
            ],
            'file': {'transfer_method': TransferMethod.remoteUrl, 'related_id': '2'},
          },
        ),
      ]).submitData;
      expect(files['files'], isA<List<Object?>>());
      expect(files['file'], isA<Map<Object?, Object?>>());
    });

    test('should derive the zero-form auto behaviors', () {
      expect(shouldAutoRunBeforeRunForm([], false), isTrue);
      expect(shouldAutoRunBeforeRunForm([], true), isFalse);
      expect(shouldAutoShowGeneratedForm([], true), isTrue);
      expect(shouldAutoShowGeneratedForm([form()], true), isFalse);
    });
  });

  group('BeforeRunForm', () {
    final query = input({'variable': 'query', 'label': 'Query', 'required': true});

    Future<List<String>> pump(WidgetTester t, BeforeRunForm w) async {
      final errors = <String>[];
      await renderRun(
        t,
        BeforeRunForm(
          nodeName: w.nodeName,
          nodeType: w.nodeType,
          onHide: w.onHide,
          onRun: w.onRun,
          forms: w.forms,
          existVarValuesInForms: w.existVarValuesInForms,
          filteredExistVarForms: w.filteredExistVarForms,
          handleShowGeneratedForm: w.handleShowGeneratedForm,
          toast: (type, m) {
            if (type == DifyToastType.error) errors.add(m);
          },
        ),
        size: const Size(800, 900),
      );
      await t.pump();
      return errors;
    }

    testWidgets('should auto run and render nothing when there are no filtered forms', (t) async {
      final runs = <Map<String, Object?>>[];
      await pump(
        t,
        BeforeRunForm(
          nodeName: 'Tool',
          onHide: () {},
          onRun: runs.add,
          forms: const [],
          existVarValuesInForms: const [],
          filteredExistVarForms: const [],
        ),
      );
      expect(runs, [<String, Object?>{}]);
      expect(find.byType(RunPanelWrap), findsNothing);
    });

    testWidgets('should show an error toast when required fields are missing', (t) async {
      final errors = await pump(
        t,
        BeforeRunForm(
          nodeName: 'Tool',
          onHide: () {},
          onRun: (_) {},
          forms: [
            form(inputs: [query], values: {'query': ''}),
          ],
          filteredExistVarForms: [
            form(inputs: [query], values: {'query': ''}),
          ],
          existVarValuesInForms: const [{}],
        ),
      );
      await t.tap(find.text('workflow.singleRun.startRun'));
      expect(errors, isNotEmpty);
    });

    testWidgets('should generate the human input form instead of running immediately', (t) async {
      final generated = <Map<String, Object?>>[];
      final runs = <Map<String, Object?>>[];
      await pump(
        t,
        BeforeRunForm(
          nodeName: 'Human input',
          nodeType: 'human-input',
          onHide: () {},
          onRun: runs.add,
          forms: [
            form(inputs: [query], values: {'query': 'hello'}),
          ],
          filteredExistVarForms: [
            form(inputs: [query], values: {'query': 'hello'}),
          ],
          existVarValuesInForms: const [{}],
          handleShowGeneratedForm: generated.add,
        ),
      );
      await t.tap(find.text('workflow.nodes.humanInput.singleRun.button'));
      expect(generated, [
        {'query': 'hello'},
      ]);
      expect(runs, isEmpty);
    });

    testWidgets('should run immediately when the form is valid', (t) async {
      final runs = <Map<String, Object?>>[];
      await pump(
        t,
        BeforeRunForm(
          nodeName: 'Tool',
          onHide: () {},
          onRun: runs.add,
          forms: [
            form(inputs: [query], values: {'query': 'hello'}),
          ],
          filteredExistVarForms: [
            form(inputs: [query], values: {'query': 'hello'}),
          ],
          existVarValuesInForms: const [{}],
        ),
      );
      await t.tap(find.text('workflow.singleRun.startRun'));
      expect(runs, [
        {'query': 'hello'},
      ]);
    });

    testWidgets('should auto show the generated form when human input has no filtered vars', (t) async {
      final generated = <Map<String, Object?>>[];
      await pump(
        t,
        BeforeRunForm(
          nodeName: 'Human input',
          nodeType: 'human-input',
          onHide: () {},
          onRun: (_) {},
          forms: const [],
          existVarValuesInForms: const [],
          filteredExistVarForms: const [],
          handleShowGeneratedForm: generated.add,
        ),
      );
      expect(generated, [<String, Object?>{}]);
      expect(find.text('workflow.nodes.humanInput.singleRun.button'), findsOneWidget);
    });

    testWidgets('should show an error toast when json input is invalid', (t) async {
      final payload = input({'variable': 'payload', 'label': 'Payload', 'type': InputVarType.json, 'required': true});
      final errors = await pump(
        t,
        BeforeRunForm(
          nodeName: 'Tool',
          onHide: () {},
          onRun: (_) {},
          forms: [
            form(inputs: [payload], values: {'payload': '{'}),
          ],
          filteredExistVarForms: [
            form(inputs: [payload], values: {'payload': '{'}),
          ],
          existVarValuesInForms: const [{}],
        ),
      );
      await t.tap(find.text('workflow.singleRun.startRun'));
      expect(errors, isNotEmpty);
    });
  });
}
