// dify-spec: packages/dify-ui/src/icon-button/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _icon = SizedBox.square(dimension: 16);

void main() {
  group('IconButton', () {
    testWidgets('renders a named native button by default', (t) async {
      final semantics = t.ensureSemantics();
      await render(t, DifyIconButton(label: 'Close', icon: _icon, onPressed: () {}));
      expect(
        t.getSemantics(find.byType(DifyIconButton)),
        isSemantics(label: 'Close', isButton: true, hasEnabledState: true, isEnabled: true, hasTapAction: true),
      );
      semantics.dispose();
    });

    testWidgets('preserves Base UI disabled behavior', (t) async {
      final semantics = t.ensureSemantics();
      var clicks = 0;
      await render(t, DifyIconButton(label: 'Delete', icon: _icon, disabled: true, onPressed: () => clicks++));
      expect(
        t.getSemantics(find.byType(DifyIconButton)),
        isSemantics(
          label: 'Delete',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
          hasTapAction: false,
        ),
      );
      await t.tap(find.byType(DifyIconButton), warnIfMissed: false);
      expect(clicks, 0);
      semantics.dispose();
    });
  });
}
