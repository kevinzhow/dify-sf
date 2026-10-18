// dify-spec: web/app/signin/__tests__/_locale-menu.spec.tsx
import 'package:dify_sf_app/src/auth/widgets/auth_widgets.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/auth_fakes.dart';
import 'harness.dart';

const _items = [
  (value: 'en-US', name: 'English (US)'),
  (value: 'zh-Hans', name: '简体中文'),
  (value: 'ja-JP', name: '日本語'),
];

void main() {
  group('LocaleMenu', () {
    group('Rendering', () {
      testWidgets('should render selected locale name when value matches an item', (t) async {
        await renderAuth(
          t,
          await authOn(RecordingAuthApi()),
          LocaleMenu(items: _items, value: 'en-US', onChange: (_) {}),
        );
        expect(
          find.semantics.byPredicate(
            (n) => n.getSemanticsData().flagsCollection.isButton && n.label == 'English (US)',
          ),
          findsOne,
        );
      });
    });

    group('User Interactions', () {
      testWidgets('should call onChange with selected locale value when clicking an option', (t) async {
        String? chosen;
        await renderAuth(
          t,
          await authOn(RecordingAuthApi()),
          Align(
            alignment: Alignment.topRight,
            child: LocaleMenu(items: _items, value: 'en-US', onChange: (v) => chosen = v),
          ),
        );
        await t.tap(find.byKey(const ValueKey('locale-menu')));
        await settleAuth(t, 3);
        expect(
          find.semantics.byPredicate(
            (n) => n.getSemanticsData().role == SemanticsRole.menuItemRadio && n.label == '日本語',
          ),
          findsOne,
        );
        await t.tap(find.text('日本語'));
        await settleAuth(t, 3);
        expect(chosen, 'ja-JP');
      });
    });
  });
}
