// The online-users tooltip is h-7/max-w-55, not a viewport-height panel.
import 'package:dify_sf_app/src/design/widgets/surface.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/header/online_users.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => DifyI18n.load('zh-Hans', namespaces: const ['common', 'workflow']));
  for (final name in ['kevinzhow', List.filled(40, '很长的用户名称').join()]) {
    testWidgets('online-user hover keeps a 28px tooltip and truncates $name', (t) async {
      final users = ValueNotifier([OnlineUser(sid: 'session', userId: 'me', username: name)]);
      addTearDown(users.dispose);
      await renderWorkflowComponent(
        t,
        const OnlineUsers(),
        data: WorkflowHeaderData(onlineUsers: users, currentUserId: 'me'),
        testTranslator: false,
      );
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(t.getCenter(find.byType(UserAvatar)));
      await t.pump(const Duration(milliseconds: 300));
      await t.pump(const Duration(milliseconds: 150));
      expect(find.text(name), findsOneWidget);
      final bubble = find.ancestor(of: find.text(name), matching: find.byType(DifyBlurredBox)).first;
      final bounds = t.getRect(bubble);
      expect(bounds.height, 28);
      expect(bounds.width, lessThanOrEqualTo(220));
      expect(bounds.top, closeTo(t.getRect(find.byType(UserAvatar)).bottom + 4, .01));
      expect(t.takeException(), isNull);
      await mouse.removePointer();
      await t.pumpWidget(const SizedBox.shrink());
    });
  }
}
