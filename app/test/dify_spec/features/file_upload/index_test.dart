// dify-spec: web/app/components/base/features/new-feature-panel/file-upload/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter_test/flutter_test.dart';

import '../file_upload/file_card.dart';
import '../harness.dart';

const title = r'feature\.fileUpload\.title';

void main() {
  setUp(useDifyTestTranslator);

  group('FileUpload', () {
    testWidgets('should render the file upload title', (t) async {
      await renderFile(t, image: false);
      expect(byText(r'feature\.fileUpload\.title'), findsOneWidget);
    });

    testWidgets('should render description when disabled', (t) async {
      await renderFile(t, image: false);
      expect(byText(r'feature\.fileUpload\.description'), findsOneWidget);
    });

    testWidgets('should render a switch toggle', (t) async {
      await renderFile(t, image: false);
      expect(switchAt(), findsOneWidget);
    });

    testWidgets('should call onChange when toggled', (t) async {
      final onChange = OnChangeSpy();
      await renderFile(t, image: false, onChange: onChange.call);
      await tap(t, switchAt());
      expect(onChange.called, isTrue);
      final file = featureMap(featuresStore.features.value, 'file');
      expect(file['enabled'], true);
      expect(file['image'], {'enabled': true});
    });

    testWidgets('should toggle without onChange callback', (t) async {
      await renderFile(t, image: false);
      await tap(t, switchAt());
      expect(t.takeException(), isNull);
    });

    testWidgets('should show supported types when enabled', (t) async {
      await renderFile(
        t,
        image: false,
        file: {
          'enabled': true,
          'allowed_file_types': ['image', 'document'],
          'number_limits': 5,
        },
      );
      expect(find.text('image,document'), findsOneWidget);
    });

    testWidgets('should show number limits when enabled', (t) async {
      await renderFile(
        t,
        image: false,
        file: {
          'enabled': true,
          'allowed_file_types': ['image'],
          'number_limits': 3,
        },
      );
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('should show dash when no allowed file types', (t) async {
      await renderFile(t, image: false, file: {'enabled': true});
      expect(find.text('-'), findsOneWidget);
    });

    testWidgets('should show settings button when hovering', (t) async {
      await renderFile(t, image: false, file: {'enabled': true});
      await hover(t, card(title));
      expect(byText(r'operation\.settings'), findsOneWidget);
    });

    testWidgets('should open setting modal when settings is clicked', (t) async {
      await renderFile(t, image: false, file: {'enabled': true});
      await openSettings(t, title);
      expect(byText(r'feature\.fileUpload\.modalTitle'), findsOneWidget);
    });

    testWidgets('should show supported types label when enabled', (t) async {
      await renderFile(
        t,
        image: false,
        file: {
          'enabled': true,
          'allowed_file_types': ['image'],
          'number_limits': 3,
        },
      );
      expect(byText(r'feature\.fileUpload\.supportedTypes'), findsOneWidget);
      expect(byText(r'feature\.fileUpload\.numberLimit'), findsOneWidget);
    });

    testWidgets('should hide info display when hovering over enabled feature', (t) async {
      await renderFile(
        t,
        image: false,
        file: {
          'enabled': true,
          'allowed_file_types': ['image'],
          'number_limits': 3,
        },
      );
      await hover(t, card(title));
      expect(byText(r'feature\.fileUpload\.supportedTypes'), findsNothing);
      expect(byText(r'operation\.settings'), findsOneWidget);
    });

    testWidgets('should show info display again when mouse leaves', (t) async {
      await renderFile(
        t,
        image: false,
        file: {
          'enabled': true,
          'allowed_file_types': ['image'],
          'number_limits': 3,
        },
      );
      await hover(t, card(title));
      await unhover(t);
      expect(byText(r'feature\.fileUpload\.supportedTypes'), findsOneWidget);
    });

    testWidgets('should close setting modal when cancel is clicked', (t) async {
      await renderFile(t, image: false, file: {'enabled': true});
      await openSettings(t, title);
      expect(byText(r'feature\.fileUpload\.modalTitle'), findsOneWidget);
      await tap(t, button('common.operation.cancel'));
      expect(byText(r'feature\.fileUpload\.modalTitle'), findsNothing);
    });
  });
}
