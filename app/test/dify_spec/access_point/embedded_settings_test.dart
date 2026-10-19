// dify-spec: web/app/components/app/overview/embedded/__tests__/index.spec.tsx
// dify-spec: web/app/components/app/overview/settings/__tests__/index.spec.tsx
import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/app_detail/access/embedded_modal.dart';
import 'package:dify_sf_app/src/app_detail/access/site_settings_modal.dart';
import 'package:dify_sf_app/src/design/widgets/emoji_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

// ---- Embedded -----------------------------------------------------------------------------------------------------

class _EmbedRig {
  final copied = <String>[];
  final opened = <String>[];
}

/// Embedded on `https://app.example.com` / `token` with a `#000000` theme; the hidden inputs' "compression" is the
/// identity (Dify's spec polyfills CompressionStream with a pass-through stream).
Future<_EmbedRig> _renderEmbedded(WidgetTester t, {List<Map<String, Object?>> hiddenInputs = const []}) async {
  final rig = _EmbedRig();
  await renderMembers(
    t,
    Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => EmbeddedModal(
              appBaseUrl: 'https://app.example.com',
              accessToken: 'token',
              chatColorTheme: '#000000',
              hiddenInputs: hiddenInputs,
              encode: (v) => base64Encode(utf8.encode(v)),
              copy: rig.copied.add,
              openUrl: rig.opened.add,
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
    size: const Size(1440, 1200),
  );
  await t.tap(find.text('open'));
  await settle(t);
  return rig;
}

String _pre(WidgetTester t) => t.widget<SelectableText>(find.byKey(const ValueKey('embedded-pre'))).data!;

Future<void> _option(WidgetTester t, EmbeddedOption o) async {
  await t.tap(find.byKey(ValueKey('embedded-option-${o.name}')));
  await settle(t);
}

Future<void> _copy(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('embedded-copy')));
  await settle(t);
}

// ---- Settings -----------------------------------------------------------------------------------------------------

AppInfo _settingsApp({Map<String, Object?> site = const {}}) => AppInfo.fromJson({
  'id': 'app-1',
  'name': 'Test App',
  'mode': AppModes.advancedChat,
  'site': {
    'title': 'Test App',
    'icon_type': 'emoji',
    'icon': '😀',
    'icon_background': '#ABCDEF',
    'icon_url': 'https://example.com/icon.png',
    'description': 'A description',
    'chat_color_theme': '#123456',
    'chat_color_theme_inverted': true,
    'copyright': '© Dify',
    'privacy_policy': '',
    'custom_disclaimer': 'Disclaimer',
    'input_placeholder': 'Ask me anything',
    'default_language': 'en-US',
    'show_workflow_steps': true,
    'use_icon_as_answer_icon': true,
    ...site,
  },
});

class _SettingsRig {
  final saved = <SiteConfigParams>[];
  var closed = 0;
  late StateSetter setApp;
  late AppInfo app;
}

/// The settings modal as Dify's spec renders it: Dify Cloud with the copyright entitlement unless told otherwise.
Future<_SettingsRig> _renderSettings(
  WidgetTester t, {
  AppInfo? app,
  bool canDeploy = false,
  String edition = 'CLOUD',
  bool? copyrightEnabled = true,
}) async {
  final rig = _SettingsRig()..app = app ?? _settingsApp();
  await renderMembers(
    t,
    StatefulBuilder(
      builder: (context, setState) {
        rig.setApp = setState;
        return SiteSettingsModal(
          app: rig.app,
          isChat: true,
          canDeploy: canDeploy,
          deploymentEdition: edition,
          webappCopyrightEnabled: copyrightEnabled,
          onSave: (p) async => rig.saved.add(p),
          onClose: () => rig.closed++,
        );
      },
    ),
    size: const Size(1440, 2400),
  );
  return rig;
}

Finder _field(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText));

String _text(WidgetTester t, String key) => t.widget<EditableText>(_field(key)).controller.text;

bool _readOnly(WidgetTester t, String key) => t.widget<EditableText>(_field(key)).readOnly;

Future<void> _save(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('settings-save')));
  await settle(t);
}

const _placeholderName = 'appOverview.overview.appInfo.settings.more.inputPlaceholder';

void main() {
  setUp(() async => EmojiCatalog.load());

  group('Embedded', () {
    testWidgets('copies iframe snippet', (t) async {
      final rig = await _renderEmbedded(t);
      expect(_pre(t), contains('/chatbot/token'));
      await _copy(t);
      expect(rig.copied.single, contains('/chatbot/token'));
    });

    testWidgets('opens chrome plugin store link when chrome option selected', (t) async {
      final rig = await _renderEmbedded(t);
      await _option(t, EmbeddedOption.chromePlugin);
      await t.tap(find.byKey(const ValueKey('embedded-chrome-install')));
      await settle(t);
      expect(rig.opened, ['https://chrome.google.com/webstore/detail/dify-chatbot/ceehdapohffmjmkdcifjofadiaoeggaf']);
    });

    testWidgets('calls onClose when the close button is clicked', (t) async {
      await _renderEmbedded(t);
      expect(find.byType(EmbeddedModal), findsOneWidget);
      await tapButton(t, 'common.operation.close');
      expect(find.byType(EmbeddedModal), findsNothing);
    });

    testWidgets(
      'keeps hidden inputs collapsed by default and updates iframe and script content when values change',
      (t) async {
        await _renderEmbedded(
          t,
          hiddenInputs: const [
            {
              'variable': 'secret',
              'label': 'Secret',
              'type': 'text-input',
              'hide': true,
              'required': true,
              'default': '',
            },
          ],
        );
        expect(find.byKey(const ValueKey('embedded-hidden-input-secret')), findsNothing);

        await t.tap(find.byKey(const ValueKey('embedded-hidden-inputs')));
        await settle(t);
        expect(find.byKey(const ValueKey('embedded-hidden-input-secret')), findsOneWidget);

        await t.enterText(_field('embedded-hidden-input-secret'), 'top-secret');
        await settle(t);
        expect(_pre(t), contains('/chatbot/token?secret=dG9wLXNlY3JldA%3D%3D'));

        await _option(t, EmbeddedOption.scripts);
        expect(_pre(t), contains('secret: "top-secret"'));
      },
    );

    testWidgets('copies script content when scripts option is selected', (t) async {
      final rig = await _renderEmbedded(t);
      await _option(t, EmbeddedOption.scripts);
      expect(_pre(t), contains("token: 'token'"));
      expect(_pre(t), contains('background-color: #000000'));
      await _copy(t);
      expect(rig.copied.single, contains("token: 'token'"));
    });

    testWidgets('copies chrome plugin URL (without prefix) when chromePlugin option is selected', (t) async {
      final rig = await _renderEmbedded(t);
      await _option(t, EmbeddedOption.chromePlugin);
      expect(_pre(t), contains('ChatBot URL:'));
      await _copy(t);
      expect(rig.copied.single, contains('/chatbot/token'));
      expect(rig.copied.single, isNot(contains('ChatBot URL:')));
    });
  });

  group('SettingsModal', () {
    testWidgets('should render the modal with all settings exposed by default', (t) async {
      await _renderSettings(t);
      expect(find.text('appOverview.overview.appInfo.settings.title'), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-multi-environment')), findsNothing);
      expect(find.text('appOverview.overview.appInfo.settings.more.entry'), findsNothing);
      expect(find.bySemanticsLabel(_placeholderName), findsWidgets);
      expect(find.byKey(const ValueKey('settings-copyright')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-privacy')), findsOneWidget);
    });

    testWidgets('should explain that Web app settings apply to every environment when ACL allows deploy', (t) async {
      await _renderSettings(t, canDeploy: true);
      expect(find.byKey(const ValueKey('settings-multi-environment')), findsOneWidget);
      expect(find.text('appOverview.overview.appInfo.settings.multiEnvironmentNotice'), findsOneWidget);
    });

    testWidgets('should notify the user when the name is empty', (t) async {
      final rig = await _renderSettings(t);
      await t.enterText(_field('settings-title'), '');
      await _save(t);
      expect(toastShown('app.newApp.nameNotEmpty'), isTrue);
      expect(rig.saved, isEmpty);
    });

    testWidgets('should validate the theme color and show an error when the hex is invalid', (t) async {
      final rig = await _renderSettings(t);
      await t.enterText(_field('settings-color'), 'not-a-hex');
      await _save(t);
      expect(toastShown('appOverview.overview.appInfo.settings.invalidHexMessage'), isTrue);
      expect(rig.saved, isEmpty);
    });

    testWidgets('should validate the privacy policy URL', (t) async {
      final rig = await _renderSettings(t);
      await t.enterText(_field('settings-privacy'), 'ftp://invalid-url');
      await _save(t);
      expect(toastShown('appOverview.overview.appInfo.settings.invalidPrivacyPolicy'), isTrue);
      expect(rig.saved, isEmpty);
    });

    testWidgets('should save valid settings and close the modal', (t) async {
      final rig = await _renderSettings(t);
      await _save(t);
      expect(rig.saved.single, {
        'title': 'Test App',
        'description': 'A description',
        'default_language': 'en-US',
        'chat_color_theme': '#123456',
        'chat_color_theme_inverted': true,
        'prompt_public': false,
        'copyright': '© Dify',
        'privacy_policy': '',
        'custom_disclaimer': 'Disclaimer',
        'input_placeholder': 'Ask me anything',
        'icon_type': 'emoji',
        'icon': '😀',
        'icon_background': '#ABCDEF',
        'show_workflow_steps': true,
        'use_icon_as_answer_icon': true,
      });
      expect(rig.closed, 1);
    });

    testWidgets('should not render a show-more trigger', (t) async {
      await _renderSettings(t);
      expect(find.text('appOverview.overview.appInfo.settings.more.entry'), findsNothing);
      expect(find.byKey(const ValueKey('settings-privacy')), findsOneWidget);
    });

    testWidgets('should reset local form state when the controlled dialog reopens', (t) async {
      await _renderSettings(t);
      await t.enterText(_field('settings-privacy'), 'https://changed.example');
      expect(find.byKey(const ValueKey('settings-privacy')), findsOneWidget);
      // Closing removes the dialog; opening it again starts from the app's site.
      await t.pumpWidget(const SizedBox());
      await _renderSettings(t);
      expect(find.text('appOverview.overview.appInfo.settings.more.entry'), findsNothing);
      expect(_text(t, 'settings-privacy'), '');
    });

    testWidgets('should reset the input placeholder when app info changes while open', (t) async {
      final rig = await _renderSettings(t);
      expect(_text(t, 'settings-input-placeholder'), 'Ask me anything');
      rig.setApp(() => rig.app = _settingsApp(site: {'input_placeholder': 'Updated prompt'}));
      await settle(t);
      expect(_text(t, 'settings-input-placeholder'), 'Updated prompt');
    });

    testWidgets('should preserve restricted settings when saving other Cloud settings', (t) async {
      final rig = await _renderSettings(t, copyrightEnabled: false);
      expect(_readOnly(t, 'settings-input-placeholder'), isTrue);
      expect(_text(t, 'settings-input-placeholder'), 'Ask me anything');
      expect(_readOnly(t, 'settings-copyright'), isTrue);
      await _save(t);
      expect(rig.saved.single.containsKey('copyright'), isFalse);
      expect(rig.saved.single.containsKey('input_placeholder'), isFalse);
    });

    testWidgets('should keep the input placeholder editable when billing is disabled', (t) async {
      final rig = await _renderSettings(t, edition: 'COMMUNITY', copyrightEnabled: false);
      await t.enterText(_field('settings-input-placeholder'), 'Self-hosted prompt');
      await _save(t);
      expect(_readOnly(t, 'settings-input-placeholder'), isFalse);
      expect(find.text('billing.upgradeBtn.encourageShort'), findsNothing);
      expect(rig.saved.single.containsKey('copyright'), isFalse);
      expect(rig.saved.single['input_placeholder'], 'Self-hosted prompt');
    });

    testWidgets('should hide the upgrade badge for non-sandbox plans', (t) async {
      await _renderSettings(t);
      expect(find.text('billing.upgradeBtn.encourageShort'), findsNothing);
    });

    testWidgets(
      'should preserve image icons and apply textarea or switch changes when saving image-based settings',
      (t) async {
        final rig = await _renderSettings(
          t,
          app: _settingsApp(
            site: {
              'icon_type': 'image',
              'icon': 'file-1',
              'icon_background': null,
              'icon_url': 'https://example.com/uploaded.png',
            },
          ),
        );
        await t.enterText(_field('settings-description'), 'Updated description');
        await t.enterText(_field('settings-color'), '');
        for (final key in [
          'settings-answer-icon',
          'settings-color-inverted',
          'settings-workflow-steps',
          'settings-copyright-switch',
        ]) {
          await t.tap(find.byKey(ValueKey(key)));
          await t.pump();
        }
        await _save(t);
        final saved = rig.saved.single;
        expect(saved['description'], 'Updated description');
        expect(saved['chat_color_theme'], '');
        expect(saved['chat_color_theme_inverted'], isFalse);
        expect(saved['copyright'], '');
        expect(saved['icon_type'], 'image');
        expect(saved['icon'], 'file-1');
        expect(saved.containsKey('icon_background'), isFalse);
        expect(saved['show_workflow_steps'], isFalse);
        expect(saved['use_icon_as_answer_icon'], isFalse);
      },
    );
  });

  testWidgets('saves unrelated settings while entitlements are pending without clearing protected fields', (t) async {
    final rig = await _renderSettings(t, copyrightEnabled: null);
    expect(_readOnly(t, 'settings-input-placeholder'), isTrue);
    expect(find.text('billing.upgradeBtn.encourageShort'), findsNothing);
    await _save(t);
    expect(rig.saved.single.containsKey('copyright'), isFalse);
    expect(rig.saved.single.containsKey('input_placeholder'), isFalse);
    expect(rig.saved.single['title'], 'Test App');
  });
}
