// dify-spec: web/app/components/workflow/block-selector/trigger-plugin/__tests__/trigger-plugin.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/start_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Map<String, Object?> _event(String name, String label) => {
  'name': name,
  'author': 'Dify',
  'label': {'en_US': label, 'zh_Hans': label},
  'description': {'en_US': '$label description', 'zh_Hans': '$label description'},
  'parameters': [
    {
      'name': 'token',
      'label': {'en_US': 'Token'},
      'type': 'string',
      'form': 'form',
      'required': true,
      'default': '',
    },
  ],
  'labels': <Object?>[],
  'output_schema': {'type': 'object'},
};

ToolProvider _provider({
  String id = 'trigger-provider-1',
  String name = 'trigger-provider',
  String label = 'Trigger Provider',
  String type = 'builtin',
  List<Map<String, Object?>>? events,
}) => ToolProvider.fromJson({
  'id': id,
  'name': name,
  'author': 'Trigger Author',
  'icon': '/trigger.svg',
  'icon_dark': '/trigger-dark.svg',
  'label': {'en_US': label, 'zh_Hans': label},
  'type': type,
  'is_team_authorization': false,
  'plugin_id': 'trigger-plugin-1',
  'plugin_unique_identifier': 'trigger-plugin-1@1.0.0',
  'events': events ?? [_event('on_message', 'On Message')],
  'meta': {'version': '1.0.0'},
});

Widget _w(Widget child) => SizedBox(width: 400, child: child);

void main() {
  setUpBlockSelectorTests();

  group('trigger plugin selector components', () {
    testWidgets('should select trigger plugin action items with default params and preview details', (t) async {
      final semantics = t.ensureSemantics();
      final rec = SelectRecorder();
      final event = ToolAction.fromJson(_event('on_created', 'On Created'));
      await pumpSelector(t, _w(TriggerPluginActionItem(provider: _provider(), event: event, onSelect: rec.call)));
      expect(t.getSemantics(find.bySemanticsLabel('On Created')).getSemanticsData().hint, 'On Created description');

      await tapText(t, 'On Created');
      final (type, value) = rec.calls.single;
      expect(type, 'trigger-plugin');
      expect(value, containsPair('plugin_id', 'trigger-plugin-1'));
      expect(value, containsPair('provider_id', 'trigger-provider'));
      expect(value, containsPair('event_name', 'on_created'));
      expect(value, containsPair('event_label', 'On Created'));
      expect(value!['params'], {'token': ''});
      semantics.dispose();
    });

    testWidgets('should select trigger plugin action items from the keyboard', (t) async {
      final rec = SelectRecorder();
      final event = ToolAction.fromJson(_event('on_created', 'On Created'));
      await pumpSelector(t, _w(TriggerPluginActionItem(provider: _provider(), event: event, onSelect: rec.call)));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(hasFocusOn(t, find.text('On Created')), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(rec.calls.single.$2, containsPair('event_name', 'on_created'));
      expect(rec.calls.single.$2, containsPair('event_label', 'On Created'));
    });

    testWidgets('should expand providers and select workflow trigger providers directly', (t) async {
      final rec = SelectRecorder();
      late StateSetter set;
      var provider = _provider(events: [_event('first', 'First Event'), _event('second', 'Second Event')]);
      await pumpSelector(
        t,
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return _w(TriggerPluginItem(key: ValueKey(provider.type), provider: provider, onSelect: rec.call));
          },
        ),
      );
      await tapText(t, 'Trigger Provider');
      await tapText(t, 'Second Event');
      expect(rec.calls.single.$2, containsPair('event_name', 'second'));
      expect(rec.calls.single.$2, containsPair('title', 'Second Event'));

      rec.calls.clear();
      set(() => provider = _provider(type: 'workflow', events: [_event('workflow_event', 'Workflow Event')]));
      await t.pump();
      await tapText(t, 'Workflow Event');
      expect(rec.calls.single.$2, containsPair('provider_type', 'workflow'));
      expect(rec.calls.single.$2, containsPair('event_name', 'workflow_event'));
    });

    testWidgets('should expand trigger providers from the keyboard', (t) async {
      await pumpSelector(
        t,
        _w(
          TriggerPluginItem(
            provider: _provider(events: [_event('first', 'First Event'), _event('second', 'Second Event')]),
            onSelect: (_, [_]) {},
          ),
        ),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(hasFocusOn(t, find.text('Trigger Provider')), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.space);
      await t.pump();
      expect(
        find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'workflow.tabs.allTriggers'),
        findsOneWidget,
      );
      expect(find.text('Second Event'), findsOneWidget);
    });

    testWidgets('should filter trigger plugins and report whether content exists', (t) async {
      final plugins = [
        _provider(),
        _provider(id: 'empty-provider', name: 'empty-provider', label: 'Empty Provider', events: []),
      ];
      final matched = filterTriggerPlugins(plugins, 'message');
      await pumpSelector(t, _w(TriggerPluginList(plugins: matched, onSelect: (_, [_]) {})));
      expect(find.text('Trigger Provider'), findsOneWidget);
      expect(find.text('Empty Provider'), findsNothing);

      expect(filterTriggerPlugins(plugins, 'missing'), isEmpty);
      await pumpSelector(
        t,
        _w(TriggerPluginList(plugins: filterTriggerPlugins(plugins, 'missing'), onSelect: (_, [_]) {})),
      );
      expect(find.text('Trigger Provider'), findsNothing);
    });
  });
}
