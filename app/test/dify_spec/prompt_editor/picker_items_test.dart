import 'package:dify_sf_app/src/design/widgets/widgets.dart';
// dify-spec: web/app/components/base/prompt-editor/plugins/component-picker-block/__tests__/menu.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/component-picker-block/__tests__/prompt-option.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/component-picker-block/__tests__/variable-option.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/component_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<void> _hover(WidgetTester t, Finder f) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(g.removePointer);
  await g.addPointer(location: Offset.zero);
  await g.moveTo(t.getCenter(f));
  await t.pump();
}

/// The spans of a VariableMenuItem title: before, the highlighted match, after.
List<TextSpan> _spans(WidgetTester t, String title) {
  final rich = t.widget<Text>(find.descendant(of: _tooltip(title), matching: find.byType(Text)));
  return (rich.textSpan! as TextSpan).children!.cast<TextSpan>();
}

Finder _tooltip(String title) => find.byWidgetPredicate(
  (w) => w is DifyTooltip && w.content is DifyTextLine && (w.content as DifyTextLine).data == title,
);

void main() {
  group('PickerBlockMenuOption', () {
    Widget build(bool selected, String? query, VoidCallback onSelect, VoidCallback onHighlight) =>
        Text('${selected ? 'Selected' : 'Not Selected'}${query != null ? ' Query: $query' : ''}');

    group('Constructor and Initialization', () {
      test('should correctly initialize with provided key and group', () {
        final o = PickerOption(key: 'test-key', group: 'test-group', build: build);
        expect(o.key, 'test-key');
        expect(o.group, 'test-group');
      });

      test('should initialize without group when not provided', () {
        final o = PickerOption(key: 'test-key-no-group', build: build);
        expect(o.key, 'test-key-no-group');
        expect(o.group, isNull);
      });
    });

    group('onSelectMenuOption', () {
      test('should call the provided onSelect callback', () {
        var n = 0;
        PickerOption(key: 'test-key', build: build, onSelect: () => n++).onSelect?.call();
        expect(n, 1);
      });

      test('should handle cases where onSelect is not provided (optional chaining)', () {
        final o = PickerOption(key: 'test-key', build: build);
        expect(() => o.onSelect?.call(), returnsNormally);
      });
    });

    group('renderMenuOption', () {
      testWidgets('should call the render function with correct props and return the element', (t) async {
        final o = PickerOption(key: 'test-key', build: build);
        await render(t, o.build(true, 'search-string', () {}, () {}));
        expect(find.text('Selected Query: search-string'), findsOneWidget);
      });
    });
  });

  group('PromptMenuItem', () {
    late int clicks, enters;
    setUp(() => clicks = enters = 0);
    Widget item({bool disabled = false}) => PromptMenuItem(
      icon: const Text('icon', key: Key('test-icon')),
      title: 'Test Option',
      isSelected: false,
      disabled: disabled,
      onClick: () => clicks++,
      onMouseEnter: () => enters++,
    );

    group('Rendering', () {
      testWidgets('should render the icon and title correctly', (t) async {
        await render(t, item());
        expect(find.byKey(const Key('test-icon')), findsOneWidget);
        expect(find.text('Test Option'), findsOneWidget);
      });
    });

    group('Interactions', () {
      group('onClick', () {
        testWidgets('should call onClick when not disabled', (t) async {
          await render(t, item());
          await t.tap(find.text('Test Option'));
          expect(clicks, 1);
        });

        testWidgets('should NOT call onClick when disabled', (t) async {
          await render(t, item(disabled: true));
          await t.tap(find.text('Test Option'), warnIfMissed: false);
          expect(clicks, 0);
        });
      });

      group('onMouseEnter', () {
        testWidgets('should call onMouseEnter when not disabled', (t) async {
          await render(t, item());
          await _hover(t, find.text('Test Option'));
          expect(enters, 1);
        });

        testWidgets('should NOT call onMouseEnter when disabled', (t) async {
          await render(t, item(disabled: true));
          await _hover(t, find.text('Test Option'));
          expect(enters, 0);
        });
      });
    });
  });

  group('VariableMenuItem', () {
    late int clicks, enters;
    setUp(() => clicks = enters = 0);
    Widget item({String title = 'Variable Name', String? query, Widget? icon, Widget? extra}) => VariableMenuItem(
      title: title,
      isSelected: false,
      queryString: query,
      icon: icon,
      extraElement: extra,
      onClick: () => clicks++,
      onMouseEnter: () => enters++,
    );

    group('Rendering', () {
      testWidgets('should render the title correctly', (t) async {
        await render(t, item());
        expect(find.text('Variable Name', findRichText: true), findsOneWidget);
        expect(_tooltip('Variable Name'), findsOneWidget);
      });

      testWidgets('should render the icon when provided', (t) async {
        await render(t, item(icon: const Text('icon', key: Key('test-icon'))));
        expect(find.byKey(const Key('test-icon')), findsOneWidget);
      });

      testWidgets('should render the extra element when provided', (t) async {
        await render(t, item(extra: const Text('extra', key: Key('extra'))));
        expect(find.byKey(const Key('extra')), findsOneWidget);
      });
    });

    group('Highlighting Logic (queryString)', () {
      testWidgets('should not highlight anything when queryString is null', (t) async {
        await render(t, item());
        expect(_spans(t, 'Variable Name')[1].text, '');
      });

      testWidgets('should highlight matching text case-insensitively', (t) async {
        await render(t, item(title: 'User Name', query: 'user'));
        final s = _spans(t, 'User Name');
        expect(s[1].text, 'User');
        expect(s[1].style?.color, DifyColors.textAccent);
        expect(s.map((e) => e.text).join(), 'User Name');
      });

      testWidgets('should handle partial match in the middle of the string', (t) async {
        await render(t, item(title: 'System Variable', query: 'tem'));
        final s = _spans(t, 'System Variable');
        expect(s.map((e) => e.text), ['Sys', 'tem', ' Variable']);
        expect(s[1].style?.color, DifyColors.textAccent);
      });

      testWidgets('should handle no match gracefully', (t) async {
        await render(t, item(title: 'Variable', query: 'xyz'));
        expect(_spans(t, 'Variable').map((e) => e.text), ['Variable', '', '']);
      });
    });

    group('Events', () {
      testWidgets('should trigger onClick when clicked', (t) async {
        await render(t, item());
        await t.tap(_tooltip('Variable Name'));
        expect(clicks, 1);
      });

      testWidgets('should trigger onMouseEnter when mouse enters', (t) async {
        await render(t, item());
        await _hover(t, _tooltip('Variable Name'));
        expect(enters, 1);
      });
    });
  });
}
