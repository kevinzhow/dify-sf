// dify-spec: web/app/components/base/features/new-feature-panel/file-upload/__tests__/setting-modal.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

final features = {
  ...specDefaultFeatures,
  'file': {
    'enabled': true,
    'allowed_file_upload_methods': ['local_file'],
    'allowed_file_types': ['image'],
    'allowed_file_extensions': ['.jpg'],
    'number_limits': 5,
  },
};

final opened = <bool>[];

Future<void> renderSettings(
  WidgetTester t, {
  required bool open,
  bool disabled = false,
  bool imageUpload = false,
  OnFeaturesChange? onChange,
}) async {
  opened.clear();
  await render(
    t,
    FileUploadSettings(
      open: open,
      disabled: disabled,
      imageUpload: imageUpload,
      onOpen: opened.add,
      onChange: onChange,
      child: const Text('Upload Settings'),
    ),
    features: features,
  );
  await settle(t);
}

void main() {
  setUp(useDifyTestTranslator);

  group('FileUploadSettings (setting-modal)', () {
    testWidgets('should render children in trigger', (t) async {
      await renderSettings(t, open: false);
      expect(find.text('Upload Settings'), findsOneWidget);
    });

    testWidgets('should render SettingContent in portal', (t) async {
      await renderSettings(t, open: true);
      expect(byText(r'feature\.fileUpload\.modalTitle'), findsOneWidget);
    });

    testWidgets('should call onOpen with true when trigger is clicked', (t) async {
      await renderSettings(t, open: false);
      await tap(t, find.text('Upload Settings'));
      expect(opened, [true]);
    });

    testWidgets('should not call onOpen when disabled', (t) async {
      await renderSettings(t, open: false, disabled: true);
      await tap(t, find.text('Upload Settings'));
      expect(opened, isEmpty);
    });

    testWidgets('should call onOpen with false when cancel is clicked', (t) async {
      await renderSettings(t, open: true);
      expect(byText(r'operation\.cancel'), findsOneWidget);
      await tap(t, button('common.operation.cancel'));
      expect(opened, [false]);
    });

    testWidgets('should call onChange and close when save is clicked', (t) async {
      final onChange = OnChangeSpy();
      await renderSettings(t, open: true, onChange: onChange.call);
      expect(byText(r'operation\.save'), findsOneWidget);
      await tap(t, button('common.operation.save'));
      expect(onChange.called, isTrue);
      expect(opened, [false]);
    });

    testWidgets('should pass imageUpload prop to SettingContent', (t) async {
      await renderSettings(t, open: true, imageUpload: true);
      expect(byText(r'feature\.imageUpload\.modalTitle'), findsOneWidget);
    });
  });
}
