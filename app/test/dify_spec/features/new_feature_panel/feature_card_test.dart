// dify-spec: web/app/components/base/features/new-feature-panel/__tests__/feature-card.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

const icon = Text('icon', key: ValueKey('icon'));

FeatureCard featureCard({
  String? description,
  String? tooltip,
  Widget? child,
  bool disabled = false,
  ValueChanged<bool>? onChange,
  VoidCallback? onMouseEnter,
  VoidCallback? onMouseLeave,
}) => FeatureCard(
  icon: icon,
  title: 'Test Feature',
  value: false,
  description: description,
  tooltip: tooltip,
  disabled: disabled,
  onChange: onChange,
  onMouseEnter: onMouseEnter,
  onMouseLeave: onMouseLeave,
  child: child,
);

void main() {
  group('FeatureCard', () {
    testWidgets('should render icon and title', (t) async {
      await render(t, featureCard());
      expect(find.byKey(const ValueKey('icon')), findsOneWidget);
      expect(byText('Test Feature'), findsOneWidget);
    });

    testWidgets('should render description when provided', (t) async {
      await render(t, featureCard(description: 'A test description'));
      expect(byText('A test description'), findsOneWidget);
    });

    testWidgets('should not render description when not provided', (t) async {
      await render(t, featureCard());
      expect(byText('description'), findsNothing);
    });

    testWidgets('should render a switch toggle', (t) async {
      await render(t, featureCard());
      expect(switchAt(), findsOneWidget);
    });

    testWidgets('should call onChange when switch is toggled', (t) async {
      final calls = <bool>[];
      await render(t, featureCard(onChange: calls.add));
      await tap(t, switchAt());
      expect(calls, [true]);
    });

    testWidgets('should render tooltip when provided', (t) async {
      await render(t, featureCard(tooltip: 'Helpful tip'));
      expect(byText('Test Feature'), findsOneWidget);
      expect(find.bySemanticsLabel('Helpful tip'), findsOneWidget);
    });

    testWidgets('should not render tooltip when not provided', (t) async {
      await render(t, featureCard());
      expect(byText('Test Feature'), findsOneWidget);
    });

    testWidgets('should render children when provided', (t) async {
      await render(t, featureCard(child: const Text('Child', key: ValueKey('child-content'))));
      expect(find.byKey(const ValueKey('child-content')), findsOneWidget);
    });

    testWidgets('should call onMouseEnter when hovering', (t) async {
      var entered = 0;
      await render(t, featureCard(onMouseEnter: () => entered++));
      await hover(t, card('Test Feature'));
      expect(entered, 1);
    });

    testWidgets('should call onMouseLeave when mouse leaves', (t) async {
      var left = 0;
      await render(t, featureCard(onMouseEnter: () {}, onMouseLeave: () => left++));
      await hover(t, card('Test Feature'));
      await unhover(t);
      expect(left, 1);
    });

    testWidgets('should handle disabled state', (t) async {
      await render(t, featureCard(disabled: true));
      expect(switchAt(), findsOneWidget);
    });

    testWidgets('should not call onChange when onChange is not provided', (t) async {
      await render(t, featureCard());
      await tap(t, switchAt());
      expect(t.takeException(), isNull);
    });
  });
}
