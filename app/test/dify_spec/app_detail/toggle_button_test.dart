// dify-spec: web/app/components/detail-sidebar/__tests__/toggle-button.spec.tsx
import 'package:dify_sf_app/src/app_detail/detail_sidebar.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<void> _render(WidgetTester t, {required bool expand, VoidCallback? onToggle}) => renderDetail(
  t,
  Center(
    child: DetailSidebarToggleButton(expand: expand, onToggle: onToggle ?? () {}),
  ),
);

void main() {
  group('DetailSidebarToggleButton', () {
    testWidgets('labels the expanded sidebar action', (t) async {
      await _render(t, expand: true);
      expect(find.bySemanticsLabel('layout.sidebar.collapseSidebar'), findsOneWidget);
    });

    testWidgets('labels the collapsed sidebar action', (t) async {
      await _render(t, expand: false);
      expect(find.bySemanticsLabel('layout.sidebar.expandSidebar'), findsOneWidget);
    });

    testWidgets('toggles the sidebar when activated', (t) async {
      var toggled = 0;
      await _render(t, expand: true, onToggle: () => toggled++);
      await t.tap(find.bySemanticsLabel('layout.sidebar.collapseSidebar'));
      expect(toggled, 1);
    });
  });
}
