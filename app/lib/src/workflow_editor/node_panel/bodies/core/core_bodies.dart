/// The node panel bodies of the core node group: Start, End, Answer, IF/ELSE, Code, Template, Variable Aggregator
/// (and its legacy `variable-assigner` type) and Variable Assigner.
library;

import '../../node_panel_bodies.dart';
import 'answer_panel.dart';
import 'assigner_panel.dart';
import 'code_panel.dart';
import 'end_panel.dart';
import 'if_else_panel.dart';
import 'start_panel.dart';
import 'template_panel.dart';
import 'variable_aggregator_panel.dart';

export 'core_kit.dart' show CorePanelHost, CorePanelHostData, CodeGeneratorBuilder;

/// The core bodies by node type, for [NodePanelBodies].
const Map<String, NodePanelBodyBuilder> corePanelBodies = {
  'start': startPanelBody,
  'end': endPanelBody,
  'answer': answerPanelBody,
  'if-else': ifElsePanelBody,
  'code': codePanelBody,
  'template-transform': templatePanelBody,
  'variable-aggregator': variableAggregatorPanelBody,
  'variable-assigner': variableAggregatorPanelBody,
  'assigner': assignerPanelBody,
};
