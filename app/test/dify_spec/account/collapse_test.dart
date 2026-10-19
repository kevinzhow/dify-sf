// dify-spec: web/app/components/header/account-setting/collapse/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/widgets/collapse.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../members/harness.dart' show tapButton;

void main() {
  group('Collapse', () {
    testWidgets('toggles its items and reports the selected item', (t) async {
      final selected = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Material(
            child: DifyCollapse<String>(
              title: 'Test Title',
              items: const ['Item 1', 'Item 2'],
              itemBuilder: (context, item) => Text(item),
              onSelect: selected.add,
            ),
          ),
        ),
      );
      expect(find.text('Item 1'), findsNothing);

      await tapButton(t, 'Test Title');
      await t.tap(find.text('Item 1'));
      expect(selected, ['Item 1']);

      await tapButton(t, 'Test Title');
      expect(find.text('Item 1'), findsNothing);
    });
  });
}
