// dify-spec: packages/dify-ui/src/radio-group/__tests__/index.spec.tsx
import 'control_harness.dart';

SemanticsData _radio(WidgetTester t, String name) =>
    t.getSemantics(find.widgetWithText(DifyRadio<String>, name)).getSemanticsData();

bool _checked(WidgetTester t, String name) => _radio(t, name).flagsCollection.isChecked == CheckedState.isTrue;

/// TestRadioGroup: a RadioGroup named by its legend with SSD / HDD radios in labels.
Widget _storage({String? value, String? defaultValue, ValueChanged<String>? onValueChange, bool hddDisabled = false}) =>
    DifyRadioGroup<String>(
      label: 'Storage type',
      value: value,
      defaultValue: defaultValue,
      onValueChange: onValueChange,
      children: [
        const DifyRadio<String>(value: 'ssd', label: 'SSD'),
        DifyRadio<String>(value: 'hdd', label: 'HDD', disabled: hddDisabled),
      ],
    );

class _StorageDemo extends StatefulWidget {
  const _StorageDemo();

  @override
  State<_StorageDemo> createState() => _StorageDemoState();
}

class _StorageDemoState extends State<_StorageDemo> {
  String _value = 'ssd';

  @override
  Widget build(BuildContext context) => _storage(value: _value, onValueChange: (v) => setState(() => _value = v));
}

void main() {
  group('RadioGroup', () {
    testWidgets('should manage a controlled single selection', (t) async {
      await renderControl(t, const _StorageDemo());
      expect(_checked(t, 'SSD'), isTrue);
      await t.tap(find.text('HDD'));
      await t.pump();
      expect(_checked(t, 'SSD'), isFalse);
      expect(_checked(t, 'HDD'), isTrue);
    });
    testWidgets('should compose with Dify UI Field and Fieldset without losing labels', (t) async {
      final changes = <String>[];
      await renderControl(t, _storage(value: 'ssd', onValueChange: changes.add));
      final group = t.getSemantics(find.byType(DifyRadioGroup<String>)).getSemanticsData();
      expect(group.role, SemanticsRole.radioGroup);
      expect(group.label, 'Storage type');
      expect(_checked(t, 'HDD'), isFalse);
      expect(_radio(t, 'HDD').label, 'HDD');
      await t.tap(find.text('HDD'));
      await t.pump();
      expect(changes, ['hdd']);
    });
  });

  group('Radio', () {
    testWidgets('should render unchecked and checked radios with Base UI semantics', (t) async {
      await renderControl(t, _storage(defaultValue: 'ssd'));
      final ssd = _radio(t, 'SSD'), hdd = _radio(t, 'HDD');
      expect(ssd.flagsCollection.isChecked, CheckedState.isTrue);
      expect(ssd.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
      expect(hdd.flagsCollection.isChecked, CheckedState.isFalse);
      expect(hdd.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
      // data-checked / data-unchecked: the control's look.
      final controls = t.widgetList<Container>(
        find.descendant(of: find.byType(DifyRadioControl), matching: find.byType(Container)),
      );
      final widths = [for (final c in controls) ((c.decoration! as BoxDecoration).border! as Border).top.width];
      expect(widths, [5, 1]);
    });
    testWidgets('should call onValueChange and update uncontrolled state when selected', (t) async {
      final changes = <String>[];
      await renderControl(t, _storage(defaultValue: 'ssd', onValueChange: changes.add));
      await t.tap(find.text('HDD'));
      await t.pump();
      expect(changes, ['hdd']);
      expect(_checked(t, 'HDD'), isTrue);
    });
    testWidgets('should expose disabled semantics', (t) async {
      final changes = <String>[];
      await renderControl(t, _storage(defaultValue: 'ssd', onValueChange: changes.add, hddDisabled: true));
      final hdd = _radio(t, 'HDD');
      expect(hdd.flagsCollection.isEnabled, Tristate.isFalse);
      expect(hdd.flagsCollection.isChecked, CheckedState.isFalse);
      await t.tap(find.text('HDD'));
      await t.pump();
      expect(changes, isEmpty);
    });
    testWidgets('should support custom items with a visual RadioControl', (t) async {
      await renderControl(
        t,
        DifyRadioGroup<String>(
          label: 'Card choice',
          defaultValue: 'card',
          children: [
            DifyRadioItem<String>(
              value: 'card',
              builder: (context, s) => Container(
                key: const ValueKey('custom-card'),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Card option'), DifyRadioControl()]),
              ),
            ),
          ],
        ),
      );
      expect(find.byKey(const ValueKey('custom-card')), findsOneWidget);
      expect(find.byType(DifyRadioControl), findsOneWidget);
      final item = t.getSemantics(find.byType(DifyRadioItem<String>)).getSemanticsData();
      expect(item.label, 'Card option');
      expect(item.flagsCollection.isChecked, CheckedState.isTrue);
      // The control reads the item's checked state.
      final dot = t.widget<Container>(
        find.descendant(of: find.byType(DifyRadioControl), matching: find.byType(Container)),
      );
      expect(((dot.decoration! as BoxDecoration).border! as Border).top.width, 5);
    });
  });

  group('RadioSkeleton', () {
    testWidgets('should render a visual placeholder without radio semantics', (t) async {
      final handle = t.ensureSemantics();
      await renderControl(t, const DifyRadioSkeleton());
      expect(find.byType(DifyRadioSkeleton), findsOneWidget);
      expect(
        find.semantics.byPredicate((n) => n.getSemanticsData().flagsCollection.isInMutuallyExclusiveGroup),
        findsNothing,
      );
      handle.dispose();
    });
  });

  // Keyboard: Base UI's roving tab stop and arrow keys (used by the upload-method group).
  group('DifyRadioGroup keyboard', () {
    testWidgets('arrow keys move to and check the next item, wrapping', (t) async {
      final changes = <String>[];
      await renderControl(t, _storage(defaultValue: 'ssd', onValueChange: changes.add));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(changes, ['hdd', 'ssd']);
    });
  });
}
