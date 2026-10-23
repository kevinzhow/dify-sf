import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

class _ExportBackend extends DemoBackend {
  _ExportBackend({this.fail = false}) : super(withBo: false);
  final bool fail;
  @override
  bool get supportsDifyDsl => true;
  @override
  Future<String> exportDifyDsl(String docId, {bool includeSecret = false}) async {
    if (fail) throw StateError('offline');
    return 'kind: app';
  }
}

void main() {
  for (final fail in [false, true]) {
    testWidgets(
      fail ? 'export failure uses the Dify error toast' : 'copying exported DSL uses the Dify success toast',
      (t) async {
        await useAppFonts();
        t.view.physicalSize = const Size(1600, 900);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final backend = _ExportBackend(fail: fail);
        final clipboard = <MethodCall>[];
        t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          clipboard.add(call);
          return null;
        });
        addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
        await t.pumpWidget(
          MaterialApp(
            home: Stack(
              children: [
                EditorPage(backend: backend, docId: 'demo', clientId: 'me-abc123', journaled: false),
                const DifyToastHost(),
              ],
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        await t.tap(find.byKey(const Key('session-menu')));
        await t.pump(const Duration(milliseconds: 300));
        await t.tap(find.byKey(const Key('export-dsl')));
        await t.pump(const Duration(milliseconds: 300));
        if (!fail) {
          expect(find.byKey(const Key('export-dsl-text')), findsOneWidget);
          await t.tap(find.byKey(const Key('export-dsl-copy')));
          await t.pump();
          expect(clipboard.where((c) => c.method == 'Clipboard.setData').single.arguments, {'text': 'kind: app'});
        }
        await t.pump(const Duration(milliseconds: 600));
        expect(find.text(fail ? 'Export failed: Bad state: offline' : 'Copied the workflow file'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) => w is RemixIcon && w.name == (fail ? 'error-warning-fill' : 'checkbox-circle-fill'),
          ),
          findsOneWidget,
        );
        expect(find.byType(SnackBar), findsNothing);
        await t.pumpWidget(const SizedBox());
        await backend.dispose();
        await t.pump(const Duration(seconds: 20));
      },
    );
  }
}
