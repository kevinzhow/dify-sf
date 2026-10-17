// dify-spec: web/app/components/base/prompt-editor/plugins/component-picker-block/__tests__/hooks.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/component_picker.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Records what the options ask the editor to do (Dify's spies on dispatchCommand / update).
class _Recorder {
  final calls = <Object>[];
  late final actions = PickerActions(
    insertBlock: calls.add,
    insertText: calls.add,
    insertBraces: () => calls.add('{{}}'),
  );
}

ContextBlockConfig _context({bool show = true, bool selectable = true}) =>
    ContextBlockConfig(show: show, selectable: selectable);
PromptBlockConfig _block({bool show = true, bool selectable = true}) =>
    PromptBlockConfig(show: show, selectable: selectable);
HistoryBlockConfig _history({bool show = true, bool selectable = true}) =>
    HistoryBlockConfig(show: show, selectable: selectable);
VariableBlockConfig _variables(List<PromptOption> vars, {bool show = true}) =>
    VariableBlockConfig(show: show, variables: vars);
ExternalToolBlockConfig _tools(List<ExternalToolOption> tools, {bool show = true, void Function()? onAdd}) =>
    ExternalToolBlockConfig(show: show, externalTools: tools, onAddExternalTool: onAdd);
WorkflowVariableBlockConfig _workflow(List<VarGroup> vars, {bool show = true}) =>
    WorkflowVariableBlockConfig(show: show, variables: vars);

void main() {
  setUp(useDifyTestTranslator);

  group('usePromptOptions', () {
    final r = _Recorder();
    setUp(r.calls.clear);

    group('when no blocks are provided', () {
      test('should return an empty array', () {
        expect(promptOptions(actions: r.actions), isEmpty);
      });
    });

    group('contextBlock', () {
      test('should NOT include context option when show is false', () {
        expect(promptOptions(actions: r.actions, contextBlock: _context(show: false)), isEmpty);
      });

      test('should include context option when show is true', () {
        final o = promptOptions(actions: r.actions, contextBlock: _context());
        expect(o, hasLength(1));
        expect(o[0].group, 'prompt context');
      });

      test('should dispatch INSERT_CONTEXT_BLOCK_COMMAND when selectable and onSelectMenuOption is called', () {
        promptOptions(actions: r.actions, contextBlock: _context()).single.onSelect!();
        expect(r.calls, [PromptBlockKind.context]);
      });

      test('should NOT dispatch any command when selectable is false', () {
        promptOptions(actions: r.actions, contextBlock: _context(selectable: false)).single.onSelect!();
        expect(r.calls, isEmpty);
      });
    });

    group('queryBlock', () {
      test('should NOT include query option when show is false', () {
        expect(promptOptions(actions: r.actions, queryBlock: _block(show: false)), isEmpty);
      });

      test('should include query option when show is true', () {
        final o = promptOptions(actions: r.actions, queryBlock: _block());
        expect(o, hasLength(1));
        expect(o[0].group, 'prompt query');
      });

      test('should dispatch INSERT_QUERY_BLOCK_COMMAND when selectable', () {
        promptOptions(actions: r.actions, queryBlock: _block()).single.onSelect!();
        expect(r.calls, [PromptBlockKind.query]);
      });

      test('should NOT dispatch command when selectable is false', () {
        promptOptions(actions: r.actions, queryBlock: _block(selectable: false)).single.onSelect!();
        expect(r.calls, isEmpty);
      });
    });

    group('requestURLBlock', () {
      test('should NOT include request URL option when show is false', () {
        expect(promptOptions(actions: r.actions, requestUrlBlock: _block(show: false)), isEmpty);
      });

      test('should include request URL option when show is true', () {
        final o = promptOptions(actions: r.actions, requestUrlBlock: _block());
        expect(o, hasLength(1));
        expect(o[0].group, 'request URL');
      });

      test('should dispatch INSERT_REQUEST_URL_BLOCK_COMMAND when selectable', () {
        promptOptions(actions: r.actions, requestUrlBlock: _block()).single.onSelect!();
        expect(r.calls, [PromptBlockKind.requestUrl]);
      });

      test('should NOT dispatch command when selectable is false', () {
        promptOptions(actions: r.actions, requestUrlBlock: _block(selectable: false)).single.onSelect!();
        expect(r.calls, isEmpty);
      });
    });

    group('historyBlock', () {
      test('should NOT include history option when show is false', () {
        expect(promptOptions(actions: r.actions, historyBlock: _history(show: false)), isEmpty);
      });

      test('should include history option when show is true', () {
        final o = promptOptions(actions: r.actions, historyBlock: _history());
        expect(o, hasLength(1));
        expect(o[0].group, 'prompt history');
      });

      test('should dispatch INSERT_HISTORY_BLOCK_COMMAND when selectable', () {
        promptOptions(actions: r.actions, historyBlock: _history()).single.onSelect!();
        expect(r.calls, [PromptBlockKind.history]);
      });

      test('should NOT dispatch command when selectable is false', () {
        promptOptions(actions: r.actions, historyBlock: _history(selectable: false)).single.onSelect!();
        expect(r.calls, isEmpty);
      });
    });

    group('all blocks visible', () {
      test('should return all four options in correct order', () {
        final o = promptOptions(
          actions: r.actions,
          contextBlock: _context(),
          queryBlock: _block(),
          historyBlock: _history(),
          requestUrlBlock: _block(),
        );
        expect(o.map((e) => e.group), ['prompt context', 'prompt query', 'request URL', 'prompt history']);
      });
    });
  });

  group('useVariableOptions', () {
    final r = _Recorder();
    setUp(r.calls.clear);

    group('when variableBlock.show is false', () {
      test('should return an empty array', () {
        expect(variableOptions(_variables([(value: 'foo', name: 'foo')], show: false), null, r.actions), isEmpty);
      });
    });

    group('when variableBlock is undefined', () {
      test('should return an empty array', () {
        expect(variableOptions(null, null, r.actions), isEmpty);
      });
    });

    group('when variableBlock.variables is undefined', () {
      test('should return only the addOption', () {
        final o = variableOptions(const VariableBlockConfig(show: true), null, r.actions);
        expect(o, hasLength(1));
        expect(o[0].group, 'prompt variable');
      });
    });

    group('with variables and no queryString', () {
      test('should return all variables + addOption', () {
        final o = variableOptions(
          _variables([(value: 'alpha', name: 'Alpha'), (value: 'beta', name: 'Beta')]),
          null,
          r.actions,
        );
        expect(o.map((e) => e.key).take(2), ['alpha', 'beta']);
        expect(o, hasLength(3));
      });

      test('should dispatch INSERT_VARIABLE_VALUE_BLOCK_COMMAND with correct payload when variable is selected', () {
        variableOptions(_variables([(value: 'myvar', name: 'My Var')]), null, r.actions)[0].onSelect!();
        expect(r.calls, ['{{myvar}}']);
      });
    });

    group('with queryString filtering', () {
      test('should filter variables by queryString (case-insensitive)', () {
        final o = variableOptions(
          _variables([
            (value: 'alpha', name: 'Alpha'),
            (value: 'beta', name: 'Beta'),
            (value: 'ALPHA_UPPER', name: 'ALPHA_UPPER'),
          ]),
          'alpha',
          r.actions,
        );
        expect(o, hasLength(3));
        expect(o[0].key, 'alpha');
        expect(o[1].key, 'ALPHA_UPPER');
      });

      test('should return only addOption when no variables match the queryString', () {
        final o = variableOptions(
          _variables([(value: 'alpha', name: 'Alpha'), (value: 'beta', name: 'Beta')]),
          'zzz',
          r.actions,
        );
        expect(o, hasLength(1));
      });
    });

    group('addOption (the last element)', () {
      test('should call editor.update() when addOption is selected', () {
        variableOptions(_variables([]), null, r.actions).last.onSelect!();
        expect(r.calls, ['{{}}']);
      });
    });
  });

  group('useExternalToolOptions', () {
    final r = _Recorder();
    setUp(r.calls.clear);
    const sampleTool = ExternalToolOption(
      name: 'weather',
      variableName: 'weather_tool',
      icon: 'cloud',
      iconBackground: '#fff',
    );

    group('when externalToolBlockType.show is false', () {
      test('should return an empty array', () {
        expect(externalToolOptions(_tools([sampleTool], show: false), null, r.actions), isEmpty);
      });
    });

    group('when externalToolBlockType is undefined', () {
      test('should return an empty array', () {
        expect(externalToolOptions(null, null, r.actions), isEmpty);
      });
    });

    group('when externalTools is undefined', () {
      test('should return only the addOption', () {
        final o = externalToolOptions(const ExternalToolBlockConfig(show: true), null, r.actions);
        expect(o, hasLength(1));
        expect(o[0].group, 'external tool');
      });
    });

    group('with tools and no queryString', () {
      test('should return all tools + addOption', () {
        final o = externalToolOptions(
          _tools(const [
            ExternalToolOption(name: 'tool-a', variableName: 'tool_a'),
            ExternalToolOption(name: 'tool-b', variableName: 'tool_b'),
          ]),
          null,
          r.actions,
        );
        expect(o, hasLength(3));
        expect(o[0].key, 'tool-a');
        expect(o[1].key, 'tool-b');
      });

      test('should dispatch INSERT_VARIABLE_VALUE_BLOCK_COMMAND with variableName when tool is selected', () {
        externalToolOptions(_tools(const [sampleTool]), null, r.actions)[0].onSelect!();
        expect(r.calls, ['{{weather_tool}}']);
      });
    });

    group('with queryString filtering', () {
      test('should filter tools by queryString (case-insensitive)', () {
        final o = externalToolOptions(
          _tools(const [
            ExternalToolOption(name: 'WeatherTool', variableName: 'weather'),
            ExternalToolOption(name: 'SearchTool', variableName: 'search'),
          ]),
          'weather',
          r.actions,
        );
        expect(o, hasLength(2));
        expect(o[0].key, 'WeatherTool');
      });

      test('should return only addOption when no tools match', () {
        final o = externalToolOptions(
          _tools(const [ExternalToolOption(name: 'Alpha', variableName: 'alpha')]),
          'zzz',
          r.actions,
        );
        expect(o, hasLength(1));
      });
    });

    group('addOption (the last element)', () {
      test('should call onAddExternalTool when addOption is selected and callback provided', () {
        var added = 0;
        externalToolOptions(_tools(const [], onAdd: () => added++), null, r.actions).last.onSelect!();
        expect(added, 1);
      });

      test('should NOT throw when onAddExternalTool is undefined and addOption is selected', () {
        final o = externalToolOptions(_tools(const []), null, r.actions).last;
        expect(() => o.onSelect!(), returnsNormally);
      });
    });
  });

  group('useOptions', () {
    final r = _Recorder();
    VarGroup nodeVars(String id, String title, [List<PickerVar> vars = const []]) =>
        VarGroup(nodeId: id, title: title, vars: vars);

    group('with no arguments', () {
      test('should return empty workflowVariableOptions and allFlattenOptions', () {
        expect(workflowVariableOptions(), isEmpty);
        expect(pickerOptions(actions: r.actions), isEmpty);
      });
    });

    group('allFlattenOptions aggregation', () {
      test('should combine prompt, variable, and external tool options', () {
        final o = pickerOptions(
          actions: r.actions,
          contextBlock: _context(),
          variableBlock: _variables([(value: 'v1', name: 'v1')]),
          externalToolBlock: _tools(const [ExternalToolOption(name: 't1', variableName: 'tv1')]),
        );
        expect(o, hasLength(5));
      });
    });

    group('workflowVariableOptions when show is false', () {
      test('should return empty array', () {
        expect(workflowVariableOptions(workflowVariableBlock: _workflow([], show: false)), isEmpty);
      });
    });

    group('workflowVariableOptions with plain variables', () {
      test('should return variables as-is when no special blocks are shown', () {
        final o = workflowVariableOptions(
          workflowVariableBlock: _workflow([
            nodeVars('node-1', 'Node One', const [PickerVar('out', 'string')]),
          ]),
        );
        expect(o, hasLength(1));
        expect(o[0].nodeId, 'node-1');
      });
    });

    group('workflowVariableOptions when variables is undefined', () {
      test('should default to empty array', () {
        expect(workflowVariableOptions(workflowVariableBlock: const WorkflowVariableBlockConfig(show: true)), isEmpty);
      });
    });

    group('errorMessageBlockType injection', () {
      test('should prepend error_message node when show is true and not already present', () {
        final o = workflowVariableOptions(
          workflowVariableBlock: _workflow([]),
          errorMessageBlock: const PromptBlockConfig(show: true),
        );
        expect(o[0].nodeId, 'error_message');
        expect(o[0].vars[0].variable, 'error_message');
        expect(o[0].vars[0].type, 'string');
      });

      test('should NOT inject error_message when already present in variables', () {
        final o = workflowVariableOptions(
          workflowVariableBlock: _workflow([
            nodeVars('error_message', 'error_message', const [PickerVar('error_message', 'string')]),
          ]),
          errorMessageBlock: const PromptBlockConfig(show: true),
        );
        expect(o.where((v) => v.nodeId == 'error_message'), hasLength(1));
      });

      test('should NOT inject error_message when errorMessageBlockType.show is false', () {
        final o = workflowVariableOptions(
          workflowVariableBlock: _workflow([]),
          errorMessageBlock: const PromptBlockConfig(),
        );
        expect(o.where((v) => v.nodeId == 'error_message'), isEmpty);
      });
    });

    group('lastRunBlockType injection', () {
      test('should prepend last_run node when show is true and not already present', () {
        final o = workflowVariableOptions(
          workflowVariableBlock: _workflow([]),
          lastRunBlock: const PromptBlockConfig(show: true),
        );
        expect(o[0].nodeId, 'last_run');
        expect(o[0].vars[0].type, 'object');
      });

      test('should NOT inject last_run when already present in variables', () {
        final o = workflowVariableOptions(
          workflowVariableBlock: _workflow([
            nodeVars('last_run', 'last_run', const [PickerVar('last_run', 'object')]),
          ]),
          lastRunBlock: const PromptBlockConfig(show: true),
        );
        expect(o.where((v) => v.nodeId == 'last_run'), hasLength(1));
      });

      test('should NOT inject last_run when lastRunBlockType.show is false', () {
        final o = workflowVariableOptions(
          workflowVariableBlock: _workflow([]),
          lastRunBlock: const PromptBlockConfig(),
        );
        expect(o.where((v) => v.nodeId == 'last_run'), isEmpty);
      });
    });

    group('currentBlockType injection', () {
      test('should prepend current node with title "current_prompt" when generatorType is prompt', () {
        final o = workflowVariableOptions(
          workflowVariableBlock: _workflow([]),
          currentBlock: const CurrentBlockConfig(show: true),
        );
        final current = o.firstWhere((v) => v.nodeId == 'current');
        expect(current.title, 'current_prompt');
        expect(current.vars[0].type, 'string');
      });

      test('should prepend current node with title "current_code" when generatorType is not prompt', () {
        final o = workflowVariableOptions(
          workflowVariableBlock: _workflow([]),
          currentBlock: const CurrentBlockConfig(show: true, generatorType: PromptGeneratorType.code),
        );
        expect(o.firstWhere((v) => v.nodeId == 'current').title, 'current_code');
      });

      test('should NOT inject current node when already present', () {
        final o = workflowVariableOptions(
          workflowVariableBlock: _workflow([
            nodeVars('current', 'current_prompt', const [PickerVar('current', 'string')]),
          ]),
          currentBlock: const CurrentBlockConfig(show: true),
        );
        expect(o.where((v) => v.nodeId == 'current'), hasLength(1));
      });

      test('should NOT inject current node when currentBlockType.show is false', () {
        final o = workflowVariableOptions(
          workflowVariableBlock: _workflow([]),
          currentBlock: const CurrentBlockConfig(),
        );
        expect(o.where((v) => v.nodeId == 'current'), isEmpty);
      });
    });

    group('stacking order of injected nodes', () {
      test('should place current first, then last_run, then error_message, then base vars', () {
        final o = workflowVariableOptions(
          workflowVariableBlock: _workflow([nodeVars('base-node', 'Base')]),
          currentBlock: const CurrentBlockConfig(show: true),
          errorMessageBlock: const PromptBlockConfig(show: true),
          lastRunBlock: const PromptBlockConfig(show: true),
        );
        expect(o.map((v) => v.nodeId), ['current', 'last_run', 'error_message', 'base-node']);
      });
    });

    group('full integration scenario', () {
      test('should return correct combined options when all block types are configured', () {
        final options = pickerOptions(
          actions: r.actions,
          queryString: 'v1',
          contextBlock: _context(),
          queryBlock: _block(),
          historyBlock: _history(),
          requestUrlBlock: _block(),
          variableBlock: _variables([(value: 'v1', name: 'v1')]),
          externalToolBlock: _tools(const [ExternalToolOption(name: 'tool1', variableName: 'tv1')]),
        );
        expect(options, hasLength(7));
        final vars = workflowVariableOptions(
          workflowVariableBlock: _workflow([nodeVars('node-x', 'NodeX')]),
          currentBlock: const CurrentBlockConfig(show: true),
          errorMessageBlock: const PromptBlockConfig(show: true),
          lastRunBlock: const PromptBlockConfig(show: true),
        );
        expect(vars.map((v) => v.nodeId), ['current', 'last_run', 'error_message', 'node-x']);
      });
    });
  });
}
