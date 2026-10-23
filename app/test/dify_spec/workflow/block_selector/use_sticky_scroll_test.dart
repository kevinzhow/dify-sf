// dify-spec: web/app/components/workflow/block-selector/__tests__/use-sticky-scroll.spec.ts
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpBlockSelectorTests();

  group('useStickyScroll', () {
    testWidgets('should keep the default state when refs are missing', (t) async {
      // Without marketplace results to follow, the scroll area keeps the bar in the list (no sticky copy).
      await pumpSelector(
        t,
        const SizedBox(width: 400, height: 300, child: MarketplaceScrollArea(children: [Text('x')])),
      );
      expect(find.byType(MarketplaceStickyBar), findsNothing);
    });

    test('should mark the sticky element as below the wrapper when it is outside the visible area', () {
      expect(stickyScrollPosition(wrapTop: 100, wrapHeight: 200, nextTop: 320), StickyScrollPosition.belowTheWrap);
    });

    test('should mark the sticky element as showing when it is within the wrapper', () {
      expect(stickyScrollPosition(wrapTop: 100, wrapHeight: 200, nextTop: 220), StickyScrollPosition.showing);
    });

    test('should mark the sticky element as above the wrapper when it has scrolled past the top', () {
      expect(stickyScrollPosition(wrapTop: 100, wrapHeight: 200, nextTop: 90), StickyScrollPosition.aboveTheWrap);
    });
  });
}
