import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/features/features.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/field_hints.dart';

export '../dify_test_i18n.dart';

/// The specs' `defaultFeatures`: every feature present and off.
const Features specDefaultFeatures = {
  'moreLikeThis': {'enabled': false},
  'opening': {'enabled': false},
  'suggested': {'enabled': false},
  'text2speech': {'enabled': false},
  'speech2text': {'enabled': false},
  'citation': {'enabled': false},
  'moderation': {'enabled': false},
  'file': {'enabled': false},
  'annotationReply': {'enabled': false},
};

/// The toasts shown, as `{type, message}`.
final toasts = <({DifyToastType type, String message})>[];

/// What `onChange` was called with (`vi.fn()`): one entry per call, the features passed (or null).
class OnChangeSpy {
  final calls = <Features?>[];
  void call([Features? features]) => calls.add(features);
  bool get called => calls.isNotEmpty;
}

/// The store [render] provided (`FeaturesProvider`).
late FeaturesStore featuresStore;

/// Renders [child] (a feature card or a feature's content) in a 420 px column at the right of a 1600 x 1000 page
/// (room for the popovers on its left; the whole page with [fill]), inside `FeaturesProvider features={features}` and the host's services.
Future<void> render(
  WidgetTester t,
  Widget child, {
  Features? features,
  FeaturesServices services = const FeaturesServices(),
  LlmGroupServices llm = LlmGroupServices.empty,
  double width = 420,
  bool fill = false,
}) async {
  t.view.physicalSize = const Size(1600, 1000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  toasts.clear();
  final s = FeaturesServices(
    voices: services.voices,
    playAudition: services.playAudition,
    stopAudition: services.stopAudition,
    codeBasedExtensions: services.codeBasedExtensions,
    apiBasedExtensions: services.apiBasedExtensions,
    addApiBasedExtension: services.addApiBasedExtension,
    modelProviders: services.modelProviders,
    modelProvidersLoading: services.modelProvidersLoading,
    fileUploadConfig: services.fileUploadConfig,
    openAccountSettings: services.openAccountSettings,
    toast: (type, message) => toasts.add((type: type, message: message)),
    locale: services.locale,
    languages: services.languages,
    showOpeningModal: services.showOpeningModal,
    showModerationSettingModal: services.showModerationSettingModal,
  );
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        child: LlmGroupScope(
          services: llm,
          child: FeaturesServicesScope(
            services: s,
            child: FeaturesProvider(
              features: features,
              child: Builder(
                builder: (context) {
                  featuresStore = FeaturesScope.of(context);
                  if (fill) return child;
                  return Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SizedBox(width: width, child: child),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump();
}

/// Lets popups and dialogs finish their transitions.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Text matching [pattern] (Dify's `getByText(/.../)`), case-insensitive (uppercase utilities upper-case labels).
Finder byText(String pattern) => find.byWidgetPredicate((w) {
  final s = switch (w) {
    Text(:final data?) => data,
    Text(:final textSpan?) => textSpan.toPlainText(),
    _ => null,
  };
  return s != null && RegExp(pattern, caseSensitive: false).hasMatch(s);
}, description: 'text /$pattern/');

/// The control named [label] (`getByRole('button', { name })`), or the button around [label]'s text.
Finder button(String label) {
  final named = find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == label);
  if (named.evaluate().isNotEmpty) return named;
  return find.ancestor(of: byText(RegExp.escape(label)), matching: find.byType(DifyPressable)).first;
}

/// Whether the button holding [label]'s text is disabled.
bool isDisabled(WidgetTester t, String pattern) =>
    t.widget<DifyButton>(find.ancestor(of: byText(pattern), matching: find.byType(DifyButton)).first).disabled;

/// The [index]th switch (`getAllByRole('switch')[index]`).
Finder switchAt([int index = 0]) => find.byType(DifySwitch).at(index);

bool switchChecked(WidgetTester t, [int index = 0]) => t.widget<DifySwitch>(switchAt(index)).checked;

/// Taps [f] and lets transitions finish.
Future<void> tap(WidgetTester t, Finder f) async {
  await t.ensureVisible(f.first);
  await t.pump();
  await t.tap(f.first, warnIfMissed: false);
  await settle(t);
}

TestGesture? _mouse;

/// `fireEvent.mouseEnter`: the mouse moves onto [f].
Future<void> hover(WidgetTester t, Finder f) async {
  if (_mouse == null) {
    final m = _mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await m.addPointer(location: const Offset(1, 999));
    addTearDown(() async {
      await m.removePointer();
      _mouse = null;
    });
  }
  await _mouse!.moveTo(t.getCenter(f.first));
  await t.pump();
}

/// `fireEvent.mouseLeave`: the mouse moves to the page's corner.
Future<void> unhover(WidgetTester t) async {
  await _mouse?.moveTo(const Offset(1, 999));
  await t.pump();
}

/// The feature card titled by [pattern] (`getByText(title).closest('[class]')`).
Finder card(String pattern) => find.ancestor(of: byText(pattern), matching: find.byType(FeatureCard)).first;

/// The text field showing [text] (`getByDisplayValue`).
Finder byDisplayValue(String text) =>
    find.byWidgetPredicate((w) => w is TextField && w.controller?.text == text, description: 'field "$text"');

/// The text field with [placeholder] (`getByPlaceholderText`).
Finder byPlaceholder(String pattern) => find.byWidgetPredicate(
  (w) => w is TextField && hintTextOf(w) != null && RegExp(pattern).hasMatch(hintTextOf(w)!),
  description: 'field /$pattern/',
);

/// Focuses the control [f] (`element.focus()`).
Future<void> focusOn(WidgetTester t, Finder f) async {
  Focus.of(t.element(find.descendant(of: f, matching: find.byType(MouseRegion)).last)).requestFocus();
  await t.pump();
}
