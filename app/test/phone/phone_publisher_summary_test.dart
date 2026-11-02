// Polish after batch 4: the publisher's version line on phones. "Name it" and the edit pencil are touch targets
// (44 dp nodes for touch and accessibility), and a version the server dated a little ahead of the device reads as just
// published, at every width (items 1 and 6).
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/header/format.dart';
import 'package:dify_sf_app/src/workflow_editor/header/publisher/summary_section.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

String _w(String key) => DifyI18n.tr('workflow', key);

/// The summary of a workflow app whose version [name]d (or not) was published [ahead] of the device's clock.
Widget _summary({String name = '', Duration ahead = const Duration(seconds: 20)}) => PublisherSummarySection(
  isWorkflowApp: true,
  isChatApp: false,
  published: false,
  publishedAt: DateTime.now().add(ahead).millisecondsSinceEpoch,
  formatTimeFromNow: formatTimeFromNow,
  onPublish: () {},
  onRestore: () {},
  onEditVersion: () {},
  versionInfo: PublishedWorkflowInfo(
    id: 'v1',
    createdAt: DateTime.now().add(ahead).millisecondsSinceEpoch ~/ 1000,
    createdByName: 'Alice',
    versionNumber: 1,
    markedName: name,
  ),
);

Future<void> _pump(WidgetTester t, Widget child, {Size size = const Size(411, 914)}) async {
  phoneWindow(t, size: size);
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      home: DifyPage(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: size.width < 600 ? size.width : 360, child: child),
        ),
      ),
    ),
  );
  await settle(t, 300);
}

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });

  for (final size in phoneSizes) {
    final name = '${size.width.toInt()}x${size.height.toInt()}';
    testWidgets('$name: "Name it" and the edit pencil are 44 dp targets for touch and accessibility', (t) async {
      final semantics = t.ensureSemantics();
      await _pump(t, _summary(), size: size);
      final nameIt = t.getSemantics(find.bySemanticsLabel(_w('versionHistory.nameIt')));
      expect(nameIt.rect.width, greaterThanOrEqualTo(44), reason: '${nameIt.rect}');
      expect(nameIt.rect.height, greaterThanOrEqualTo(44), reason: '${nameIt.rect}');
      await _pump(t, _summary(name: 'v1 slow count'), size: size);
      final pencil = t.getSemantics(find.bySemanticsLabel(_w('versionHistory.editVersionInfo')));
      expect(pencil.rect.width, greaterThanOrEqualTo(44), reason: '${pencil.rect}');
      expect(pencil.rect.height, greaterThanOrEqualTo(44), reason: '${pencil.rect}');
      expect(t.takeException(), isNull);
      semantics.dispose();
    });
  }

  for (final size in const [Size(411, 914), Size(1280, 800)]) {
    testWidgets('${size.width.toInt()} dp: a version published 20 s "ahead" (the server\'s clock) reads as just '
        'published, not "in a few seconds"', (t) async {
      await _pump(t, _summary(), size: size);
      expect(find.textContaining('a few seconds ago'), findsOneWidget);
      expect(find.textContaining('in a few seconds'), findsNothing);
      expect(t.takeException(), isNull);
    });
  }
}
