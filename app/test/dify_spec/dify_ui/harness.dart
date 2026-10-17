import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dify's `render`: the widget at the top-left of the page.
Future<void> render(WidgetTester t, Widget w) => renderWithSafeViewport(t, w, padding: EdgeInsets.zero);

/// Dify's `renderWithSafeViewport`: the widget inside 240 px of padding, then time for open popups to finish their
/// transition (not pumpAndSettle: loading spinners never settle).
Future<void> renderWithSafeViewport(WidgetTester t, Widget w, {EdgeInsets padding = const EdgeInsets.all(240)}) async {
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(padding: padding, child: w),
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 200));
}

/// The positioner around [inside] (Base UI's `data-side` / `data-align` live on it).
RenderDifyFloatingLayout positioner(WidgetTester t, Finder inside) => t.renderObject<RenderDifyFloatingLayout>(
  find.ancestor(of: inside, matching: find.byType(DifyFloatingLayout)).first,
);

/// The semantics node named [label] with [role] (`getByRole(role, { name })`).
SemanticsNode byRole(SemanticsRole role, String label) => find.semantics
    .byPredicate((n) => n.getSemanticsData().role == role && n.label == label, describeMatch: (_) => '$role "$label"')
    .evaluate()
    .single;

Iterable<SemanticsNode> allByRole(SemanticsRole role) =>
    find.semantics.byPredicate((n) => n.getSemanticsData().role == role).evaluate();
