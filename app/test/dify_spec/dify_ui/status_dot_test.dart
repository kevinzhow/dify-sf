// dify-spec: packages/dify-ui/src/status-dot/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Whether [w]'s subtree is hidden from assistive technology (`aria-hidden="true"`).
bool hidden(WidgetTester t, Finder w) => t
    .widgetList<ExcludeSemantics>(find.descendant(of: w, matching: find.byType(ExcludeSemantics)))
    .any((e) => e.excluding);

void main() {
  group('StatusDot', () {
    testWidgets('hides the visual indicator and its loading placeholder from assistive technology', (t) async {
      final semantics = t.ensureSemantics();
      await render(t, const Row(children: [DifyStatusDot(), DifyStatusDotSkeleton()]));
      expect(hidden(t, find.byType(DifyStatusDot)), isTrue);
      expect(hidden(t, find.byType(DifyStatusDotSkeleton)), isTrue);
      // Default: success, medium (`size-2 rounded-[3px] border`, the green indicator shadow).
      final box = t.widget<Container>(
        find.descendant(of: find.byType(DifyStatusDot), matching: find.byType(Container)),
      );
      final d = box.decoration! as BoxDecoration;
      expect(d.color, DifyColors.componentsBadgeStatusLightSuccessBg);
      expect(d.boxShadow, DifyShadows.statusIndicatorGreenShadow);
      expect(t.getSize(find.byType(DifyStatusDot)), const Size(8, 8));
      semantics.dispose();
    });

    testWidgets('does not allow consumers to override the decorative contract', (t) async {
      final semantics = t.ensureSemantics();
      // The widgets take no semantics of their own: a label belongs to the surrounding component, and the dot adds
      // nothing below it.
      await render(
        t,
        Row(
          children: [
            const DifyStatusDot(),
            Semantics(
              container: true,
              label: 'Active',
              child: const DifyStatusDot(status: DifyStatusDotStatus.error, size: DifyStatusDotSize.small),
            ),
            const DifyStatusDotSkeleton(),
          ],
        ),
      );
      for (final w in t.widgetList(find.byWidgetPredicate((w) => w is DifyStatusDot || w is DifyStatusDotSkeleton))) {
        expect(hidden(t, find.byWidget(w)), isTrue);
      }
      final active = find.semantics.byLabel('Active').evaluate().single;
      var children = 0;
      active.visitChildren((_) {
        children++;
        return true;
      });
      expect(children, 0);
      expect(
        t.getSize(find.byWidgetPredicate((w) => w is DifyStatusDot && w.size == DifyStatusDotSize.small)),
        const Size(6, 6),
      );
      semantics.dispose();
    });
  });
}
