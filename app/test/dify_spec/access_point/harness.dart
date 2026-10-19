import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:flutter/material.dart';

import '../dify_test_i18n.dart';
import '../members/harness.dart' show settle;

export '../members/harness.dart' show settle;
export '../studio/card_harness.dart' show toastShown;

/// Dify's `render` for these specs: [child] with Dify's test translator (`<ns>.<key>`) and the app's toast host
/// (toasts stay), on a [size] page (1200 px wide by default: one card column, so the test translator's long keys fit).
Future<void> renderMembers(WidgetTester t, Widget child, {Size size = const Size(1200, 900)}) async {
  useDifyTestTranslator();
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(child: child),
      builder: (context, c) => AppLocaleScope(
        locale: AppLocale('en-US'),
        child: Stack(
          fit: StackFit.expand,
          children: [
            c!,
            const DifyToastHost(timeout: Duration.zero),
          ],
        ),
      ),
    ),
  );
  await settle(t);
}

/// Dify's `AccessPointAppInfo` fixtures as dify-sf's [AppInfo] (`AppDetailWithSite` JSON).
AppInfo accessAppInfo({
  String id = 'app-1',
  String mode = AppModes.advancedChat,
  bool enableSite = true,
  bool enableApi = true,
  String apiBaseUrl = 'https://api.example.test/v1',
  String appBaseUrl = 'https://site.example.test',
  String accessToken = 'site-code',
  List<String> permissionKeys = const [],
  Map<String, Object?> site = const {},
}) => AppInfo.fromJson({
  'id': id,
  'name': 'Test App',
  'mode': mode,
  'icon_type': 'emoji',
  'icon': '🤖',
  'icon_background': '#FFEAD5',
  'icon_url': null,
  'enable_site': enableSite,
  'enable_api': enableApi,
  'api_base_url': apiBaseUrl,
  'permission_keys': permissionKeys,
  'site': {'access_token': accessToken, 'app_base_url': appBaseUrl, 'title': 'Test App', ...site},
});

/// A recorded request: the method and its arguments.
typedef Call = (String method, List<Object?> args);

/// An [AccessApi] recording each call; [hold] keeps a call pending until its completer completes (Dify's deferred
/// promises), [fail] makes calls of a method throw.
class RecordingAccessApi implements AccessApi {
  RecordingAccessApi({this.keys = const []});

  List<AppApiKey> keys;
  final calls = <Call>[];
  final holds = <String, List<Completer<Object?>>>{};
  final fail = <String, Object>{};
  AppApiKey created = const AppApiKey(id: 'new-key', token: 'new-app-token-123');

  /// The next [count] calls of [method] wait for the returned completers (each completes with the answer to send, or
  /// an error).
  List<Completer<Object?>> hold(String method, [int count = 1]) {
    final completers = [for (var i = 0; i < count; i++) Completer<Object?>()];
    holds[method] = [...completers];
    return completers;
  }

  Future<Object?> _call(String method, List<Object?> args) async {
    calls.add((method, args));
    final held = holds[method];
    if (held != null && held.isNotEmpty) {
      final c = held.removeAt(0);
      return c.future;
    }
    if (fail[method] case final e?) throw e;
    return null;
  }

  List<List<Object?>> callsOf(String method) => [
    for (final (m, a) in calls)
      if (m == method) a,
  ];

  @override
  Future<AppSite> updateSite(String appId, AppSiteUpdate update) async {
    await _call('updateSite', [appId, update.toJson()]);
    return const AppSite(accessToken: 'site-code', title: 'Test App');
  }

  @override
  Future<AppSite> resetAccessToken(String appId) async {
    await _call('resetAccessToken', [appId]);
    return const AppSite(accessToken: 'new-code', title: 'Test App');
  }

  @override
  Future<AppInfo> setSiteEnabled(String appId, bool enable) async {
    final r = await _call('setSiteEnabled', [appId, enable]);
    return r is AppInfo ? r : accessAppInfo(enableSite: enable);
  }

  @override
  Future<AppInfo> setApiEnabled(String appId, bool enable) async {
    final r = await _call('setApiEnabled', [appId, enable]);
    return r is AppInfo ? r : accessAppInfo(enableApi: enable);
  }

  @override
  Future<List<AppApiKey>> listApiKeys(String appId) async {
    await _call('listApiKeys', [appId]);
    return keys;
  }

  @override
  Future<AppApiKey> createApiKey(String appId) async {
    await _call('createApiKey', [appId]);
    return created;
  }

  @override
  Future<void> deleteApiKey(String appId, String keyId) async {
    await _call('deleteApiKey', [appId, keyId]);
  }
}

/// The switch's semantics node (`getByRole('switch')`): toggled state and enabled flag.
SemanticsNode switchNode([int index = 0]) => find.semantics
    .byPredicate((n) => n.getSemanticsData().flagsCollection.isToggled != Tristate.none)
    .evaluate()
    .elementAt(index);

bool switchChecked([int index = 0]) =>
    switchNode(index).getSemanticsData().flagsCollection.isToggled == Tristate.isTrue;

bool switchEnabled([int index = 0]) =>
    switchNode(index).getSemanticsData().flagsCollection.isEnabled == Tristate.isTrue;

/// Taps the switch through its semantics action (a click on an enabled switch).
Future<void> tapSwitch(WidgetTester t, [int index = 0]) async {
  final n = switchNode(index);
  if (n.getSemanticsData().hasAction(SemanticsAction.tap)) n.owner!.performAction(n.id, SemanticsAction.tap);
  await settle(t);
}

/// The text of the link-semantics node labelled [label] (`getByRole('link', {name})`), or null.
SemanticsNode? linkNode(Pattern label) {
  final found = find.semantics
      .byPredicate(
        (n) =>
            !n.isMergedIntoParent &&
            n.getSemanticsData().flagsCollection.isLink &&
            n.getSemanticsData().label.contains(label),
      )
      .evaluate();
  return found.isEmpty ? null : found.first;
}

/// The button whose (merged) label is [label] (`getByRole('button', {name})`), links drawn as buttons included.
SemanticsFinder button(Pattern label) => find.semantics.byPredicate((n) {
  if (n.isMergedIntoParent) return false;
  final d = n.getSemanticsData();
  if (!d.flagsCollection.isButton) return false;
  return label is String ? d.label == label : d.label.contains(label);
}, describeMatch: (_) => 'button "$label"');

/// Taps the button labelled [label] through its semantics (as a screen reader would).
Future<void> tapButton(WidgetTester t, Pattern label) async {
  final node = button(label).evaluate().single;
  node.owner!.performAction(node.id, SemanticsAction.tap);
  await settle(t);
}

/// Whether the button labelled [label] is enabled.
bool isEnabled(Pattern label) =>
    button(label).evaluate().single.getSemanticsData().flagsCollection.isEnabled == Tristate.isTrue;

/// The text [s] as written (`getByText`): an `uppercase` utility's text is shown upper-cased with [s] as its
/// semantics label (Flutter has no CSS text-transform; jsdom's text content keeps the case).
Finder label(String s) => find.byWidgetPredicate((w) => w is Text && (w.data == s || w.semanticsLabel == s));
