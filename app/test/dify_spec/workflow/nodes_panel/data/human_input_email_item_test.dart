// dify-spec: web/app/components/workflow/nodes/human-input/components/delivery-method/recipient/__tests__/email-item.spec.tsx
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/email_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';


void main() {
  group('human-input/delivery-method/recipient/email-item', () {
    testWidgets('should render the current user label and delete the recipient when enabled', (t) async {
      var deletes = 0;
      await pumpComponent(
        t,
        Align(
          alignment: Alignment.topLeft,
          child: EmailItem(
            email: 'owner@example.com',
            address: 'owner@example.com',
            name: 'Owner',
            avatarUrl: 'avatar.png',
            onDelete: () => deletes++,
          ),
        ),
      );

      expect(find.textContaining('Owner'), findsOneWidget);
      expect(find.textContaining('common.members.you'), findsOneWidget);
      await tapNamed(t, 'common.operation.remove');
      expect(deletes, 1);
    });

    testWidgets('should show an error style and hide delete when disabled', (t) async {
      await pumpComponent(
        t,
        Align(
          alignment: Alignment.topLeft,
          child: EmailItem(
            email: 'owner@example.com',
            address: 'missing@example.com',
            name: 'Missing',
            disabled: true,
            isError: true,
            onDelete: () {},
          ),
        ),
      );

      expect(
        find.byWidgetPredicate(
          (w) =>
              w is DifyTooltip &&
              w.content is DifyTextLine &&
              (w.content as DifyTextLine).data == 'missing@example.com',
        ),
        findsOneWidget,
      );
      expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'error-warning-fill'), findsOneWidget);
      expect(named('common.operation.remove'), findsNothing);
    });
  });
}
