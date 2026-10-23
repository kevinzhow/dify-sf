// dify-spec: packages/dify-ui/src/avatar/__tests__/index.spec.tsx
import 'control_harness.dart';

void main() {
  group('Avatar', () {
    group('Rendering', () {
      testWidgets('should render fallback with uppercase initial when avatar is null', (t) async {
        await renderControl(t, const DifyAvatar(name: 'alice'));
        expect(find.text('A'), findsOneWidget);
        expect(find.byType(Image), findsNothing);
      });
    });
  });
}
