// dify-spec: web/app/components/app/access-point/__tests__/access-point-card.spec.tsx
// dify-spec: web/app/components/app/access-point/__tests__/access-point-url.spec.tsx
import 'package:dify_sf_app/src/app_detail/access/access_point_card.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

AccessPointCard _card(WidgetTester t) => t.widget<AccessPointCard>(find.byType(AccessPointCard));

const _endpoint = (label: 'Access URL', unavailableLabel: 'FAILED', value: 'https://example.test/access');

void main() {
  group('AccessPointCard', () {
    testWidgets('marks the card when it is the highlighted access point', (t) async {
      await renderMembers(
        t,
        const AccessPointCard(
          title: 'Web App',
          description: 'Web application access',
          icon: 'robot-2-line',
          status: AccessPointStatus.inService,
          statusLabel: 'In service',
          highlighted: true,
          child: Text('Access URL'),
        ),
      );
      expect(find.bySemanticsLabel('Web App'), findsWidgets);
      expect(_card(t).highlighted, isTrue);
      // The ring of `ring-2 ring-state-accent-solid`.
      final box = t.widget<Container>(
        find.descendant(of: find.byType(AccessPointCard), matching: find.byType(Container)).first,
      );
      expect((box.decoration! as BoxDecoration).boxShadow, isNotEmpty);
      expect(find.text('Web App'), findsOneWidget);
      expect(find.text('Web application access'), findsOneWidget);
    });

    testWidgets('renders the %s state independently', (t) async {
      for (final (status, label, isLoading) in [
        (AccessPointStatus.loading, 'common.loading', true),
        (AccessPointStatus.unsupported, 'deployments.studio.accessPoint.notSupported', false),
        (AccessPointStatus.unavailable, 'deployments.health.ENVIRONMENT_STATUS_FAILED', false),
      ]) {
        await renderMembers(
          t,
          AccessPointCard(
            key: ValueKey(status),
            title: 'Web App',
            description: 'Web application access',
            icon: 'robot-2-line',
            status: status,
            statusLabel: label,
            onEnabledChange: (_) {},
            child: const Text('Access URL'),
          ),
        );
        expect(find.byWidgetPredicate((w) => w is Text && w.semanticsLabel == label), findsOneWidget);
        expect(_card(t).busy, isLoading);
        expect(find.byType(DifySwitch), findsNothing);
      }
    });

    testWidgets('keeps an unavailable switch focusable and explains why it is disabled', (t) async {
      final changes = <bool>[];
      await renderMembers(
        t,
        AccessPointCard(
          title: 'Web App',
          description: 'Web application access',
          icon: 'robot-2-line',
          status: AccessPointStatus.disabled,
          statusLabel: 'Disabled',
          switchDisabled: true,
          switchDisabledReason: 'Publish first',
          switchLabel: 'Toggle Web App',
          onEnabledChange: changes.add,
          child: const Text('Access URL'),
        ),
      );
      expect(find.bySemanticsLabel('Toggle Web App'), findsOneWidget);
      expect(switchEnabled(), isFalse);

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await settle(t);
      expect(Focus.of(t.element(find.byType(DifySwitch))).hasPrimaryFocus, isTrue);
      await settle(t, 10);
      expect(find.text('Publish first'), findsOneWidget);

      await t.tap(find.byType(DifySwitch), warnIfMissed: false);
      await settle(t);
      expect(changes, isEmpty);
    });
  });

  group('AccessPointUrl', () {
    testWidgets('keeps a disabled endpoint visible without marking it unavailable', (t) async {
      await renderMembers(
        t,
        AccessPointUrl(
          label: _endpoint.label,
          unavailableLabel: _endpoint.unavailableLabel,
          value: _endpoint.value,
          enabled: false,
          showOpen: true,
          openLabel: 'Open',
        ),
      );
      expect(find.text(_endpoint.value), findsOneWidget);
      expect(label(_endpoint.unavailableLabel), findsNothing);
      expect(isEnabled('Open'), isFalse);
    });

    testWidgets('exposes an available endpoint as an external link', (t) async {
      final opened = <String>[];
      await renderMembers(
        t,
        AccessPointUrl(
          label: _endpoint.label,
          unavailableLabel: _endpoint.unavailableLabel,
          value: _endpoint.value,
          enabled: true,
          showOpen: true,
          openLabel: 'Open',
          openUrl: _endpoint.value,
          onOpen: opened.add,
        ),
      );
      final link = linkNode('Open')!;
      expect(link.getSemanticsData().linkUrl, Uri.parse(_endpoint.value));
      await tapButton(t, 'Open');
      // `target="_blank" rel="noopener noreferrer"`: the external opener.
      expect(opened, [_endpoint.value]);
    });

    testWidgets('explains why the open action is disabled', (t) async {
      await renderMembers(
        t,
        AccessPointUrl(
          label: _endpoint.label,
          unavailableLabel: _endpoint.unavailableLabel,
          value: _endpoint.value,
          enabled: false,
          showOpen: true,
          openLabel: 'Open',
          openDisabledReason: 'Publish first',
        ),
      );
      final gesture = await t.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(t.getCenter(find.byKey(const ValueKey('access-point-open'))));
      await settle(t, 10);
      expect(find.text('Publish first'), findsOneWidget);
    });

    testWidgets('shows an unavailable endpoint without replacing it with a loading skeleton', (t) async {
      await renderMembers(
        t,
        AccessPointUrl(
          label: _endpoint.label,
          unavailableLabel: _endpoint.unavailableLabel,
          value: _endpoint.value,
          enabled: false,
          unavailable: true,
        ),
      );
      expect(label(_endpoint.unavailableLabel), findsOneWidget);
      expect(find.text(_endpoint.value), findsOneWidget);
    });

    testWidgets('shows loading independently from the unavailable state', (t) async {
      await renderMembers(
        t,
        AccessPointUrl(
          label: _endpoint.label,
          unavailableLabel: _endpoint.unavailableLabel,
          value: _endpoint.value,
          enabled: false,
          loading: true,
        ),
      );
      expect(label(_endpoint.unavailableLabel), findsNothing);
      expect(find.text(_endpoint.value), findsNothing);
    });
  });
}
