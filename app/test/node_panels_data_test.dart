// The data group's panel bodies (http-request, tool, document-extractor, list-operator, iteration, loop, loop-end,
// human-input) as registered: each renders from Dify's default data without errors.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/data_bodies.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/workflow/nodes_panel/data/harness.dart';

/// Each node type's `defaultValue` (default.ts).
const _defaults = <String, Map<String, Object?>>{
  'http-request': {
    'variables': <Object?>[],
    'method': 'get',
    'url': '',
    'authorization': {'type': 'no-auth', 'config': null},
    'headers': '',
    'params': '',
    'body': {'type': 'none', 'data': <Object?>[]},
    'ssl_verify': true,
    'timeout': {'max_connect_timeout': 0, 'max_read_timeout': 0, 'max_write_timeout': 0},
    'retry_config': {'retry_enabled': true, 'max_retries': 3, 'retry_interval': 100},
  },
  'tool': {
    'tool_parameters': <String, Object?>{},
    'tool_configurations': <String, Object?>{},
    'tool_node_version': '2',
  },
  'document-extractor': {'variable_selector': <Object?>[], 'is_array_file': false},
  'list-operator': {
    'variable': <Object?>[],
    'filter_by': {'enabled': false, 'conditions': <Object?>[]},
    'extract_by': {'enabled': false, 'serial': '1'},
    'order_by': {'enabled': false, 'key': '', 'value': 'asc'},
    'limit': {'enabled': false, 'size': 10},
  },
  'iteration': {
    'start_node_id': '',
    'iterator_selector': <Object?>[],
    'output_selector': <Object?>[],
    'is_parallel': false,
    'parallel_nums': 10,
    'error_handle_mode': 'terminated',
    'flatten_output': true,
  },
  'loop': {'start_node_id': '', 'break_conditions': <Object?>[], 'loop_count': 10, 'logical_operator': 'and'},
  'loop-end': <String, Object?>{},
  'human-input': {
    'delivery_methods': <Object?>[],
    'user_actions': <Object?>[],
    'form_content': '',
    'inputs': <Object?>[],
    'timeout': 3,
    'timeout_unit': 'day',
  },
};

void main() {
  test('registers every data node type', () {
    expect(dataPanelBodies.keys.toSet(), _defaults.keys.toSet());
  });

  for (final MapEntry(key: type, value: data) in _defaults.entries) {
    testWidgets('renders the $type panel from its default data', (t) async {
      final h = await Harness.start(t, [
        difyNode('n', {'type': type, ...data}),
      ]);
      await renderBody(t, h, 'n', dataPanelBodies[type]!);
      expect(t.takeException(), isNull);
      await h.dispose(t);
    });
  }
}
