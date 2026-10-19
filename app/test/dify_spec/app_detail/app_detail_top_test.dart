// dify-spec: web/app/components/app-sidebar/__tests__/app-detail-top.spec.tsx
//
// dify-sf's home is the Studio: both the home control and the breadcrumb lead there.
import 'package:dify_sf_app/src/app_detail/app_sidebar.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<List<String>> _render(WidgetTester t, {VoidCallback? onToggle}) async {
  final calls = <String>[];
  await renderDetail(
    t,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 240,
        child: AppDetailTop(expand: true, onToggle: onToggle, onHome: () => calls.add('home')),
      ),
    ),
  );
  return calls;
}

void main() {
  group('AppDetailTop', () {
    testWidgets('links the combined home control to home', (t) async {
      final calls = await _render(t);
      await t.tap(find.bySemanticsLabel('common.mainNav.home'));
      expect(calls, ['home']);
      expect(find.bySemanticsLabel('common.operation.back'), findsNothing);
    });

    testWidgets('links the Studio breadcrumb to the Studio page', (t) async {
      final calls = await _render(t);
      expect(find.text('COMMON.MENUS.APPS'), findsOneWidget, reason: 'system-sm-semibold-uppercase');
      await t.tap(find.bySemanticsLabel('common.menus.apps'));
      expect(calls, ['home']);
    });

    testWidgets('renders the sidebar toggle action in the top right', (t) async {
      var toggled = 0;
      await _render(t, onToggle: () => toggled++);
      final toggle = find.bySemanticsLabel('layout.sidebar.collapseSidebar');
      await t.tap(toggle);
      expect(toggled, 1);
      expect(t.getTopLeft(toggle).dx, greaterThan(t.getTopLeft(find.bySemanticsLabel('common.menus.apps')).dx));
    });
  });
}
