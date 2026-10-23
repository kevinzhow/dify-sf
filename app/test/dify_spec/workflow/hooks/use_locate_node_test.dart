// dify-spec: web/app/components/workflow/hooks/__tests__/use-locate-node.spec.tsx
//
// useLocateNode is NodeLocator (fed the document's nodes on every change by LocateNodeOnOpen); the URL's `node_id`
// comes from the launch options.
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/launch_options.dart';
import 'package:dify_sf_app/src/workflow_editor/hooks/use_locate_node.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dify's mocked `t`: the key, then `:` and the node id or title.
class _T implements Translator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) => params['nodeId'] != null
      ? '$key:${params['nodeId']}'
      : (params['title'] != null ? '$key:${params['title']}' : key);
}

class _Recorder {
  final selected = <String>[], scrolled = <String>[], success = <String>[], errors = <String>[];

  NodeLocator locator(String? nodeId) => NodeLocator(
    nodeIdFromUrl: nodeId,
    select: selected.add,
    scrollTo: scrolled.add,
    toast: (type, message) => (type == DifyToastType.success ? success : errors).add(message),
  );
}

({String id, String title}) _node(String id, [String title = 'Writer']) => (id: id, title: title);

void main() {
  setUp(() => DifyI18n.current = _T());

  group('useLocateNode', () {
    testWidgets('does nothing when node_id param is absent', (t) async {
      final r = _Recorder();
      expect(LaunchOptions.fromQuery(const {}).nodeId, isNull);
      r.locator(null).update([_node('n1')]);
      await t.pump(const Duration(seconds: 1));
      expect(r.selected, isEmpty);
      expect(r.success, isEmpty);
      expect(r.errors, isEmpty);
    });

    testWidgets('does nothing when nodes are empty', (t) async {
      final r = _Recorder();
      r.locator(LaunchOptions.fromQuery(const {'node_id': 'n1'}).nodeId).update(const []);
      await t.pump(const Duration(seconds: 1));
      expect(r.selected, isEmpty);
      expect(r.errors, isEmpty);
    });

    testWidgets('selects, scrolls to, and shows success toast when node is found', (t) async {
      final r = _Recorder();
      r.locator('target-node').update([_node('target-node', 'My Node')]);
      expect(r.selected, ['target-node']);
      expect(r.success, ['panel.locateNodeSuccess:My Node']);
      // Scroll happens after a 200ms delay.
      expect(r.scrolled, isEmpty);
      await t.pump(const Duration(milliseconds: 200));
      expect(r.scrolled, ['target-node']);
    });

    testWidgets('shows error toast after debounce when node is not found', (t) async {
      final r = _Recorder();
      r.locator('missing-node').update([_node('other-node')]);
      expect(r.errors, isEmpty);
      await t.pump(const Duration(milliseconds: 500));
      expect(r.errors, ['panel.locateNodeNotFound:missing-node']);
    });

    testWidgets('does not report not-found prematurely when nodes are still loading', (t) async {
      final r = _Recorder();
      final locator = r.locator('target-node')..update([_node('other-node')]);
      await t.pump(const Duration(milliseconds: 300));
      locator.update([_node('other-node'), _node('target-node', 'Found!')]);
      await t.pump(const Duration(seconds: 1));
      expect(r.errors, isEmpty);
      expect(r.selected, ['target-node']);
      expect(r.success, ['panel.locateNodeSuccess:Found!']);
    });

    testWidgets('locates only once even if nodes update afterwards', (t) async {
      final r = _Recorder();
      final locator = r.locator('target-node')..update([_node('target-node')]);
      expect(r.selected, hasLength(1));
      locator.update([_node('target-node'), _node('extra')]);
      expect(r.selected, hasLength(1));
      expect(r.success, hasLength(1));
      await t.pump(const Duration(milliseconds: 200));
    });

    testWidgets('clears scroll timeout on unmount', (t) async {
      final r = _Recorder();
      r.locator('target-node')
        ..update([_node('target-node')])
        ..dispose();
      await t.pump(const Duration(milliseconds: 500));
      expect(r.scrolled, isEmpty);
    });
  });
}
