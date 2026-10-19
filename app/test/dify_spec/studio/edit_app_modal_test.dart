// dify-spec: web/app/components/explore/create-app-modal/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/widgets/app_icon_picker.dart';
import 'package:dify_sf_app/src/design/widgets/kbd.dart';
import 'package:dify_sf_app/src/studio/app_modals.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/controls.dart' show DifyInput, DifySwitch;
import 'package:dify_sf_app/src/workflow_editor/panel_fields/form_controls.dart' show DifyTextarea;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'card_harness.dart';
import 'harness.dart';

class _Rig {
  final confirmed = <AppInfoPayload>[];
  var hidden = 0;
}

/// Dify's `setup`: a chat app "Test App" with the 🤖 icon, create mode unless [isEditModal].
Future<_Rig> _setup(
  WidgetTester t, {
  bool isEditModal = false,
  String appName = 'Test App',
  String appDescription = 'Test description',
  String appIconType = 'emoji',
  String appIcon = '🤖',
  String? appIconBackground = '#FFEAD5',
  String? appIconUrl,
  String appMode = 'chat',
  bool appUseIconAsAnswerIcon = false,
  int? maxActiveRequests,
  bool confirmDisabled = false,
}) async {
  final rig = _Rig();
  await renderMembers(
    t,
    EditAppModal(
      isEditModal: isEditModal,
      appName: appName,
      appDescription: appDescription,
      appIconType: appIconType,
      appIcon: appIcon,
      appIconBackground: appIconBackground,
      appIconUrl: appIconUrl,
      appMode: appMode,
      appUseIconAsAnswerIcon: appUseIconAsAnswerIcon,
      maxActiveRequests: maxActiveRequests,
      confirmDisabled: confirmDisabled,
      onConfirm: (p) async => rig.confirmed.add(p),
      onHide: () => rig.hidden++,
    ),
  );
  return rig;
}

Finder _text(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText));

/// Mod+Enter (`triggerHotkey('Mod+Enter')`) and the 300 ms debounce.
Future<void> _modEnter(WidgetTester t) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyEvent(LogicalKeyboardKey.enter);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump(const Duration(milliseconds: 300));
  await t.pump();
}

Future<void> _submit(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('app-modal-submit')));
  await t.pump(const Duration(milliseconds: 300));
  await t.pump();
}

Future<void> _openPicker(WidgetTester t) async {
  await tapButton(t, 'app.iconPicker.emoji');
  expect(find.byType(AppIconPicker), findsOneWidget);
}

void main() {
  setUp(() async => EmojiCatalog.load());

  group('CreateAppModal', () {
    group('Rendering', () {
      testWidgets('should render create title and actions when creating', (t) async {
        await _setup(t, appName: 'My App');
        expect(find.text('explore.appCustomize.title:{"name":"My App"}'), findsOneWidget);
        expect(buttonMatching('common.operation.create'), findsOneWidget);
        expect(button('common.operation.cancel'), findsOneWidget);
      });

      testWidgets('should render the submit shortcut with kbd primitives', (t) async {
        await _setup(t);
        expect(
          find.descendant(of: find.byKey(const ValueKey('app-modal-submit')), matching: find.byType(DifyKbd)),
          findsNWidgets(2),
        );
      });

      testWidgets('should render edit-only fields when editing a chat app', (t) async {
        await _setup(t, isEditModal: true, maxActiveRequests: 5);
        expect(find.text('app.editAppTitle'), findsOneWidget);
        expect(buttonMatching('common.operation.save'), findsOneWidget);
        expect(find.byType(DifySwitch), findsOneWidget);
        expect(t.widget<DifyInput>(find.byKey(const ValueKey('app-modal-max-active-requests'))).value, '5');
      });

      testWidgets('should render answer icon switch when editing %s app', (t) async {
        for (final mode in ['advanced-chat', 'agent-chat']) {
          await _setup(t, isEditModal: true, appMode: mode);
          expect(find.byType(DifySwitch), findsOneWidget, reason: mode);
          await t.pumpWidget(const SizedBox());
        }
      });

      testWidgets('should not render answer icon switch when editing a non-chat app', (t) async {
        await _setup(t, isEditModal: true, appMode: 'completion');
        expect(find.byType(DifySwitch), findsNothing);
      });
    });

    group('Props', () {
      testWidgets('should disable confirm action when confirmDisabled is true', (t) async {
        await _setup(t, confirmDisabled: true);
        expect(isEnabled('common.operation.create'), isFalse);
      });

      testWidgets('should disable confirm action when appName is empty', (t) async {
        await _setup(t, appName: '   ');
        expect(isEnabled('common.operation.create'), isFalse);
      });
    });

    group('Edge Cases', () {
      testWidgets('should default description to empty string when appDescription is empty', (t) async {
        await _setup(t, appDescription: '');
        expect(t.widget<EditableText>(_text('app-modal-description')).controller.text, '');
      });

      testWidgets('should render i18n key placeholders when translations are available', (t) async {
        await _setup(t);
        expect(t.widget<EditableText>(_text('app-modal-name')).controller.text, 'Test App');
        expect(
          t.widget<DifyInput>(find.byKey(const ValueKey('app-modal-name'))).placeholder,
          'app.newApp.appNamePlaceholder',
        );
        expect(t.widget<EditableText>(_text('app-modal-description')).controller.text, 'Test description');
        expect(
          t.widget<DifyTextarea>(find.byKey(const ValueKey('app-modal-description'))).placeholder,
          'app.newApp.appDescriptionPlaceholder',
        );
      });
    });

    group('User Interactions', () {
      testWidgets('should call onHide when cancel button is clicked', (t) async {
        final rig = await _setup(t);
        await tapButton(t, 'common.operation.cancel');
        expect(rig.hidden, 1);
        expect(rig.confirmed, isEmpty);
      });
    });

    group('Keyboard Shortcuts', () {
      testWidgets('should submit when Mod+Enter is pressed while visible', (t) async {
        final rig = await _setup(t);
        await _modEnter(t);
        expect(rig.confirmed, hasLength(1));
        expect(rig.hidden, 1);
      });

      testWidgets('should not submit when name is empty', (t) async {
        final rig = await _setup(t, appName: '   ');
        await _modEnter(t);
        expect(rig.confirmed, isEmpty);
        expect(rig.hidden, 0);
      });
    });

    group('App Icon Picker', () {
      testWidgets('should open and close the picker when cancel is clicked', (t) async {
        await _setup(t, appIconType: 'image', appIcon: 'file-123', appIconUrl: 'https://example.com/icon.png');
        await _openPicker(t);
        expect(find.text('app.iconPicker.cancel'), findsOneWidget);
        await t.tap(find.text('app.iconPicker.cancel'));
        await settle(t);
        expect(find.text('app.iconPicker.cancel'), findsNothing);
      });

      testWidgets('should update icon payload when selecting emoji and confirming', (t) async {
        final rig = await _setup(
          t,
          appIconType: 'image',
          appIcon: 'file-123',
          appIconUrl: 'https://example.com/icon.png',
        );
        await _openPicker(t);
        await t.tap(find.byKey(const ValueKey('icon-emoji-grinning')));
        await t.pump();
        await t.tap(find.text('app.iconPicker.ok'));
        await settle(t);
        await _submit(t);
        final p = rig.confirmed.single;
        expect((p.iconType, p.icon, p.iconBackground), ('emoji', '😀', '#FFEAD5'));
      });

      testWidgets('should allow changing only the background for the current emoji icon', (t) async {
        final rig = await _setup(t);
        await _openPicker(t);
        await t.tap(find.byKey(const ValueKey('icon-color-#E4FBCC')));
        await t.tap(find.text('app.iconPicker.ok'));
        await settle(t);
        await _submit(t);
        final p = rig.confirmed.single;
        expect((p.iconType, p.icon, p.iconBackground), ('emoji', '🤖', '#E4FBCC'));
      });
    });

    group('Submitting', () {
      testWidgets('should call onConfirm with emoji payload and hide when create is clicked', (t) async {
        final rig = await _setup(
          t,
          appName: 'My App',
          appDescription: 'My description',
          appIcon: '😀',
          appIconBackground: '#000000',
        );
        await _submit(t);
        expect(rig.confirmed, hasLength(1));
        expect(rig.hidden, 1);
        final p = rig.confirmed.single;
        expect(
          (p.name, p.iconType, p.icon, p.iconBackground, p.description, p.useIconAsAnswerIcon),
          (
            'My App',
            'emoji',
            '😀',
            '#000000',
            'My description',
            false,
          ),
        );
        expect(p.maxActiveRequests, isNull);
      });

      testWidgets('should include updated description when textarea is changed before submitting', (t) async {
        final rig = await _setup(t, appDescription: 'Old description');
        await t.enterText(_text('app-modal-description'), 'Updated description');
        await t.pump();
        await _submit(t);
        expect(rig.confirmed.single.description, 'Updated description');
      });

      testWidgets('should omit icon_background when submitting with image icon', (t) async {
        final rig = await _setup(
          t,
          appIconType: 'image',
          appIcon: 'file-123',
          appIconUrl: 'https://example.com/icon.png',
          appIconBackground: null,
        );
        await _submit(t);
        final p = rig.confirmed.single;
        expect((p.iconType, p.icon), ('image', 'file-123'));
        expect(p.iconBackground, isNull);
      });

      testWidgets('should include max_active_requests and updated answer icon when saving', (t) async {
        final rig = await _setup(t, isEditModal: true, maxActiveRequests: 3);
        await t.tap(find.byType(DifySwitch));
        await t.pump();
        await t.enterText(_text('app-modal-max-active-requests'), '12');
        await t.pump();
        await _submit(t);
        final p = rig.confirmed.single;
        expect((p.useIconAsAnswerIcon, p.maxActiveRequests), (true, 12));
      });

      testWidgets('should omit max_active_requests when input is empty', (t) async {
        final rig = await _setup(t, isEditModal: true);
        await _submit(t);
        expect(rig.confirmed.single.maxActiveRequests, isNull);
      });

      testWidgets('should omit max_active_requests when input is not a number', (t) async {
        final rig = await _setup(t, isEditModal: true);
        await t.enterText(_text('app-modal-max-active-requests'), 'abc');
        await t.pump();
        await _submit(t);
        expect(rig.confirmed.single.maxActiveRequests, isNull);
      });

      testWidgets('should show toast error and not submit when name becomes empty before debounced submit runs', (
        t,
      ) async {
        final rig = await _setup(t, appName: 'My App');
        await t.tap(find.byKey(const ValueKey('app-modal-submit')));
        await t.enterText(_text('app-modal-name'), '   ');
        await t.pump(const Duration(milliseconds: 300));
        await t.pump(const Duration(seconds: 6));
        expect(rig.confirmed, isEmpty);
        expect(rig.hidden, 0);
        expect(toastShown('explore.appCustomize.nameRequired'), isTrue);
      });
    });
  });

  testWidgets('edits an existing app without waiting for application quota data', (t) async {
    final rig = await _setup(t, isEditModal: true, appName: 'Existing', appDescription: '');
    expect(isEnabled('common.operation.save'), isTrue);
    await _submit(t);
    expect(rig.confirmed, hasLength(1));
  });
}
