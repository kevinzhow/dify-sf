// dify-spec: web/app/components/base/form/form-scenarios/auth/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/settings/form/base_form.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '_harness.dart';

const formSchemas = [FormSchema(type: FormTypeEnum.textInput, name: 'apiKey', label: 'API Key', required: true)];

void main() {
  group('AuthForm', () {
    testWidgets('should render configured fields', (t) async {
      await renderForm(t, const AuthForm(formSchemas: formSchemas));
      expect(find.text('API Key'), findsOneWidget);
      expect(find.byType(EditableText), findsOneWidget);
    });

    testWidgets('should use provided default values', (t) async {
      await renderForm(t, const AuthForm(formSchemas: formSchemas, defaultValues: {'apiKey': 'value-123'}));
      expect(hasInputValue(t, 'value-123'), isTrue);
    });

    testWidgets('should render nothing when no schema is provided', (t) async {
      await renderForm(t, const AuthForm());
      expect(find.byType(BaseField), findsNothing);
    });
  });
}
