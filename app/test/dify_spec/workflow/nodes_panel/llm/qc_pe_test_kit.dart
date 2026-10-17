import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/llm/group_host.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../dify_test_i18n.dart';

/// [child] alone (Dify's `render(<Component/>)`), 360 px wide, with [services] and a store in scope.
Future<void> pumpComponent(
  WidgetTester t,
  Widget child, {
  LlmGroupServices services = LlmGroupServices.empty,
  WorkflowStore? store,
  double width = 360,
}) async {
  t.view.physicalSize = const Size(1200, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: store ?? WorkflowStore(),
          child: LlmGroupScope(
            services: services,
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: SizedBox(
                  width: width,
                  child: SingleChildScrollView(child: child),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 100));
}

/// The prompt editor panels on screen, in order.
List<DifyPromptEditorPanel> editors(WidgetTester t) =>
    t.widgetList<DifyPromptEditorPanel>(find.byType(DifyPromptEditorPanel)).toList();

Future<void> settleShort(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Collects toasts.
class Toasts {
  final messages = <String>[];
  void call(LlmToastType type, String message) => messages.add('${type.name}:$message');
}

/// Dify's test translator, with the labels laid out in one row shortened (the vision resolution picker, the reasoning
/// mode cards: `fnCall` / `prompt`, "Import from tools" beside the Extract Parameters title: `import`): the
/// `<ns>.<key>` texts would overflow them.
class _ShortVisionTranslator extends DifyTestTranslator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      _short[key] ?? (key.startsWith('nodes.llm.resolution.') ? key.split('.').last : super.t(ns, key, params));

  static const _short = {
    'nodes.parameterExtractor.reasoningModeFunctionToolCalling': 'fnCall',
    'nodes.parameterExtractor.reasoningModePrompt': 'prompt',
    'nodes.parameterExtractor.importFromTool': 'import',
  };
}

void useShortVisionTranslator() => DifyI18n.current = _ShortVisionTranslator();
