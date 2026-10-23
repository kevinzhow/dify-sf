import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/copy_id.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/workflow/hooks/editor_harness.dart';

void main() {
  testWidgets('the MCP card mounts a real CopyId control; clicks copy without dragging/selecting', (t) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    final h = await EditorHarness.start(t, [
      node(
        'mcp',
        type: 'tool',
        x: 100,
        y: 100,
        config: {'provider_type': const VString('mcp'), 'provider_id': const VString('tool-123')},
      ),
      node('ordinary', type: 'tool', x: 500, y: 100),
    ]);
    expect(find.byType(CopyId), findsOneWidget);
    expect(find.text('tool-123'), findsOneWidget);
    final rect = t.getRect(find.byType(CopyId));
    expect(h.canvas.graph!['mcp']!.rect.contains(rect.center), isTrue);
    await t.tap(find.byType(CopyId));
    await t.pump(const Duration(milliseconds: 150));
    expect(copied, 'tool-123');
    expect(h.controller.selectedNodeId, isNull);
    expect(h.controller.undo.past, isEmpty);
    // Same shared layer is used over Scene textures; the capture reserves its space, so it is drawn once.
    h.canvas.view.zoomAt(rect.center, 0.5);
    await t.pump();
    await t.tap(find.byType(CopyId));
    await t.pump(const Duration(milliseconds: 150));
    expect(copied, 'tool-123');
    await h.dispose(t);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
}
