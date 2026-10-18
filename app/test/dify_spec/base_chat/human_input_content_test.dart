// dify-spec: web/app/components/base/chat/chat/answer/human-input-content/__tests__/content-item.spec.tsx
// dify-spec: web/app/components/base/chat/chat/answer/human-input-content/__tests__/content-wrapper.spec.tsx
// dify-spec: web/app/components/base/chat/chat/answer/human-input-content/__tests__/expiration-time.spec.tsx
// dify-spec: web/app/components/base/chat/chat/answer/human-input-content/__tests__/field-renderer.spec.tsx
// dify-spec: web/app/components/base/chat/chat/answer/human-input-content/__tests__/human-input-form.spec.tsx
// dify-spec: web/app/components/base/chat/chat/answer/human-input-content/__tests__/submitted-content-item.spec.tsx
// dify-spec: web/app/components/base/chat/chat/answer/human-input-content/__tests__/submitted-field-values.spec.tsx
// dify-spec: web/app/components/base/chat/chat/answer/human-input-content/__tests__/submitted.spec.tsx
// dify-spec: web/app/components/base/chat/chat/answer/human-input-content/__tests__/tips.spec.tsx
// dify-spec: web/app/components/base/chat/chat/answer/human-input-content/__tests__/unsubmitted.spec.tsx
// dify-spec: web/app/components/base/chat/chat/answer/__tests__/human-input-form-list.spec.tsx
//
// FileEntity values are HumanInputFile; FileUploaderInAttachmentWrapper is the run forms' RunFileInput (a picker
// stands in for the upload); FileList is RunFileList (file cards with names: no image previews). Titles in
// `-uppercase` styles are drawn upper case (CSS `text-transform`), so they are read from the widgets.
import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:dify_sf_app/src/cards/card_kit.dart' show DifyText;
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_model.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/selectors.dart' show DifySelect;
import 'package:dify_sf_app/src/workflow_editor/run/ui/before_run_form.dart' show RunFileInput;
import 'package:dify_sf_app/src/workflow_editor/run/ui/human_input_content.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/markdown.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart' show DifyJson;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workflow/run/run_harness.dart';

Future<void> render(WidgetTester t, Widget w) async {
  await renderRun(t, SingleChildScrollView(child: w), size: const Size(640, 900));
}

Finder textareaOf(Finder f) => find.descendant(of: f, matching: find.byType(EditableText));
Finder get textarea => textareaOf(find.byKey(const Key('content-item-textarea')));
String textOf(WidgetTester t, Finder f) => t.widget<EditableText>(f).controller.text;
DifyButton buttonOf(WidgetTester t, String label) => t.widget<DifyButton>(find.widgetWithText(DifyButton, label));

Map<String, Object?> paragraph(String name, [String value = '', String type = 'constant']) => {
  'type': 'paragraph',
  'output_variable_name': name,
  'default': {'type': type, 'value': value, 'selector': <Object?>[]},
};
Map<String, Object?> select(String name, List<String> options) => {
  'type': 'select',
  'output_variable_name': name,
  'option_source': {'type': 'constant', 'value': options, 'selector': <Object?>[]},
};
Map<String, Object?> file(String name) => {
  'type': 'file',
  'output_variable_name': name,
  'allowed_file_extensions': ['.png'],
  'allowed_file_types': ['image'],
  'allowed_file_upload_methods': ['local_file'],
};
Map<String, Object?> fileList(String name, [int? limit]) => {
  'type': 'file-list',
  'output_variable_name': name,
  'allowed_file_extensions': ['.png'],
  'allowed_file_types': ['image'],
  'allowed_file_upload_methods': ['local_file'],
  'number_limits': ?limit,
};

/// A picker that "uploads" [name] (the upload stand-in).
Future<DifyJson?> Function(String) picker(String name) =>
    (method) async => {'name': name, 'size': 1, 'type': 'document', 'transfer_method': method};

const uploaded1 = HumanInputFile(
  transferMethod: 'local_file',
  supportFileType: 'image',
  uploadedId: 'upload-file-1',
  name: 'avatar.png',
  size: 128,
);
const pending1 = HumanInputFile(
  transferMethod: 'local_file',
  supportFileType: 'image',
  progress: 50,
  name: 'avatar.png',
);
const uploaded2 = HumanInputFile(
  transferMethod: 'local_file',
  supportFileType: 'image',
  uploadedId: 'upload-file-2',
  name: 'main.png',
  size: 256,
);
const pending2 = HumanInputFile(transferMethod: 'local_file', supportFileType: 'image', progress: 50, name: 'main.png');

DifyJson fileResponse(String id, String name, {String transfer = 'local_file'}) => {
  'related_id': id,
  'upload_file_id': 'upload-$id',
  'filename': name,
  'extension': name.split('.').last,
  'size': 128,
  'mime_type': 'application/octet-stream',
  'transfer_method': transfer,
  'type': 'document',
  'url': 'https://example.com/$name',
  'remote_url': '',
};

void main() {
  group('ContentItem', () {
    final fields = [paragraph('user_bio')];
    final changes = <(String, Object?)>[];
    setUp(changes.clear);

    Future<void> item(WidgetTester t, String content, List<Object?> fields, Map<String, Object?> inputs) => render(
      t,
      HumanInputContentItem(
        content: content,
        formInputFields: fields,
        inputs: inputs,
        onInputChange: (n, v) => changes.add((n, v)),
      ),
    );

    testWidgets('should render Markdown for literal content', (t) async {
      await item(t, 'Hello world', const [], const {});
      expect(t.widget<DifyMarkdown>(find.byType(DifyMarkdown)).content, 'Hello world');
      expect(find.byKey(const Key('content-item-textarea')), findsNothing);
    });

    testWidgets('should render Textarea for valid output variable content', (t) async {
      await item(t, r'{{#$output.user_bio#}}', fields, {'user_bio': 'Initial bio'});
      expect(find.byKey(const Key('content-item-textarea')), findsOneWidget);
      expect(find.bySemanticsLabel('user_bio'), findsOneWidget);
      expect(find.byType(DifyMarkdown), findsNothing);
    });

    testWidgets('should call onInputChange when textarea value changes', (t) async {
      await item(t, r'{{#$output.user_bio#}}', fields, {'user_bio': 'Initial bio'});
      await t.enterText(textarea, 'updated value');
      expect(changes.last, ('user_bio', 'updated value'));
    });

    testWidgets('should render nothing if field name is valid but not found in formInputFields', (t) async {
      await item(t, r'{{#$output.unknown_field#}}', fields, {'user_bio': 'Initial bio'});
      expect(find.byType(HumanInputFieldRenderer), findsNothing);
      expect(find.byType(DifyMarkdown), findsNothing);
    });

    Future<void> delegates(WidgetTester t, Map<String, Object?> field, String input, String value) async {
      await item(t, '{{#\$output.$input#}}', [field], {input: null});
      final renderer = t.widget<HumanInputFieldRenderer>(find.byType(HumanInputFieldRenderer));
      expect(renderer.field, field);
      renderer.onChange(value);
      expect(changes.single, (input, value));
    }

    testWidgets('should delegate select fields to the shared renderer', (t) async {
      await delegates(t, select('user_bio', const []), 'user_bio', 'select');
    });

    testWidgets('should delegate single-file fields to the shared renderer', (t) async {
      await delegates(t, file('attachment'), 'attachment', 'file');
    });

    testWidgets('should delegate file-list fields to the shared renderer', (t) async {
      await delegates(t, fileList('attachments', 4), 'attachments', 'file-list');
    });
  });

  group('ContentWrapper', () {
    Future<void> wrapper(WidgetTester t, {bool showExpandIcon = false, bool expanded = false}) => render(
      t,
      HumanInputContentWrapper(
        nodeTitle: 'Human Input Node',
        showExpandIcon: showExpandIcon,
        expanded: expanded,
        child: const Text('Child Content', key: Key('child-content')),
      ),
    );

    testWidgets('should render node title and children by default when not collapsible', (t) async {
      await wrapper(t);
      expect(find.text('HUMAN INPUT NODE'), findsOneWidget);
      expect(find.byKey(const Key('child-content')), findsOneWidget);
      expect(find.byType(DifyPressable), findsNothing);
    });

    testWidgets('should show/hide content when toggling expansion', (t) async {
      await wrapper(t, showExpandIcon: true);
      expect(find.byKey(const Key('child-content')), findsNothing);
      final expand = find.bySemanticsLabel('share.chat.expand Human Input Node');
      expect(t.getSemantics(expand).getSemanticsData().flagsCollection.isExpanded, Tristate.isFalse);
      await t.tap(expand);
      await t.pump();
      expect(find.byKey(const Key('child-content')), findsOneWidget);
      final collapse = find.bySemanticsLabel('share.chat.collapse Human Input Node');
      expect(t.getSemantics(collapse).getSemanticsData().flagsCollection.isExpanded, Tristate.isTrue);
      await t.tap(collapse);
      await t.pump();
      expect(find.byKey(const Key('child-content')), findsNothing);
    });

    testWidgets('should expand with the %s key', (t) async {
      for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
        await t.pumpWidget(const SizedBox());
        await wrapper(t, showExpandIcon: true);
        // Focus the toggle (the first focusable), then press the key.
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        await t.sendKeyEvent(key);
        await t.pump();
        expect(find.byKey(const Key('child-content')), findsOneWidget, reason: '$key');
      }
    });

    testWidgets('should render children initially if expanded is true', (t) async {
      await wrapper(t, showExpandIcon: true, expanded: true);
      expect(find.byKey(const Key('child-content')), findsOneWidget);
      final collapse = find.bySemanticsLabel('share.chat.collapse Human Input Node');
      expect(t.getSemantics(collapse).getSemanticsData().flagsCollection.isExpanded, Tristate.isTrue);
    });
  });

  group('ExpirationTime', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    testWidgets('should render "Future" state with relative time', (t) async {
      await render(
        t,
        HumanInputExpirationTime(expirationTime: now.millisecondsSinceEpoch + 2 * 3600 * 1000, now: () => now),
      );
      expect(find.text('share.humanInput.expirationTimeNowOrFuture:{"relativeTime":"in 2 hours"}'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'time-line'), findsOneWidget);
      expect(
        t
            .widget<DifyText>(
              find.descendant(of: find.byKey(const Key('expiration-time')), matching: find.byType(DifyText)),
            )
            .color,
        DifyColors.textTertiary,
      );
    });

    testWidgets('should render "Expired" state when time is in the past', (t) async {
      await render(
        t,
        HumanInputExpirationTime(expirationTime: now.millisecondsSinceEpoch - 2 * 3600 * 1000, now: () => now),
      );
      expect(find.text('share.humanInput.expiredTip'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'alert-fill'), findsOneWidget);
      expect(
        t
            .widget<DifyText>(
              find.descendant(of: find.byKey(const Key('expiration-time')), matching: find.byType(DifyText)),
            )
            .color,
        DifyColors.textWarning,
      );
    });
  });

  group('HumanInputFieldRenderer', () {
    final changes = <Object?>[];
    setUp(changes.clear);
    Future<void> field(WidgetTester t, Object? field, Object? value, {String pick = 'report.pdf'}) => render(
      t,
      HumanInputFieldRenderer(field: field, value: value, onChange: changes.add, pickFile: picker(pick)),
    );

    testWidgets('renders paragraph input and emits string changes', (t) async {
      await field(t, paragraph('summary'), 'hello');
      await t.enterText(textarea, 'hello world');
      expect(changes.last, 'hello world');
    });

    testWidgets('renders paragraph input with an accessible name', (t) async {
      await field(t, paragraph('summary'), 'hello');
      expect(find.bySemanticsLabel('summary'), findsOneWidget);
      expect(textOf(t, textarea), 'hello');
    });

    testWidgets('renders paragraph input with an empty value when the current value is not a string', (t) async {
      await field(t, paragraph('summary'), null);
      expect(textOf(t, textarea), '');
    });

    testWidgets('renders select input and emits selected values', (t) async {
      await field(t, select('reviewer', ['alice', 'bob']), '');
      expect(t.widget<DifySelect<String>>(find.byType(DifySelect<String>)).semanticLabel, 'reviewer');
      await t.tap(find.byType(DifySelect<String>));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('alice').last);
      await t.pump();
      expect(changes, ['alice']);
    });

    testWidgets('renders single-file input and emits one file', (t) async {
      await field(t, file('attachment'), null);
      expect(t.widget<RunFileInput>(find.byType(RunFileInput)).limit, 1);
      await t.tap(find.text('common.fileUploader.uploadFromComputer'));
      await t.pump();
      expect((changes.single! as HumanInputFile).name, 'report.pdf');
    });

    testWidgets('renders existing single-file values and emits null when cleared', (t) async {
      await field(t, file('attachment'), const HumanInputFile(transferMethod: 'local_file', name: 'existing.pdf'));
      expect(find.text('existing.pdf'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('common.operation.remove'));
      await t.pump();
      expect(changes, [null]);
    });

    testWidgets('renders file-list input and emits file arrays with max count', (t) async {
      await field(t, fileList('attachments', 3), <Object?>[]);
      expect(t.widget<RunFileInput>(find.byType(RunFileInput)).limit, 3);
      await t.tap(find.text('common.fileUploader.uploadFromComputer'));
      await t.pump();
      expect([for (final f in changes.single! as List) (f as HumanInputFile).name], ['report.pdf']);
    });

    testWidgets('uses the default max count for file-list inputs without an explicit limit', (t) async {
      await field(t, fileList('attachments'), null);
      expect(t.widget<RunFileInput>(find.byType(RunFileInput)).limit, 5);
    });

    testWidgets('renders nothing for unsupported input types', (t) async {
      await field(t, {'type': 'unsupported', 'output_variable_name': 'unknown'}, '');
      expect(find.byType(EditableText), findsNothing);
      expect(find.byType(DifySelect<String>), findsNothing);
      expect(find.byType(RunFileInput), findsNothing);
    });
  });

  group('HumanInputForm', () {
    final formData = <String, Object?>{
      'form_id': 'form_1',
      'node_id': 'node_1',
      'node_title': 'Title',
      'display_in_ui': true,
      'expiration_time': 0,
      'form_token': 'token_123',
      'form_content': r'Part 1 {{#$output.field1#}} Part 2',
      'inputs': [paragraph('field1', 'initial')],
      'actions': [
        {'id': 'action_1', 'title': 'Submit', 'button_style': 'primary'},
        {'id': 'action_2', 'title': 'Cancel', 'button_style': 'default'},
        {'id': 'action_3', 'title': 'Accent', 'button_style': 'accent'},
        {'id': 'action_4', 'title': 'Ghost', 'button_style': 'ghost'},
      ],
      'resolved_default_values': <String, Object?>{},
    };

    /// Dify's mocked ContentItem: the content and buttons setting values.
    Widget mockItem(String content, void Function(String, Object?) change) => _MockItem(
      children: [
        Text(content),
        for (final (key, name, value) in [
          ('update-input', 'field1', 'new value'),
          ('update-select', 'field2', 'approved'),
          ('update-single-file', 'field4', uploaded2),
          ('update-pending-single-file', 'field4', pending2),
          ('update-input-file', 'field3', [uploaded1]),
          ('update-pending-input-file', 'field3', [pending1]),
        ])
          GestureDetector(key: Key(key), onTap: () => change(name, value), child: Text(key)),
      ],
    );

    Future<List<(String, DifyJson)>> form(WidgetTester t, DifyJson data, {Future<void> Function()? wait}) async {
      final submits = <(String, DifyJson)>[];
      await render(
        t,
        HumanInputForm(
          formData: data,
          itemBuilder: mockItem,
          onSubmit: (token, d) async {
            submits.add((token, d));
            await wait?.call();
          },
        ),
      );
      return submits;
    }

    Future<void> tapKey(WidgetTester t, String key) => tapVisible(t, find.byKey(Key(key)).first);

    testWidgets('should render content parts and action buttons', (t) async {
      await form(t, formData);
      final items = find.byType(_MockItem);
      expect(items, findsNWidgets(3));
      expect(find.text('Part 1 '), findsOneWidget);
      expect(find.text(r'{{#$output.field1#}}'), findsOneWidget);
      expect(find.text(' Part 2'), findsOneWidget);
      for (final label in ['Submit', 'Cancel', 'Accent', 'Ghost']) {
        expect(find.widgetWithText(DifyButton, label), findsOneWidget);
      }
    });

    testWidgets('should handle input changes and submit correctly', (t) async {
      final submits = await form(t, formData);
      await tapKey(t, 'update-input');
      await tapVisible(t, find.text('Submit'));
      await t.pump();
      expectSubmit(submits, (
        'token_123',
        {
          'inputs': {'field1': 'new value'},
          'action': 'action_1',
        },
      ));
    });

    testWidgets('should submit file field values using the backend payload shape', (t) async {
      final submits = await form(t, {
        ...formData,
        'form_content': r'{{#$output.field1#}} {{#$output.field3#}}',
        'inputs': [paragraph('field1', 'initial'), fileList('field3', 5)],
      });
      await tapKey(t, 'update-input');
      await tapKey(t, 'update-input-file');
      await tapVisible(t, find.text('Submit'));
      await t.pump();
      expectSubmit(submits, (
        'token_123',
        {
          'inputs': {
            'field1': 'new value',
            'field3': [
              {'type': 'image', 'transfer_method': 'local_file', 'url': '', 'upload_file_id': 'upload-file-1'},
            ],
          },
          'action': 'action_1',
        },
      ));
    });

    testWidgets('should disable buttons until select, file, and file list inputs have uploaded values', (t) async {
      final submits = await form(t, {
        ...formData,
        'form_content': r'{{#$output.field2#}} {{#$output.field3#}} {{#$output.field4#}}',
        'inputs': [
          select('field2', ['approved']),
          fileList('field3', 5),
          file('field4'),
        ],
      });
      expect(buttonOf(t, 'Submit').disabled, isTrue);
      await tapKey(t, 'update-select');
      await tapKey(t, 'update-pending-single-file');
      await tapKey(t, 'update-input-file');
      expect(buttonOf(t, 'Submit').disabled, isTrue);
      await tapKey(t, 'update-single-file');
      await tapKey(t, 'update-pending-input-file');
      expect(buttonOf(t, 'Submit').disabled, isTrue);
      await tapKey(t, 'update-input-file');
      expect(buttonOf(t, 'Submit').disabled, isFalse);
      await tapVisible(t, find.text('Submit'));
      await t.pump();
      expectSubmit(submits, (
        'token_123',
        {
          'inputs': {
            'field2': 'approved',
            'field3': [
              {'type': 'image', 'transfer_method': 'local_file', 'url': '', 'upload_file_id': 'upload-file-1'},
            ],
            'field4': {'type': 'image', 'transfer_method': 'local_file', 'url': '', 'upload_file_id': 'upload-file-2'},
          },
          'action': 'action_1',
        },
      ));
    });

    testWidgets('should ignore input fields that are not rendered in form content when checking actions', (t) async {
      final submits = await form(t, {
        ...formData,
        'form_content': r'{{#$output.field2#}}',
        'inputs': [
          select('field2', ['approved']),
          select('stale_select', ['unused']),
          file('stale_file'),
        ],
      });
      expect(buttonOf(t, 'Submit').disabled, isTrue);
      await tapKey(t, 'update-select');
      expect(buttonOf(t, 'Submit').disabled, isFalse);
      await tapVisible(t, find.text('Submit'));
      await t.pump();
      expectSubmit(submits, (
        'token_123',
        {
          'inputs': {'field2': 'approved'},
          'action': 'action_1',
        },
      ));
    });

    testWidgets('should disable buttons during submission', (t) async {
      final done = Completer<void>();
      await form(t, formData, wait: () => done.future);
      await tapVisible(t, find.text('Submit'));
      await t.pump();
      expect(buttonOf(t, 'Submit').disabled, isTrue);
      expect(buttonOf(t, 'Cancel').disabled, isTrue);
      done.complete();
      await t.pump();
      await t.pump();
      expect(buttonOf(t, 'Submit').disabled, isFalse);
      expect(buttonOf(t, 'Cancel').disabled, isFalse);
    });

    testWidgets('should handle missing resolved_default_values', (t) async {
      await form(t, {...formData}..remove('resolved_default_values'));
      expect(find.byType(_MockItem), findsNWidgets(3));
    });

    testWidgets('should handle mixed supported input types in initializeInputs', (t) async {
      await form(t, {
        ...formData,
        'inputs': [
          {
            'type': 'select',
            'output_variable_name': 'field2',
            'option_source': {'type': 'variable', 'value': <Object?>[], 'selector': <Object?>[]},
          },
          {
            'type': 'file',
            'output_variable_name': 'field3',
            'allowed_file_extensions': <Object?>[],
            'allowed_file_types': <Object?>[],
            'allowed_file_upload_methods': <Object?>[],
          },
        ],
        'resolved_default_values': {'field2': 'default value'},
      });
      expect(find.byType(_MockItem), findsNWidgets(3));
    });
  });

  final fields = <Object?>[
    paragraph('summary'),
    select('decision', ['approve', 'reject']),
    {
      'type': 'file',
      'output_variable_name': 'attachment',
      'allowed_file_extensions': <Object?>[],
      'allowed_file_types': <Object?>[],
      'allowed_file_upload_methods': <Object?>[],
    },
    {
      'type': 'file-list',
      'output_variable_name': 'evidence',
      'allowed_file_extensions': <Object?>[],
      'allowed_file_types': <Object?>[],
      'allowed_file_upload_methods': <Object?>[],
      'number_limits': 5,
    },
  ];

  group('SubmittedContentItem', () {
    final attachment = fileResponse('file-1', 'decision.pdf');
    final evidence = [
      fileResponse('file-2', 'evidence.png', transfer: 'remote_url'),
      fileResponse('file-3', 'evidence.pdf'),
    ];
    Future<void> item(WidgetTester t, String content, Map<String, Object?> values, [List<Object?>? f]) =>
        render(t, SubmittedHumanInputContentItem(content: content, formInputFields: f ?? fields, values: values));

    bool empty(WidgetTester t) =>
        find
            .descendant(of: find.byType(SubmittedHumanInputContentItem), matching: find.byType(Text))
            .evaluate()
            .isEmpty &&
        find.byType(DifySelect<String>).evaluate().isEmpty;

    testWidgets('renders file-list output placeholders as readonly file lists', (t) async {
      await item(t, r'{{#$output.evidence#}}', {'evidence': evidence});
      expect(find.byKey(const Key('submitted-field-evidence')), findsOneWidget);
      expect(find.text('evidence.png'), findsOneWidget);
      expect(find.text('evidence.pdf'), findsOneWidget);
      expect(find.byType(RunFileInput), findsNothing);
    });

    testWidgets('renders empty text for paragraph and select placeholders with non-string values', (t) async {
      await item(t, r'{{#$output.summary#}}', {'summary': attachment});
      expect(t.widget<Text>(find.byKey(const Key('submitted-field-summary'))).data, '');
      await item(t, r'{{#$output.decision#}}', {'decision': evidence});
      expect(t.widget<DifySelect<String>>(find.byType(DifySelect<String>)).value, isNull);
    });

    testWidgets('renders nothing when output placeholders do not have a usable submitted value', (t) async {
      await item(t, r'{{#$output.missing#}}', {'missing': 'value'});
      expect(empty(t), isTrue);
      await item(t, r'{{#$output.attachment#}}', {});
      expect(empty(t), isTrue);
    });

    testWidgets('skips file placeholders when submitted values have incompatible shapes', (t) async {
      await item(t, r'{{#$output.attachment#}}', {'attachment': 'not-a-file'});
      expect(empty(t), isTrue);
      await item(t, r'{{#$output.attachment#}}', {'attachment': evidence});
      expect(empty(t), isTrue);
      await item(t, r'{{#$output.evidence#}}', {'evidence': attachment});
      expect(empty(t), isTrue);
    });

    testWidgets('renders nothing for unsupported output field types', (t) async {
      await item(
        t,
        r'{{#$output.unknown#}}',
        {'unknown': 'value'},
        [
          {'type': 'unsupported', 'output_variable_name': 'unknown'},
        ],
      );
      expect(empty(t), isTrue);
    });
  });

  group('SubmittedFieldValues', () {
    final attachment = fileResponse('file-1', 'decision.pdf');
    final evidence = [
      fileResponse('file-2', 'evidence-1.png', transfer: 'remote_url'),
      fileResponse('file-3', 'evidence-2.pdf'),
    ];
    final values = <String, Object?>{
      'summary': 'Need more context',
      'decision': 'approve',
      'attachment': attachment,
      'evidence': evidence,
    };
    String fieldText(WidgetTester t, String name) => [
      for (final w in t.widgetList<Text>(
        find.descendant(of: find.byKey(Key('submitted-field-$name')), matching: find.byType(Text), matchRoot: true),
      ))
        w.data ?? '',
    ].join(' ');

    testWidgets('renders text and select values as text', (t) async {
      await render(t, SubmittedHumanInputFieldValues(fields: fields, values: values));
      expect(fieldText(t, 'summary'), 'Need more context');
      expect(fieldText(t, 'decision'), 'approve');
    });

    testWidgets('renders file and file-list values as file lists', (t) async {
      await render(t, SubmittedHumanInputFieldValues(fields: fields, values: values));
      expect(fieldText(t, 'attachment'), contains('decision.pdf'));
      expect(find.text('evidence-1.png'), findsOneWidget);
      expect(find.text('evidence-2.pdf'), findsOneWidget);
      expect(find.byKey(const Key('file-list')), findsNWidgets(2));
    });

    testWidgets('skips fields with missing values', (t) async {
      await render(t, SubmittedHumanInputFieldValues(fields: fields, values: const {'summary': 'Only one field'}));
      expect(fieldText(t, 'summary'), 'Only one field');
      expect(find.byKey(const Key('submitted-field-decision')), findsNothing);
      expect(find.byKey(const Key('submitted-field-attachment')), findsNothing);
    });

    testWidgets('infers value types when field definitions are unavailable', (t) async {
      await render(
        t,
        SubmittedHumanInputFieldValues(
          values: {'summary': 'Unstructured summary', 'attachment': attachment, 'evidence': evidence},
        ),
      );
      expect(fieldText(t, 'summary'), 'Unstructured summary');
      expect(fieldText(t, 'attachment'), contains('decision.pdf'));
      expect(find.text('evidence-1.png'), findsOneWidget);
      expect(find.text('evidence-2.pdf'), findsOneWidget);
    });

    testWidgets('skips file fields when submitted values have incompatible shapes', (t) async {
      await render(
        t,
        SubmittedHumanInputFieldValues(fields: fields, values: {'attachment': 'not-a-file', 'evidence': attachment}),
      );
      expect(find.byKey(const Key('submitted-field-attachment')), findsNothing);
      expect(find.byKey(const Key('submitted-field-evidence')), findsNothing);
    });
  });

  group('SubmittedHumanInputContent Integration', () {
    final formData = <String, Object?>{
      'rendered_content': 'Rendered **Markdown** content',
      'action_id': 'btn_1',
      'action_text': 'Submit Action',
      'node_id': 'node_1',
      'node_title': 'Node Title',
    };
    Future<void> submitted(WidgetTester t, DifyJson data) => render(t, SubmittedHumanInputContent(formData: data));

    testWidgets('should render both content and executed action', (t) async {
      await submitted(t, formData);
      expect(find.byKey(const Key('submitted-content')), findsOneWidget);
      expect(t.widget<DifyMarkdown>(find.byType(DifyMarkdown)).content, 'Rendered **Markdown** content');
      expect(find.byKey(const Key('executed-action')), findsOneWidget);
      expect(
        find.textContaining('workflow.nodes.humanInput.userActions.triggered', findRichText: true),
        findsOneWidget,
      );
    });

    testWidgets('should prefer structured form data over rendered markdown when available', (t) async {
      await submitted(t, {
        ...formData,
        'form_content': r'Decision: {{#$output.answer#}}',
        'inputs': [paragraph('answer')],
        'submitted_data': {'answer': 'approved'},
      });
      expect(find.byKey(const Key('submitted-form-content')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const Key('submitted-field-answer'))).data, 'approved');
      expect(find.byKey(const Key('submitted-content')), findsNothing);
    });

    testWidgets('should render submitted select and file fields with the original form layout', (t) async {
      await submitted(t, {
        ...formData,
        'form_content': r'{{#$output.decision#}} {{#$output.attachment#}}',
        'inputs': [fields[1], fields[2]],
        'submitted_data': {'decision': 'approve', 'attachment': fileResponse('file-1', 'decision.pdf')},
      });
      final decision = t.widget<DifySelect<String>>(find.byType(DifySelect<String>));
      expect(decision.disabled, isTrue);
      expect(decision.semanticLabel, 'decision');
      expect(decision.value, 'approve');
      expect(
        find.descendant(of: find.byKey(const Key('submitted-field-attachment')), matching: find.text('decision.pdf')),
        findsOneWidget,
      );
    });

    testWidgets('should fallback to rendered markdown when structured form data is empty', (t) async {
      await submitted(t, {...formData, 'submitted_data': <String, Object?>{}});
      expect(find.byKey(const Key('submitted-content')), findsOneWidget);
      expect(t.widget<DifyMarkdown>(find.byType(DifyMarkdown)).content, 'Rendered **Markdown** content');
      expect(find.byKey(const Key('submitted-field-values')), findsNothing);
    });

    testWidgets('should render submitted field values when original form layout is unavailable', (t) async {
      await submitted(t, {
        ...formData,
        'submitted_data': {'answer': 'approved'},
      });
      expect(find.byKey(const Key('submitted-field-values')), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const Key('submitted-field-answer'))).data, 'approved');
      expect(find.byKey(const Key('submitted-content')), findsNothing);
    });
  });

  group('Tips', () {
    Future<void> tips(WidgetTester t, bool email, bool debug, bool webapp) => render(
      t,
      HumanInputTips(showEmailTip: email, isEmailDebugMode: debug, showDebugModeTip: webapp, email: 'test@example.com'),
    );

    testWidgets('should render email tip in normal mode', (t) async {
      await tips(t, true, false, false);
      expect(find.text('workflow.common.humanInputEmailTip'), findsOneWidget);
      expect(find.textContaining('humanInputEmailTipInDebugMode', findRichText: true), findsNothing);
      expect(find.text('workflow.common.humanInputWebappTip'), findsNothing);
    });

    testWidgets('should render email tip in debug mode', (t) async {
      await tips(t, true, true, false);
      expect(
        find.textContaining(
          'workflow.common.humanInputEmailTipInDebugMode:{"email":"test@example.com"}',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('workflow.common.humanInputEmailTip'), findsNothing);
    });

    testWidgets('should render debug mode tip', (t) async {
      await tips(t, false, false, true);
      expect(find.text('workflow.common.humanInputWebappTip'), findsOneWidget);
      expect(find.text('workflow.common.humanInputEmailTip'), findsNothing);
    });

    testWidgets('should render nothing when all flags are false', (t) async {
      await tips(t, false, false, false);
      expect(find.descendant(of: find.byKey(const Key('tips')), matching: find.byType(Text)), findsNothing);
      expect(find.byType(DifyDivider), findsOneWidget);
    });
  });

  group('UnsubmittedHumanInputContent Integration', () {
    DifyJson formData([Map<String, Object?> o = const {}]) => {
      'form_id': 'form_123',
      'node_id': 'node_456',
      'node_title': 'Input Form',
      'form_content': r'Fill this out: {{#$output.user_name#}}',
      'inputs': [paragraph('user_name', 'Default value')],
      'actions': [
        {'id': 'btn_1', 'title': 'Submit', 'button_style': 'primary'},
      ],
      'form_token': 'token_123',
      'resolved_default_values': <String, Object?>{},
      'expiration_time': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
      'display_in_ui': true,
      ...o,
    };
    Future<List<(String, DifyJson)>> content(
      WidgetTester t,
      DifyJson data, {
      bool email = false,
      bool debug = false,
      bool webapp = false,
      Future<void> Function()? wait,
    }) async {
      final submits = <(String, DifyJson)>[];
      await render(
        t,
        UnsubmittedHumanInputContent(
          formData: data,
          showEmailTip: email,
          isEmailDebugMode: debug,
          showDebugModeTip: webapp,
          onSubmit: (token, d) async {
            submits.add((token, d));
            await wait?.call();
          },
        ),
      );
      return submits;
    }

    group('Rendering', () {
      testWidgets('should render form, tips, and expiration time when all conditions met', (t) async {
        await content(t, formData(), email: true, webapp: true);
        expect(find.text('Submit'), findsOneWidget);
        expect(find.byKey(const Key('tips')), findsOneWidget);
        expect(find.byKey(const Key('expiration-time')), findsOneWidget);
        expect(find.text('workflow.common.humanInputWebappTip'), findsOneWidget);
      });

      testWidgets('should hide ExpirationTime when expiration_time is not a number', (t) async {
        await content(t, formData({'expiration_time': null}));
        expect(find.byKey(const Key('expiration-time')), findsNothing);
      });

      testWidgets('should hide Tips when both tip flags are false', (t) async {
        await content(t, formData());
        expect(find.byKey(const Key('tips')), findsNothing);
      });

      testWidgets('should render different email tips based on debug mode', (t) async {
        await content(t, formData(), email: true);
        expect(find.text('workflow.common.humanInputEmailTip'), findsOneWidget);
        await content(t, formData(), email: true, debug: true);
        expect(
          find.textContaining('workflow.common.humanInputEmailTipInDebugMode', findRichText: true),
          findsOneWidget,
        );
      });

      testWidgets('should render "Expired" state when expiration time is in the past', (t) async {
        await content(t, formData({'expiration_time': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600}));
        expect(find.text('share.humanInput.expiredTip'), findsOneWidget);
      });
    });

    group('Interactions', () {
      testWidgets('should update input values and call onSubmit', (t) async {
        final submits = await content(t, formData());
        await t.enterText(textarea, 'New Value');
        await tapVisible(t, find.text('Submit'));
        await t.pump();
        expectSubmit(submits, (
          'token_123',
          {
            'inputs': {'user_name': 'New Value'},
            'action': 'btn_1',
          },
        ));
      });

      testWidgets('should handle loading state during submission', (t) async {
        final done = Completer<void>();
        final submits = await content(t, formData(), wait: () => done.future);
        await tapVisible(t, find.text('Submit'));
        await t.pump();
        expect(buttonOf(t, 'Submit').disabled, isTrue);
        expect(submits, hasLength(1));
        done.complete();
        await t.pump();
        await t.pump();
        expect(buttonOf(t, 'Submit').disabled, isFalse);
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle missing resolved_default_values', (t) async {
        await content(t, formData({'resolved_default_values': null}));
        expect(find.text('Submit'), findsOneWidget);
      });

      testWidgets('should return null in ContentItem if field is not found', (t) async {
        await content(t, formData({'form_content': r'{{#$output.unknown_field#}}', 'inputs': <Object?>[]}));
        expect(find.byType(EditableText), findsNothing);
      });

      testWidgets('should render text-input type in initializeInputs correctly', (t) async {
        await content(
          t,
          formData({
            'inputs': [
              {
                'type': 'text-input',
                'output_variable_name': 'var1',
                'label': 'Var 1',
                'required': true,
                'default': {'type': 'fixed', 'value': 'fixed_val'},
              },
            ],
          }),
        );
        expect(t.takeException(), isNull);
      });
    });
  });

  group('HumanInputFormList', () {
    final forms = <DifyJson>[
      {'form_id': 'form1', 'node_id': 'node1', 'node_title': 'Title 1', 'display_in_ui': true},
      {'form_id': 'form2', 'node_id': 'node2', 'node_title': 'Title 2', 'display_in_ui': false},
    ];
    Future<void> list(WidgetTester t, List<DifyJson> forms, [DifyJson? Function(String)? nodeData]) =>
        render(t, HumanInputFormList(humanInputFormDataList: forms, getHumanInputNodeData: nodeData));
    UnsubmittedHumanInputContent unsubmitted(WidgetTester t) =>
        t.widget<UnsubmittedHumanInputContent>(find.byType(UnsubmittedHumanInputContent));

    testWidgets('should render empty list when no form data is provided', (t) async {
      await list(t, const []);
      expect(find.byKey(const Key('human-input-form-list')), findsOneWidget);
      expect(find.byType(HumanInputContentWrapper), findsNothing);
    });

    testWidgets('should render only items with display_in_ui set to true', (t) async {
      await list(t, forms, (_) => {'delivery_methods': <Object?>[]});
      expect(find.byKey(const Key('human-input-form-item')), findsOneWidget);
      expect(t.widget<HumanInputContentWrapper>(find.byType(HumanInputContentWrapper)).nodeTitle, 'Title 1');
    });

    group('Delivery Methods Config', () {
      testWidgets('should set default tips when node data is not found', (t) async {
        await list(t, [forms.first], (_) => null);
        final u = unsubmitted(t);
        expect((u.showEmailTip, u.isEmailDebugMode, u.showDebugModeTip), (false, false, false));
      });

      testWidgets('should set default tips when delivery_methods is empty', (t) async {
        await list(t, [forms.first], (_) => {'delivery_methods': <Object?>[]});
        final u = unsubmitted(t);
        expect((u.showEmailTip, u.isEmailDebugMode, u.showDebugModeTip), (false, false, false));
      });

      testWidgets('should show tips correctly based on delivery methods', (t) async {
        await list(
          t,
          [forms.first],
          (_) => {
            'delivery_methods': [
              {'type': 'webapp', 'enabled': true},
              {
                'type': 'email',
                'enabled': true,
                'config': {'debug_mode': true},
              },
            ],
          },
        );
        final u = unsubmitted(t);
        expect((u.showEmailTip, u.isEmailDebugMode, u.showDebugModeTip), (true, true, false));
      });

      testWidgets('should show debug mode tip if WebApp is disabled', (t) async {
        await list(
          t,
          [forms.first],
          (_) => {
            'delivery_methods': [
              {'type': 'webapp', 'enabled': false},
              {'type': 'email', 'enabled': false},
            ],
          },
        );
        final u = unsubmitted(t);
        expect(u.showEmailTip, isFalse);
        expect(u.showDebugModeTip, isTrue);
      });
    });
  });
}

/// Dify's mocked ContentItem.
class _MockItem extends StatelessWidget {
  const _MockItem({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(children: children);
}

void expectSubmit(List<(String, DifyJson)> submits, (String, DifyJson) want) {
  expect(submits, hasLength(1));
  expect(submits.single.$1, want.$1);
  expect(submits.single.$2, want.$2);
}

/// Scrolls [f] into view and taps it.
Future<void> tapVisible(WidgetTester t, Finder f) async {
  await t.ensureVisible(f);
  await t.pump();
  await t.tap(f);
  await t.pump();
}
