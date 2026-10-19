import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart' show FakeAppsApi;
import 'package:dify_sf_app/src/studio/create_from_dsl_modal.dart' show DslFileData;
import 'package:dify_sf_app/src/studio/studio_page.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../members/harness.dart';

export '../members/harness.dart';

/// A workspace (owner, admin, plus [more]) signed in as [as], with an in-memory apps server whose caller is the same
/// account.
class StudioFixture {
  StudioFixture._(this.members, this.api);

  final MembersFixture members;
  final FakeAppsApi api;

  static Future<StudioFixture> create({
    String as = 'owner@example.com',
    List<(String email, String name, String role)> more = const [],
    DateTime Function()? clock,
  }) async {
    final m = await MembersFixture.create(as: as, more: more);
    final me = m.auth.account!;
    final api = FakeAppsApi(
      accountId: me.id,
      accountName: me.name,
      role: me.role,
      clock: clock ?? () => DateTime.utc(2026, 10, 19, 8, 30),
    );
    return StudioFixture._(m, api);
  }

  String idOf(String email) => members.idOf(email);
}

/// What the page asked to open, and the files it saved.
class StudioCalls {
  final opened = <({AppInfo app, bool readOnly})>[];
  final saved = <({String name, String yaml})>[];
  final envCalls = <String>[];
  List<Map<String, Object?>> env = const [];
  Object? envError;
  DslFileData? pickResult;
  int picks = 0;
  String? urlContent;
  final fetchedUrls = <String>[];
}

/// The Studio page on the fixture, as the app shows it (no polling, no search debounce unless [debounce]).
Future<StudioCalls> renderStudio(
  WidgetTester t,
  StudioFixture f, {
  Duration debounce = Duration.zero,
  Size size = const Size(1440, 900),
  StudioCalls? calls,
  String? fontFamily,
  AppsApi? api,
}) async {
  final c = calls ?? StudioCalls();
  await renderMembers(
    t,
    Theme(
      data: ThemeData(fontFamily: fontFamily),
      child: StudioPage(
        api: api ?? f.api,
        members: f.members.members,
        role: f.members.auth.account!.role,
        currentUserId: f.members.auth.account!.id,
        pollInterval: null,
        debounce: debounce,
        openApp: (app, {required readOnly}) async => c.opened.add((app: app, readOnly: readOnly)),
        environmentVariables: (id) async {
          c.envCalls.add(id);
          if (c.envError != null) throw c.envError!;
          return c.env;
        },
        saveDsl: (name, yaml) async => c.saved.add((name: name, yaml: yaml)),
        pickDslFile: () async {
          c.picks++;
          return c.pickResult;
        },
        fetchDslUrl: (url) async {
          c.fetchedUrls.add(url);
          return c.urlContent ?? '';
        },
      ),
    ),
    auth: f.members.auth,
  );
  if (size != const Size(1440, 900)) {
    t.view.physicalSize = size;
    await t.pump();
  }
  await settle(t);
  return c;
}

/// The page's state (its list and dialogs).
StudioPageState studioState(WidgetTester t) => t.state<StudioPageState>(find.byType(StudioPage));

/// Opens [key]'s dropdown / button with a tap and lets it animate.
Future<void> tapKey(WidgetTester t, String key) async {
  await t.tap(find.byKey(ValueKey(key)));
  await settle(t, 4);
}

/// Hovers the card of app [id] (its action bar shows).
Future<TestGesture> hoverCard(WidgetTester t, String id, {bool starred = false}) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  await g.moveTo(t.getCenter(find.byKey(ValueKey('app-card-$id')).at(starred ? 0 : 0)));
  await t.pump();
  return g;
}

/// Opens the More menu of app [id].
Future<void> openMore(WidgetTester t, String id) async {
  await hoverCard(t, id);
  await t.tap(find.byKey(ValueKey('app-card-more-$id')).last);
  await settle(t, 4);
}

/// Completes pending fake futures.
Future<void> flush(WidgetTester t) async {
  await t.runAsync(() => Future<void>.delayed(Duration.zero));
  await settle(t);
}

/// Unused-result helper for fire-and-forget calls in tests.
void ignore(Future<void> f) => unawaited(f);
