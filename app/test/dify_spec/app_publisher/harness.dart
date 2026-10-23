import 'dart:ui' show Tristate;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

export '../dify_test_i18n.dart';
export '../dify_ui/harness.dart' show render, renderWithSafeViewport;

/// The one semantics node named [label] (`getByRole(…, { name })`; a [RegExp] matches part of the name).
SemanticsNode named(Pattern label) => find.semantics.byLabel(label).evaluate().single;

/// The semantics nodes named [label].
Iterable<SemanticsNode> allNamed(Pattern label) => find.semantics.byLabel(label).evaluate();

/// The node's role (`getByRole('status')`) and flags.
SemanticsData data(SemanticsNode n) => n.getSemanticsData();
bool isStatus(SemanticsNode n) => data(n).role == SemanticsRole.status;
bool isButton(SemanticsNode n) => data(n).flagsCollection.isButton;
bool isLink(SemanticsNode n) => data(n).flagsCollection.isLink;
bool isDisabled(SemanticsNode n) => data(n).flagsCollection.isEnabled == Tristate.isFalse;
bool isFocused(SemanticsNode n) => data(n).flagsCollection.isFocused == Tristate.isTrue;
bool isFocusable(SemanticsNode n) => data(n).flagsCollection.isFocused != Tristate.none;
bool isExpanded(SemanticsNode n) => data(n).flagsCollection.isExpanded == Tristate.isTrue;

/// The status nodes (`getByRole('status')`).
Iterable<SemanticsNode> statuses() => find.semantics.byPredicate(isStatus).evaluate();

/// Activates a node as assistive technology would (a click on it).
Future<void> activate(WidgetTester t, Pattern label) async {
  t.semantics.tap(find.semantics.byLabel(label));
  await t.pump();
}
