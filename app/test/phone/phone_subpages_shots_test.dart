/// Renders an opened app's pages on a phone to PNG files, for the audit and for eyeballing the phone layout, with the
/// bundled Noto Sans. Runs only when `SUBPAGES_SHOTS` names an output directory:
///
///     SUBPAGES_SHOTS=/var/tmp/<you>/shots flutter test test/phone/phone_subpages_shots_test.dart
///
/// Each shot also lists the layout errors (overflows) the page raised, in `<dir>/errors.txt`.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/app_detail/app_detail_page.dart';
import 'package:dify_sf_app/src/app_detail/detail_page_slot.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/human_input/human_input_form_page.dart';
import 'package:dify_sf_app/src/public_app/public_app_page.dart';

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

void main() {
  final out = Platform.environment['SUBPAGES_SHOTS'];
  if (out == null || out.isEmpty) return;
  final errors = StringBuffer();

  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
    Directory(out).createSync(recursive: true);
  });
  tearDownAll(() => File('$out/errors.txt').writeAsStringSync(errors.toString()));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final boundary = GlobalKey();

  Future<void> shot(WidgetTester t, String name) async {
    await settle(t, 600);
    final image = await t.runAsync(() async {
      final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await ro.toImage(pixelRatio: 1.0);
      return img.toByteData(format: ui.ImageByteFormat.png);
    });
    File('$out/$name.png').writeAsBytesSync(image!.buffer.asUint8List());
    final e = t.takeException();
    errors.writeln('$name: ${e == null ? 'ok' : '$e'.split('\n').first}');
  }

  Future<Workspace> pump(
    WidgetTester t, {
    Size size = const Size(411, 914),
    Future<void> Function(Workspace w)? seed,
  }) async {
    phoneWindow(t, size: size);
    final w = await workspace();
    await seed?.call(w);
    final settings = await AppSettings.load();
    final owner = w.api;
    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: buildApp(
          settings,
          auth: w.auth,
          backendFor: (_) => FakeAppsBackend(owner),
          appsApiFor: (_) => owner,
          studioPollInterval: null,
          appDetailServicesFor: (_) => {
            StatsApi: FakeStatsApi(apps: owner, mock: true),
            LogsApi: FakeLogsApi(apps: owner, mock: true),
            AccessApi: FakeAccessApi(owner),
            AnnotationsApi: FakeAnnotationsApi(owner),
            VersionsApi: FakeVersionsApi(owner),
          },
        ),
      ),
    );
    await settle(t);
    return w;
  }

  Future<AppDetailPageState> open(WidgetTester t, String name) async {
    await t.tap(find.text(name).first);
    await settle(t, 2500);
    return t.state<AppDetailPageState>(find.byType(AppDetailPage));
  }

  Future<bool> tapIf(WidgetTester t, Finder f) async {
    if (f.evaluate().isEmpty) return false;
    await t.ensureVisible(f.first);
    await t.pump();
    await t.tap(f.first, warnIfMissed: false);
    await settle(t, 1500);
    return true;
  }

  Future<void> scrollDown(WidgetTester t) async {
    await t.dragFrom(const Offset(200, 600), const Offset(0, -500));
    await settle(t, 800);
  }

  for (final size in phoneSizes) {
    final tag1 = '${size.width.toInt()}';
    testWidgets('public pages at $tag1', (t) async {
      phoneWindow(t, size: size);
      final api = FakeWorkflowRunApi()
        ..humanInputForms['tok'] = {
          'form_id': 'form-2',
          'form_token': 'tok',
          'node_title': 'Review',
          'rendered_content': r'Please review the draft reply before it is sent: {{#$output.review#}}',
          'inputs': [
            {'type': 'paragraph', 'output_variable_name': 'review'},
          ],
          'user_actions': [
            {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
            {'id': 'reject', 'title': 'Reject', 'button_style': 'default'},
          ],
          'default_values': <String, Object?>{},
          'display_in_ui': false,
          'expiration_time': 1893456000,
          'site': {
            'site': {'title': 'Approval app', 'icon_type': 'emoji', 'icon': 'robot_face'},
          },
        };
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            home: HumanInputFormPage(token: 'tok', server: Uri.parse('https://dify.example'), apiFor: (_) => api),
          ),
        ),
      );
      await settle(t);
      await shot(t, '$tag1-public-human-input');
      for (final mode in ['workflow', 'advanced-chat']) {
        final pub = HttpPublicAppApi(
          Uri.parse('https://fixture.invalid'),
          code: 'layout',
          client: MockClient((request) async {
            if (request.url.path == '/v1/passport') return http.Response('{"access_token":"visitor"}', 200);
            if (request.url.path == '/v1/site') {
              return http.Response(
                jsonEncode({
                  'title': 'Support triage',
                  'mode': mode,
                  'parameters': {
                    'user_input_form': [
                      {
                        'text-input': {'label': 'Question', 'variable': 'q', 'required': true, 'max_length': 48},
                      },
                    ],
                    'opening_statement': 'Ready to help',
                  },
                }),
                200,
              );
            }
            return http.Response('{}', 200);
          }),
        );
        await t.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              key: ValueKey(mode),
              home: PublicAppPage(
                code: 'layout',
                server: Uri.parse('https://fixture.invalid'),
                apiFor: (_, _, _) => pub,
              ),
            ),
          ),
        );
        await settle(t);
        await shot(t, '$tag1-public-app-$mode');
      }
      await unmount(t);
    });

    final tag0 = '${size.width.toInt()}';
    testWidgets('account pages at $tag0', (t) async {
      await pump(t, size: size);
      await tapIf(t, find.text(DifyI18n.tr('common', 'account.account')).last);
      await shot(t, '$tag0-account-tab');
      for (final label in [DifyI18n.tr('common', 'settings.members'), DifyI18n.tr('common', 'account.myAccount')]) {
        if (await tapIf(t, find.text(label).last)) {
          await shot(t, '$tag0-account-${label.replaceAll(' ', '-')}');
          await systemBack(t);
        }
      }
      await unmount(t);
    });

    final tag = '${size.width.toInt()}';
    testWidgets('workflow app pages at $tag', (t) async {
      await pump(
        t,
        size: size,
        seed: (w) async {
          final app = w.api.seed(name: 'Support triage');
          await FakeVersionsApi(w.api).publish(app.id);
        },
      );
      final shell = await open(t, 'Support triage');
      for (final page in [AppDetailPageId.overview, AppDetailPageId.logs, AppDetailPageId.accessPoint]) {
        shell.navigate(page);
        await settle(t, 1500);
        await shot(t, '$tag-workflow-${page.segment}');
        if (page == AppDetailPageId.logs) {
          await tapIf(
            t,
            find.byWidgetPredicate(
              (w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('workflow-log-row-'),
            ),
          );
          await shot(t, '$tag-workflow-logs-detail');
          await systemBack(t);
          await scrollDown(t);
          await shot(t, '$tag-workflow-logs-bottom');
        }
        if (page == AppDetailPageId.accessPoint) {
          await scrollDown(t);
          await shot(t, '$tag-workflow-access-point-2');
          await scrollDown(t);
          await shot(t, '$tag-workflow-access-point-3');
          for (final k in ['web-app-settings', 'web-app-embed', 'web-app-customize', 'api-secret-key-button']) {
            if (await tapIf(t, find.byKey(ValueKey(k)))) {
              await shot(t, '$tag-workflow-access-$k');
              await systemBack(t);
            }
          }
        }
        await systemBack(t);
      }
      await unmount(t);
    });

    testWidgets('chatflow app pages at $tag', (t) async {
      await pump(
        t,
        size: size,
        seed: (w) async {
          final app = w.api.seed(name: 'Help desk bot', mode: AppModes.advancedChat);
          final ann = FakeAnnotationsApi(w.api);
          for (var i = 0; i < 4; i++) {
            await ann.create(
              app.id,
              question: 'How do I reset my password ($i)?',
              answer: 'Open Settings, then Security.',
            );
          }
        },
      );
      final shell = await open(t, 'Help desk bot');
      for (final page in [
        AppDetailPageId.overview,
        AppDetailPageId.logs,
        AppDetailPageId.annotations,
        AppDetailPageId.accessPoint,
      ]) {
        shell.navigate(page);
        await settle(t, 1500);
        await shot(t, '$tag-chatflow-${page.segment}');
        if (page == AppDetailPageId.logs) {
          await tapIf(
            t,
            find.byWidgetPredicate(
              (w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('chat-log-row-'),
            ),
          );
          await shot(t, '$tag-chatflow-logs-detail');
          await systemBack(t);
        }
        if (page == AppDetailPageId.annotations) {
          await tapIf(
            t,
            find.byWidgetPredicate(
              (w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('annotation-row-'),
            ),
          );
          await shot(t, '$tag-chatflow-annotation-edit');
          await systemBack(t);
          if (await tapIf(t, find.byKey(const ValueKey('annotation-more')))) {
            await shot(t, '$tag-chatflow-annotation-more');
            await systemBack(t);
          }
        }
        await systemBack(t);
      }
      await unmount(t);
    });
  }
}
