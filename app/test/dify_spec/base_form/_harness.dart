import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:dify_sf_app/src/settings/form/base_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_test_i18n.dart';

/// [child] on a page with Dify's test translator and the toast host.
Future<void> renderForm(WidgetTester t, Widget child) async {
  useDifyTestTranslator();
  t.view.physicalSize = const Size(1200, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 600, child: SingleChildScrollView(child: child)),
        ),
      ),
      builder: (context, c) => AppLocaleScope(
        locale: AppLocale('en-US'),
        child: Stack(
          fit: StackFit.expand,
          children: [
            c!,
            const DifyToastHost(timeout: Duration.zero),
          ],
        ),
      ),
    ),
  );
  await t.pump();
}

/// The text of the input of field [name].
String inputText(WidgetTester t, String name) => t
    .widget<EditableText>(
      find.descendant(of: find.byKey(ValueKey('form-input-$name')), matching: find.byType(EditableText)),
    )
    .controller
    .text;

/// The editable text of field [name].
Finder input(String name) =>
    find.descendant(of: find.byKey(ValueKey('form-input-$name')), matching: find.byType(EditableText));

/// Whether [text] is shown in some input.
bool hasInputValue(WidgetTester t, String text) =>
    t.widgetList<EditableText>(find.byType(EditableText)).any((e) => e.controller.text == text);

/// The semantics of the input of field [name].
SemanticsData inputSemantics(WidgetTester t, String name) => t
    .getSemantics(find.descendant(of: find.byKey(ValueKey('form-input-$name')), matching: find.byType(EditableText)))
    .getSemanticsData();

/// The value of field [name] of [form].
Object? valueOf(GlobalKey<BaseFormState> form, String name) => form.currentState!.getForm().value(name);
