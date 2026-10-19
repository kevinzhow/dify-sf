// dify-spec: web/app/components/app-sidebar/nav-link/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/app_detail/app_sidebar.dart';

import 'dart:ui' show Tristate;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Widget _icon(Color color, bool selected) =>
    SizedBox(key: ValueKey(selected ? 'selected-nav-icon' : 'normal-nav-icon'), width: 18, height: 18);

Future<void> _render(WidgetTester t, {required bool active, bool disabled = false, VoidCallback? onTap}) =>
    renderDetail(
      t,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 220,
          child: AppDetailNavLink(name: 'Orchestrate', icon: _icon, active: active, disabled: disabled, onTap: onTap),
        ),
      ),
    );

void main() {
  group('NavLink', () {
    group('Active State Handling', () {
      testWidgets('should use the selected icon when the link matches the current route', (t) async {
        final active = navLinkIsActive(href: '/app/123/overview', segment: 'overview');
        expect(active, isTrue);
        await _render(t, active: active);
        expect(find.byKey(const ValueKey('selected-nav-icon')), findsOneWidget);
        expect(find.byKey(const ValueKey('normal-nav-icon')), findsNothing);
      });

      testWidgets('should not mark logs active on the annotations pathname', (t) async {
        final active = navLinkIsActive(href: '/app/123/logs', pathname: '/app/123/annotations', segment: 'overview');
        await _render(t, active: active);
        expect(find.byKey(const ValueKey('normal-nav-icon')), findsOneWidget);
        expect(find.byKey(const ValueKey('selected-nav-icon')), findsNothing);
      });

      testWidgets('should use pathname to mark annotations active when rendered outside the app detail route segment', (
        t,
      ) async {
        final active = navLinkIsActive(
          href: '/app/123/annotations',
          pathname: '/app/123/annotations',
          segment: 'overview',
        );
        await _render(t, active: active);
        expect(find.byKey(const ValueKey('selected-nav-icon')), findsOneWidget);
        expect(find.byKey(const ValueKey('normal-nav-icon')), findsNothing);
      });
    });

    group('Disabled State', () {
      testWidgets('should render as button when disabled', (t) async {
        var taps = 0;
        await _render(t, active: false, disabled: true, onTap: () => taps++);
        final node = t.getSemantics(find.bySemanticsLabel('Orchestrate'));
        expect(node.flagsCollection.isButton, isTrue);
        expect(node.flagsCollection.isEnabled, Tristate.isFalse);
        await t.tap(find.text('Orchestrate'), warnIfMissed: false);
        expect(taps, 0);
      });
    });

    group('Button Mode', () {
      testWidgets('should render as an interactive button when href is omitted', (t) async {
        var taps = 0;
        await _render(t, active: navLinkIsActive(active: true), onTap: () => taps++);
        await t.tap(find.bySemanticsLabel('Orchestrate'));
        expect(taps, 1);
      });
    });
  });
}
