// dify-spec: web/app/components/app/duplicate-modal/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/widgets/app_icon_picker.dart';
import 'package:dify_sf_app/src/studio/app_modals.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'card_harness.dart';
import 'harness.dart';

class _Rig {
  final confirmed = <DuplicatePayload>[];
  var hidden = 0;
}

Future<_Rig> _render(
  WidgetTester t, {
  String appName = 'Demo App',
  String iconType = 'emoji',
  String icon = '🤖',
  String? iconBackground,
  String? iconUrl,
}) async {
  final rig = _Rig();
  await renderMembers(
    t,
    DuplicateAppModal(
      appName: appName,
      iconType: iconType,
      icon: icon,
      iconBackground: iconBackground,
      iconUrl: iconUrl,
      onConfirm: (p) async => rig.confirmed.add(p),
      onHide: () => rig.hidden++,
    ),
  );
  return rig;
}

Finder get _name =>
    find.descendant(of: find.byKey(const ValueKey('duplicate-name')), matching: find.byType(EditableText));

const _iconButton = 'common.operation.edit explore.appCustomize.subTitle';

Future<void> _ok(WidgetTester t) async {
  await t.tap(find.text('app.iconPicker.ok'));
  await settle(t);
}

void main() {
  setUp(() async => EmojiCatalog.load());

  group('DuplicateAppModal', () {
    testWidgets('should render a named dialog', (t) async {
      await _render(t);
      expect(find.bySemanticsLabel(RegExp('duplicateTitle')), findsWidgets);
    });

    testWidgets('should validate the name before duplicating and update the input value', (t) async {
      final rig = await _render(t, appName: '  ', iconBackground: '#FFEAD5');
      await t.enterText(_name, 'Updated App');
      await t.pump();
      expect(t.widget<EditableText>(_name).controller.text, 'Updated App');
      await t.enterText(_name, '');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await settle(t);
      expect(toastShown('explore.appCustomize.nameRequired'), isTrue);
      expect(rig.confirmed, isEmpty);
      expect(rig.hidden, 0);
    });

    testWidgets('should update the selected icon before confirming the duplicate', (t) async {
      final rig = await _render(t, iconBackground: '#FFEAD5');
      await tapButton(t, _iconButton);
      expect(find.byType(DifyAppIconPicker), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('icon-color-#E4FBCC')));
      await _ok(t);
      expect(find.byType(DifyAppIconPicker), findsNothing);
      await tapButton(t, 'app.duplicate');
      expect(rig.confirmed.single, (name: 'Demo App', iconType: 'emoji', icon: '🤖', iconBackground: '#E4FBCC'));
      expect(rig.hidden, 1);
    });

    testWidgets('should call onHide when close button is clicked', (t) async {
      final rig = await _render(t, iconBackground: '#FFEAD5');
      await tapButton(t, 'common.operation.close');
      expect(rig.hidden, 1);
    });

    testWidgets('should call onHide when Escape is pressed', (t) async {
      final rig = await _render(t);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      expect(rig.hidden, 1);
    });

    testWidgets('should preserve the current image icon when the picker closes without selecting', (t) async {
      final rig = await _render(
        t,
        appName: 'Image App',
        iconType: 'image',
        icon: 'original-file',
        iconUrl: 'https://example.com/original.png',
      );
      await tapButton(t, _iconButton);
      expect(find.byType(DifyAppIconPicker), findsOneWidget);
      final emoji = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('icon-emoji-') &&
            (w.key! as ValueKey<String>).value != 'icon-emoji-search',
      );
      await t.tap(emoji.first);
      await t.pump();
      await t.tap(find.byKey(const ValueKey('icon-color-#E4FBCC')));
      await _ok(t);
      await tapButton(t, _iconButton);
      expect(find.byType(DifyAppIconPicker), findsOneWidget);
      await t.tap(find.text('app.iconPicker.cancel'));
      await settle(t);
      expect(find.byType(DifyAppIconPicker), findsNothing);
      await tapButton(t, 'app.duplicate');
      final p = rig.confirmed.single;
      expect(p.name, 'Image App');
      expect(p.iconType, 'emoji');
      expect(p.icon, isNotEmpty);
      expect(p.iconBackground, '#E4FBCC');
    });
  });
}
