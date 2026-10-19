// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/file-support.spec.tsx
//
// FileTypeItem and FileUploadSetting (panel_fields/file_upload_setting.dart). Dify's `aria-invalid` /
// `aria-describedby` are the semantics' validation result and hint.
import 'dart:ui' show CheckedState, SemanticsRole, SemanticsValidationResult, Tristate;

import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsData;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

Map<String, Object?> _payload([Map<String, Object?> overrides = const {}]) => {
  'allowed_file_upload_methods': ['local_file'],
  'max_length': 2,
  'allowed_file_types': ['document'],
  'allowed_file_extensions': ['pdf'],
  ...overrides,
};

String _ad(String key) => 'app-debug.variableConfig.$key';

/// The semantics of each file type checkbox.
List<SemanticsData> _checkboxes(WidgetTester t) => [
  for (final e in find.byType(DifyCheckbox).evaluate()) t.getSemantics(find.byWidget(e.widget)).getSemanticsData(),
];

SemanticsData _tagInput(WidgetTester t) =>
    t.getSemantics(find.descendant(of: find.byType(TagInput), matching: find.byType(TextField))).getSemanticsData();

/// The upload method radio named [label] is checked.
bool _checked(WidgetTester t, String label) =>
    t.getSemantics(find.bySemanticsLabel(label).first).getSemanticsData().flagsCollection.isChecked ==
    CheckedState.isTrue;

bool _anyChecked(WidgetTester t) => [
  _ad('localUpload'),
  'URL',
  _ad('both'),
].any((l) => _checked(t, l));

Widget _setting(
  Map<String, Object?> payload,
  ValueChanged<Map<String, Object?>> onChange, {
  bool isMultiple = false,
  bool inFeaturePanel = false,
  bool hideSupportFileType = false,
  ({String field, String message})? validationError,
}) => FileUploadSetting(
  payload: payload,
  isMultiple: isMultiple,
  inFeaturePanel: inFeaturePanel,
  hideSupportFileType: hideSupportFileType,
  validationError: validationError,
  onChange: onChange,
);

/// FileUploadSetting keeping the payload it reports (`useState`).
class _Stateful extends StatefulWidget {
  const _Stateful({required this.initial, required this.builder});
  final Map<String, Object?> initial;
  final Widget Function(Map<String, Object?> payload, ValueChanged<Map<String, Object?>> set) builder;

  @override
  State<_Stateful> createState() => _StatefulState();
}

class _StatefulState extends State<_Stateful> {
  late Map<String, Object?> _p = widget.initial;

  @override
  Widget build(BuildContext context) => widget.builder(_p, (v) => setState(() => _p = v));
}

Finder _numberInput() => find.descendant(of: find.byType(InputNumberWithSlider), matching: find.byType(EditableText));

void main() {
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(1200, 2000);
    binding.platformDispatcher.views.first.devicePixelRatio = 1;
  });
  tearDown(() => TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first.resetPhysicalSize());

  group('File upload support components', () {
    group('FileTypeItem', () {
      testWidgets('should render built-in file types and toggle the selected type on click', (t) async {
        final toggles = <String>[];
        await render(t, FileTypeItem(type: 'image', selected: false, onToggle: toggles.add));
        expect(find.text(_ad('file.image.name')), findsOneWidget);
        expect(find.text('JPG, JPEG, PNG, GIF, WEBP, SVG'), findsOneWidget);
        await t.tap(find.text(_ad('file.image.name')));
        expect(toggles, ['image']);
      });

      testWidgets('should render the custom tag editor and emit custom extensions', (t) async {
        final changes = <List<String>>[];
        await render(
          t,
          FileTypeItem(
            type: 'custom',
            selected: true,
            onToggle: (_) {},
            customFileTypes: const ['json'],
            onCustomFileTypesChange: changes.add,
          ),
        );
        final input = find.descendant(of: find.byType(TagInput), matching: find.byType(TextField));
        expect(t.widget<TextField>(input).decoration?.hintText, _ad('file.custom.createPlaceholder'));
        await t.enterText(input, 'csv');
        FocusManager.instance.primaryFocus?.unfocus();
        await t.pump();
        expect(find.text('json'), findsOneWidget);
        expect(changes.last, ['json', 'csv']);
      });
    });

    group('FileUploadSetting', () {
      testWidgets('should associate file type errors with the checkboxes in feature panel mode %s', (t) async {
        for (final inFeaturePanel in [false, true]) {
          final changes = <Map<String, Object?>>[];
          final payload = _payload({'allowed_file_types': <String>[]});
          await render(
            t,
            _setting(
              payload,
              changes.add,
              inFeaturePanel: inFeaturePanel,
              validationError: (field: 'allowed_file_types', message: 'Choose a file type'),
            ),
          );
          for (final c in _checkboxes(t)) {
            expect(c.validationResult, SemanticsValidationResult.invalid, reason: 'feature panel: $inFeaturePanel');
            expect(c.hint, 'Choose a file type');
          }
          await t.tap(find.byWidgetPredicate((w) => w is DifyCheckbox && w.label == _ad('file.document.name')));
          await t.pump();
          expect(changes.last, {
            ...payload,
            'allowed_file_types': ['document'],
          });
          await render(t, _setting(_payload(), changes.add, inFeaturePanel: inFeaturePanel));
          expect(find.text('Choose a file type'), findsNothing);
          for (final c in _checkboxes(t)) {
            expect(c.validationResult, SemanticsValidationResult.none);
            expect(c.hint, isEmpty);
          }
        }
      });

      testWidgets('should associate extension errors only with the named tag input in feature panel mode %s', (
        t,
      ) async {
        for (final inFeaturePanel in [false, true]) {
          final changes = <Map<String, Object?>>[];
          final payload = _payload({
            'allowed_file_types': ['custom'],
            'allowed_file_extensions': <String>[],
          });
          await render(
            t,
            _setting(
              payload,
              changes.add,
              inFeaturePanel: inFeaturePanel,
              validationError: (field: 'allowed_file_extensions', message: 'Add an extension'),
            ),
          );
          final input = _tagInput(t);
          expect(input.label, contains(_ad('file.custom.name')));
          expect(input.validationResult, SemanticsValidationResult.invalid);
          expect(input.hint, 'Add an extension');
          final customCheckbox = t
              .getSemantics(find.byWidgetPredicate((w) => w is DifyCheckbox && w.label == _ad('file.custom.name')))
              .getSemanticsData();
          expect(customCheckbox.validationResult, SemanticsValidationResult.none);
          await t.enterText(find.descendant(of: find.byType(TagInput), matching: find.byType(TextField)), '.csv');
          await t.testTextInput.receiveAction(TextInputAction.done);
          await t.pump();
          expect(changes.last, {
            ...payload,
            'allowed_file_extensions': ['.csv'],
          });
          await render(
            t,
            _setting(
              {
                ...payload,
                'allowed_file_extensions': ['.csv'],
              },
              changes.add,
              inFeaturePanel: inFeaturePanel,
            ),
          );
          expect(_tagInput(t).validationResult, SemanticsValidationResult.none);
          expect(_tagInput(t).hint, isEmpty);
          expect(find.text('Add an extension'), findsNothing);
        }
      });

      testWidgets('should let keyboard users change upload methods while preserving the rest of the settings', (
        t,
      ) async {
        final changes = <Map<String, Object?>>[];
        final initial = _payload();
        final done = FocusNode();
        addTearDown(done.dispose);
        await render(
          t,
          _Stateful(
            initial: initial,
            builder: (p, set) => Column(
              children: [
                _setting(
                  p,
                  (v) {
                    set(v);
                    changes.add(v);
                  },
                  inFeaturePanel: true,
                  hideSupportFileType: true,
                ),
                TextButton(focusNode: done, onPressed: () {}, child: const Text('Done')),
              ],
            ),
          ),
        );
        final group = t.getSemantics(find.bySemanticsLabel(_ad('uploadFileTypes')).last).getSemanticsData();
        expect(group.role, SemanticsRole.radioGroup);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        expect(
          t.getSemantics(find.bySemanticsLabel(_ad('localUpload')).first).getSemanticsData().flagsCollection.isFocused,
          Tristate.isTrue,
        );
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.pump();
        expect(_checked(t, 'URL'), isTrue);
        expect(changes.last, {
          ...initial,
          'allowed_file_upload_methods': ['remote_url'],
        });
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.pump();
        expect(_checked(t, _ad('both')), isTrue);
        expect(changes.last, {
          ...initial,
          'allowed_file_upload_methods': ['local_file', 'remote_url'],
        });
        await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await t.pump();
        expect(_checked(t, _ad('localUpload')), isTrue);
        expect(changes.last, initial);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        expect(done.hasFocus, isTrue);
      });

      testWidgets('should keep empty and updated upload method selections controlled by the payload', (t) async {
        final changes = <Map<String, Object?>>[];
        final payload = _payload({'allowed_file_upload_methods': <String>[]});
        await render(t, _setting(payload, changes.add));
        expect(_anyChecked(t), isFalse);
        await t.tap(find.text('URL'));
        await t.pump();
        expect(changes.last, {
          ...payload,
          'allowed_file_upload_methods': ['remote_url'],
        });
        await render(
          t,
          _setting({
            ...payload,
            'allowed_file_upload_methods': ['remote_url'],
          }, changes.add),
        );
        expect(_checked(t, 'URL'), isTrue);
        await render(t, _setting(payload, changes.add));
        expect(_anyChecked(t), isFalse);
      });

      testWidgets('should update file types, upload methods, and upload limits', (t) async {
        final changes = <Map<String, Object?>>[];
        await render(t, _setting(_payload(), changes.add, isMultiple: true), width: 480);
        await t.tap(find.text(_ad('file.image.name')));
        expect(changes.last['allowed_file_types'], ['document', 'image']);
        await t.tap(find.text('URL'));
        expect(changes.last['allowed_file_upload_methods'], ['remote_url']);
        await t.enterText(_numberInput(), '5');
        expect(changes.last['max_length'], 5);
      });

      testWidgets('should keep upload limits within the configured range', (t) async {
        await render(
          t,
          _Stateful(initial: _payload(), builder: (p, set) => _setting(p, set, isMultiple: true)),
          width: 480,
        );
        String shown() => t.widget<EditableText>(_numberInput()).controller.text;
        await t.enterText(_numberInput(), '20');
        await t.pump();
        expect(shown(), '10');
        await t.enterText(_numberInput(), '0');
        await t.pump();
        expect(shown(), '1');
        await t.enterText(_numberInput(), '');
        await t.pump();
        expect(shown(), '');
        FocusManager.instance.primaryFocus?.unfocus();
        await t.pump();
        await t.pump();
        expect(shown(), '1');
      });

      testWidgets('should toggle built-in and custom file type selections', (t) async {
        final changes = <Map<String, Object?>>[];
        await render(t, _setting(_payload(), changes.add));
        await t.tap(find.text(_ad('file.document.name')));
        expect(changes.last['allowed_file_types'], isEmpty);
        await render(t, _setting(_payload(), changes.add));
        await t.tap(find.text(_ad('file.custom.name')));
        expect(changes.last['allowed_file_types'], ['custom']);
        await render(
          t,
          _setting(
            _payload({
              'allowed_file_types': ['custom'],
            }),
            changes.add,
          ),
        );
        await t.tap(find.text(_ad('file.custom.name')));
        expect(changes.last['allowed_file_types'], isEmpty);
      });

      testWidgets('should support both upload methods and update custom extensions', (t) async {
        final changes = <Map<String, Object?>>[];
        await render(t, _setting(_payload(), changes.add));
        await t.tap(find.text(_ad('both')));
        expect(changes.last['allowed_file_upload_methods'], ['local_file', 'remote_url']);
        await render(
          t,
          _setting(
            _payload({
              'allowed_file_types': ['custom'],
            }),
            changes.add,
          ),
        );
        await t.enterText(find.descendant(of: find.byType(TagInput), matching: find.byType(TextField)), 'csv');
        FocusManager.instance.primaryFocus?.unfocus();
        await t.pump();
        expect(changes.last['allowed_file_extensions'], ['pdf', 'csv']);
      });

      testWidgets('should render support file types in the feature panel and hide them when requested', (t) async {
        await render(t, _setting(_payload(), (_) {}, inFeaturePanel: true));
        expect(find.text(_ad('file.supportFileTypes')), findsOneWidget);
        await render(t, _setting(_payload(), (_) {}, inFeaturePanel: true, hideSupportFileType: true));
        expect(find.text(_ad('file.document.name')), findsNothing);
      });
    });
  });
}
