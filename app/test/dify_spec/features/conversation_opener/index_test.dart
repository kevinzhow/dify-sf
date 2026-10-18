// dify-spec: web/app/components/base/features/new-feature-panel/conversation-opener/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

/// setShowOpeningModal.
final modalCalls = <OpeningModalRequest>[];

Future<void> renderOpener(WidgetTester t, {bool disabled = false, OnFeaturesChange? onChange, Features? overrides}) =>
    render(
      t,
      ConversationOpener(disabled: disabled, onChange: onChange),
      features: {...specDefaultFeatures, ...?overrides},
      services: FeaturesServices(showOpeningModal: (_, r) => modalCalls.add(r)),
    );

const hello = {
  'opening': {'enabled': true, 'opening_statement': 'Hello'},
};

const title = r'feature\.conversationOpener\.title';
const writeOpener = r'openingStatement\.writeOpener';

Future<void> hoverAndOpen(WidgetTester t) async {
  await hover(t, card(title));
  await tap(t, byText(writeOpener));
}

void main() {
  setUp(() {
    useDifyTestTranslator();
    modalCalls.clear();
  });

  group('ConversationOpener', () {
    testWidgets('should render the conversation opener title', (t) async {
      await renderOpener(t);
      expect(byText(title), findsOneWidget);
    });

    testWidgets('should render description when not enabled', (t) async {
      await renderOpener(t);
      expect(byText(r'feature\.conversationOpener\.description'), findsOneWidget);
    });

    testWidgets('should render a switch toggle', (t) async {
      await renderOpener(t);
      expect(switchAt(), findsOneWidget);
    });

    testWidgets('should call onChange when toggled', (t) async {
      final onChange = OnChangeSpy();
      await renderOpener(t, onChange: onChange.call);
      await tap(t, switchAt());
      expect(onChange.called, isTrue);
    });

    testWidgets('should show opening statement when enabled and not hovering', (t) async {
      await renderOpener(
        t,
        overrides: const {
          'opening': {'enabled': true, 'opening_statement': 'Welcome to the app!'},
        },
      );
      expect(find.text('Welcome to the app!'), findsOneWidget);
    });

    testWidgets('should show placeholder when enabled but no opening statement', (t) async {
      await renderOpener(
        t,
        overrides: const {
          'opening': {'enabled': true, 'opening_statement': ''},
        },
      );
      expect(byText(r'openingStatement\.placeholder'), findsOneWidget);
    });

    testWidgets('should show edit button when hovering over enabled feature', (t) async {
      await renderOpener(t, overrides: hello);
      await hover(t, card(title));
      expect(byText(writeOpener), findsOneWidget);
    });

    testWidgets('should open modal when edit button is clicked', (t) async {
      await renderOpener(t, overrides: hello);
      await hoverAndOpen(t);
      expect(modalCalls, isNotEmpty);
    });

    testWidgets('should not open modal when disabled', (t) async {
      await renderOpener(t, disabled: true, overrides: hello);
      await hoverAndOpen(t);
      expect(modalCalls, isEmpty);
    });

    testWidgets('should pass opening data to modal', (t) async {
      await renderOpener(t, overrides: hello);
      await hoverAndOpen(t);
      final call = modalCalls.first;
      expect(call.payload, {'enabled': true, 'opening_statement': 'Hello'});
      expect(call.onSaveCallback, isNotNull);
      expect(call.onCancelCallback, isNotNull);
    });

    testWidgets('should invoke onSaveCallback and update features', (t) async {
      final onChange = OnChangeSpy();
      await renderOpener(t, onChange: onChange.call, overrides: hello);
      await hoverAndOpen(t);
      modalCalls.first.onSaveCallback({'enabled': true, 'opening_statement': 'Updated'});
      expect(onChange.called, isTrue);
      expect(featureMap(featuresStore.features.value, 'opening')['opening_statement'], 'Updated');
    });

    testWidgets('should invoke onCancelCallback', (t) async {
      final onChange = OnChangeSpy();
      await renderOpener(t, onChange: onChange.call, overrides: hello);
      await hoverAndOpen(t);
      modalCalls.first.onCancelCallback();
      expect(onChange.called, isTrue);
    });

    testWidgets('should show info and hide when hovering over enabled feature', (t) async {
      await renderOpener(
        t,
        overrides: const {
          'opening': {'enabled': true, 'opening_statement': 'Welcome!'},
        },
      );
      expect(find.text('Welcome!'), findsOneWidget);
      await hover(t, card(title));
      expect(byText(writeOpener), findsOneWidget);
      expect(find.text('Welcome!'), findsNothing);
      await unhover(t);
      expect(find.text('Welcome!'), findsOneWidget);
    });

    testWidgets('should return early from opener handler when disabled and hovered', (t) async {
      await renderOpener(t, disabled: true, overrides: hello);
      await hoverAndOpen(t);
      expect(modalCalls, isEmpty);
    });

    testWidgets('should run save and cancel callbacks without onChange', (t) async {
      await renderOpener(t, overrides: hello);
      await hoverAndOpen(t);
      modalCalls.first
        ..onSaveCallback({'enabled': true, 'opening_statement': 'Updated without callback'})
        ..onCancelCallback();
      expect(modalCalls, hasLength(1));
    });

    testWidgets('should toggle feature switch without onChange callback', (t) async {
      await renderOpener(t);
      await tap(t, switchAt());
      expect(switchAt(), findsOneWidget);
    });
  });
}
