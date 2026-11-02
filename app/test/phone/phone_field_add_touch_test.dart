// dify-sf phone layout (no Dify spec), PR #89 review of the phone polish: a field header's "+" (FieldAddButton) in a
// phone sheet answers a tap anywhere in the 44 dp box it reports, 2 dp inside each edge too, also with its inline line
// gap (alone: true), which would be a dead strip at the box's bottom. Cases from Winnie's review
// (pr89_field_add_review6_test.dart).
import 'dart:async';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/core_kit.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/dify_ui/phone_harness.dart' as ph;

Rect _globalRect(SemanticsNode n) {
  var r = n.rect;
  for (SemanticsNode? x = n; x != null; x = x.parent) {
    if (x.transform case final m?) r = MatrixUtils.transformRect(m, r);
  }
  return r;
}

void main() {
  for (final alone in [false, true]) {
    testWidgets('the field header\'s "+" answers its whole 44 dp target in a phone sheet (alone: $alone)', (t) async {
      final s = t.ensureSemantics();
      try {
        ph.phoneView(t);
        final nav = await ph.pumpPhoneApp(t, const DifyPage(body: SizedBox.expand()));
        var calls = 0;
        unawaited(
          showDifyBottomSheet<void>(
            nav.currentContext!,
            (_) => Center(
              child: FieldAddButton(label: 'Add input', alone: alone, onPressed: () => calls++),
            ),
          ),
        );
        await t.pumpAndSettle();
        final r = _globalRect(t.getSemantics(find.bySemanticsLabel('Add input')));
        expect(r.height, greaterThanOrEqualTo(44));
        await t.tapAt(r.center);
        await t.pump();
        expect(calls, 1);
        for (final p in [
          Offset(r.center.dx, r.top + 2),
          Offset(r.center.dx, r.bottom - 2),
          Offset(r.left + 2, r.center.dy),
          Offset(r.right - 2, r.center.dy),
        ]) {
          final old = calls;
          await t.tapAt(p);
          await t.pump();
          expect(calls, old + 1, reason: 'alone=$alone point=$p rect=$r');
        }
      } finally {
        await t.pumpWidget(const SizedBox());
        s.dispose();
      }
    });
  }
}
