// dify-spec: web/app/components/base/features/new-feature-panel/file-upload/__tests__/setting-content.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/file_upload_setting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

final defaultFile = {
  'enabled': true,
  'allowed_file_upload_methods': ['local_file'],
  'allowed_file_types': ['image'],
  'allowed_file_extensions': ['.jpg'],
  'number_limits': 5,
};

var closed = 0;

Future<void> renderContent(
  WidgetTester t, {
  bool imageUpload = false,
  OnFeaturesChange? onChange,
  bool noFile = false,
}) async {
  closed = 0;
  await render(
    t,
    SettingContent(imageUpload: imageUpload, onClose: () => closed++, onChange: onChange),
    features: {...specDefaultFeatures, 'file': noFile ? null : defaultFile},
  );
}

/// The FileUploadSetting's payload (the spec's mocked `payload` test id).
Json payload(WidgetTester t) => t.widget<FileUploadSetting>(find.byType(FileUploadSetting)).payload;

/// The FileUploadSetting's onChange with [patch] over its payload.
Future<void> changeSetting(WidgetTester t, Json patch) async {
  final w = t.widget<FileUploadSetting>(find.byType(FileUploadSetting));
  w.onChange({...w.payload, ...patch});
  await t.pump();
}

void main() {
  setUp(useDifyTestTranslator);

  group('SettingContent', () {
    testWidgets('should render file upload modal title', (t) async {
      await renderContent(t);
      expect(byText(r'feature\.fileUpload\.modalTitle'), findsOneWidget);
    });

    testWidgets('should render image upload modal title when imageUpload is true', (t) async {
      await renderContent(t, imageUpload: true);
      expect(byText(r'feature\.imageUpload\.modalTitle'), findsOneWidget);
    });

    testWidgets('should render FileUploadSetting component with payload from file feature', (t) async {
      await renderContent(t);
      expect(find.byType(FileUploadSetting), findsOneWidget);
      expect(payload(t), {
        'allowed_file_upload_methods': ['local_file'],
        'allowed_file_types': ['image'],
        'allowed_file_extensions': ['.jpg'],
        'max_length': 5,
      });
    });

    testWidgets('should use fallback payload values when file feature is undefined', (t) async {
      await renderContent(t, noFile: true);
      expect(payload(t)['allowed_file_upload_methods'], ['local_file', 'remote_url']);
      expect(payload(t)['allowed_file_types'], ['image']);
      expect(payload(t)['max_length'], 3);
    });

    testWidgets('should render cancel and save buttons', (t) async {
      await renderContent(t);
      expect(byText(r'operation\.cancel'), findsOneWidget);
      expect(byText(r'operation\.save'), findsOneWidget);
    });

    testWidgets('should call onClose when close icon is clicked', (t) async {
      await renderContent(t);
      expect(button('common.operation.close'), findsOneWidget);
      await tap(t, button('common.operation.close'));
      expect(closed, 1);
    });

    testWidgets('should call onClose when close icon receives Enter key', (t) async {
      await renderContent(t);
      await focusOn(t, button('common.operation.close'));
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(closed, 1);
    });

    testWidgets('should call onClose when close icon receives Space key', (t) async {
      await renderContent(t);
      await focusOn(t, button('common.operation.close'));
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      expect(closed, 1);
    });

    testWidgets('should not call onClose when close icon receives non-action key', (t) async {
      await renderContent(t);
      await focusOn(t, button('common.operation.close'));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(closed, 0);
    });

    testWidgets('should call onClose when cancel button is clicked to close', (t) async {
      await renderContent(t);
      await tap(t, byText(r'operation\.cancel'));
      expect(closed, 1);
    });

    testWidgets('should call onChange when save is clicked', (t) async {
      final onChange = OnChangeSpy();
      await renderContent(t, onChange: onChange.call);
      await tap(t, byText(r'operation\.save'));
      expect(onChange.called, isTrue);
    });

    testWidgets('should not throw when save is clicked without onChange', (t) async {
      await renderContent(t);
      await tap(t, byText(r'operation\.save'));
      expect(t.takeException(), isNull);
    });

    testWidgets('should disable save button when allowed file types are empty', (t) async {
      final onChange = OnChangeSpy();
      await renderContent(t, onChange: onChange.call);
      await changeSetting(t, {'allowed_file_types': <String>[]});
      expect(isDisabled(t, r'operation\.save'), isTrue);
      await tap(t, byText(r'operation\.save'));
      expect(onChange.called, isFalse);
    });

    testWidgets('should update temp payload when FileUploadSetting onChange is called', (t) async {
      await renderContent(t);
      await changeSetting(t, {
        'allowed_file_types': ['document'],
      });
      expect(payload(t)['allowed_file_types'], ['document']);
    });
  });
}
