/// The panel bodies of the data group: http-request, tool, document-extractor, list-operator, iteration, loop,
/// loop-end and human-input.
library;

import '../../node_panel_bodies.dart';
import 'document_extractor/document_extractor_panel.dart';
import 'http/http_panel.dart';
import 'human_input/human_input_panel.dart';
import 'iteration/iteration_panel.dart';
import 'list_operator/list_operator_panel.dart';
import 'loop/loop_panel.dart';
import 'tool/tool_panel.dart';

export 'data_common.dart' show DataPanelHost, DataToast, DataToastType;

/// The bodies by node type (register with `NodePanelBodies({...dataPanelBodies, ...})`).
const Map<String, NodePanelBodyBuilder> dataPanelBodies = {
  'http-request': httpRequestPanelBody,
  'tool': toolPanelBody,
  'document-extractor': documentExtractorPanelBody,
  'list-operator': listOperatorPanelBody,
  'iteration': iterationPanelBody,
  'loop': loopPanelBody,
  'loop-end': loopEndPanelBody,
  'human-input': humanInputPanelBody,
};
