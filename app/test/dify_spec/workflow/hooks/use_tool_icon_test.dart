// dify-spec: web/app/components/workflow/hooks/__tests__/use-tool-icon.spec.ts
//
// useToolIcon is toolIconOf and useGetToolIcon getToolIcon (hooks/use_tool_icon.dart); the queried collections,
// trigger plugins and data sources are passed in (Dify's service mocks).
import 'package:dify_sf_app/src/workflow_editor/hooks/use_tool_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter_test/flutter_test.dart';

const ToolIconCollections _collections = (
  buildInTools: [
    {'id': 'builtin-1', 'name': 'builtin', 'icon': '/builtin.svg', 'icon_dark': '/builtin-dark.svg', 'plugin_id': 'p1'},
  ],
  customTools: [
    {'id': 'custom-1', 'name': 'custom', 'icon': '/custom.svg', 'plugin_id': 'p2'},
  ],
  workflowTools: [
    {'id': 'workflow-1', 'name': 'workflow-tool', 'icon': '/workflow.svg', 'plugin_id': 'p3'},
  ],
  mcpTools: [
    {'id': 'mcp-1', 'name': 'mcp-tool', 'icon': '/mcp.svg', 'plugin_id': 'p4'},
  ],
);

const _triggerPlugins = [
  {'id': 'trigger-1', 'icon': '/trigger.svg', 'icon_dark': '/trigger-dark.svg'},
];

Object _icon(Map<String, Object?>? data, {String theme = 'light', List<Map<String, Object?>>? dataSourceList}) =>
    toolIconOf(
      data,
      collections: _collections,
      triggerPlugins: _triggerPlugins,
      dataSourceList: dataSourceList,
      theme: theme,
    );

const _base = {'title': '', 'desc': ''};

void main() {
  group('useToolIcon', () {
    test('should return empty string when no data', () {
      expect(_icon(null), '');
    });

    test('should find icon for TriggerPlugin node', () {
      expect(
        _icon({
          ..._base,
          'type': 'trigger-plugin',
          'plugin_id': 'trigger-1',
          'provider_id': 'trigger-1',
          'provider_name': 'trigger-1',
        }),
        '/trigger.svg',
      );
    });

    test('should find icon for Tool node (builtIn)', () {
      expect(
        _icon({
          ..._base,
          'type': 'tool',
          'provider_type': 'builtin',
          'provider_id': 'builtin-1',
          'plugin_id': 'p1',
          'provider_name': 'builtin',
        }),
        '/builtin.svg',
      );
    });

    test('should find icon for Tool node (custom)', () {
      expect(
        _icon({
          ..._base,
          'type': 'tool',
          'provider_type': 'api',
          'provider_id': 'custom-1',
          'plugin_id': 'p2',
          'provider_name': 'custom',
        }),
        '/custom.svg',
      );
    });

    test('should use dark trigger and provider icons when available', () {
      expect(
        _icon({
          ..._base,
          'type': 'trigger-plugin',
          'plugin_id': 'trigger-1',
          'provider_id': 'trigger-1',
          'provider_name': 'trigger-1',
        }, theme: 'dark'),
        '/trigger-dark.svg',
      );
      expect(
        _icon({
          ..._base,
          'type': 'tool',
          'provider_type': 'builtin',
          'provider_id': 'missing-provider',
          'provider_name': 'missing',
          'provider_icon': '/fallback.svg',
          'provider_icon_dark': '/fallback-dark.svg',
        }, theme: 'dark'),
        '/fallback-dark.svg',
      );
    });

    test('should resolve workflow, mcp and datasource icons', () {
      expect(
        _icon({
          ..._base,
          'type': 'tool',
          'provider_type': 'workflow',
          'provider_id': 'workflow-1',
          'provider_name': 'workflow-tool',
        }),
        '/workflow.svg',
      );
      expect(
        _icon({..._base, 'type': 'tool', 'provider_type': 'mcp', 'provider_id': 'mcp-1', 'provider_name': 'mcp-tool'}),
        '/mcp.svg',
      );
      expect(
        _icon(
          {..._base, 'type': 'datasource', 'plugin_id': 'datasource-1'},
          dataSourceList: [
            {'id': 'ds-1', 'plugin_id': 'datasource-1', 'icon': '/datasource.svg'},
          ],
        ),
        '/datasource.svg',
      );
    });

    test('should fallback to provider_icon when no collection match', () {
      expect(
        _icon({
          ..._base,
          'type': 'tool',
          'provider_type': 'builtin',
          'provider_id': 'unknown-provider',
          'plugin_id': 'unknown-plugin',
          'provider_name': 'unknown',
          'provider_icon': '/fallback.svg',
        }),
        '/fallback.svg',
      );
    });

    test('should return empty string for unmatched DataSource node', () {
      expect(_icon({..._base, 'type': 'datasource', 'plugin_id': 'unknown-ds'}), '');
    });

    test('should return empty string for unrecognized node type', () {
      expect(_icon({..._base, 'type': 'llm'}), '');
    });
  });

  group('useGetToolIcon', () {
    late WorkflowStore store;
    setUp(() => store = WorkflowStore());
    tearDown(() => store.dispose());

    Object? Function(Map<String, Object?>) hook({List<Map<String, Object?>>? dataSourceList}) =>
        getToolIcon(store, collections: _collections, triggerPlugins: _triggerPlugins, dataSourceList: dataSourceList);

    test('should find icon for TriggerPlugin node via returned function', () {
      expect(
        hook()({
          ..._base,
          'type': 'trigger-plugin',
          'plugin_id': 'trigger-1',
          'provider_id': 'trigger-1',
          'provider_name': 'trigger-1',
        }),
        '/trigger.svg',
      );
    });

    test('should find icon for Tool node via returned function', () {
      expect(
        hook()({
          ..._base,
          'type': 'tool',
          'provider_type': 'builtin',
          'provider_id': 'builtin-1',
          'plugin_id': 'p1',
          'provider_name': 'builtin',
        }),
        '/builtin.svg',
      );
    });

    test('should prefer workflow store collections over query collections', () {
      store.buildInTools.value = [
        {'id': 'override-1', 'name': 'override', 'icon': '/override.svg', 'plugin_id': 'p1'},
      ];
      final get = hook(
        dataSourceList: [
          {'id': 'ds-1', 'plugin_id': 'datasource-1', 'icon': '/datasource-store.svg'},
        ],
      );
      expect(
        get({
          ..._base,
          'type': 'tool',
          'provider_type': 'builtin',
          'provider_id': 'override-1',
          'provider_name': 'override',
        }),
        '/override.svg',
      );
      expect(get({..._base, 'type': 'datasource', 'plugin_id': 'datasource-1'}), '/datasource-store.svg');
      expect(store.buildInTools.value, hasLength(1));
    });

    test('should return undefined for unmatched node type', () {
      expect(hook()({..._base, 'type': 'llm'}), isNull);
    });
  });
}
