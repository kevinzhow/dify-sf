import 'package:flutter/foundation.dart';

import '../../store/workflow_store.dart';

/// hooks/use-checklist.ts `ChecklistItem`: one entry of the checklist (a node with problems, or a missing node).
@immutable
class ChecklistItem {
  factory ChecklistItem.fromJson(DifyJson item) => ChecklistItem(
    id: '${item['id'] ?? ''}', type: '${item['type'] ?? ''}', title: '${item['title'] ?? item['id'] ?? ''}',
    toolIcon: item['toolIcon'], unConnected: item['unConnected'] == true,
    errorMessages: [for (final e in item['errorMessages'] as List? ?? const []) '$e'],
    canNavigate: item['canNavigate'] == true, disableGoTo: item['disableGoTo'] == true,
    isPluginMissing: item['isPluginMissing'] == true, pluginUniqueIdentifier: item['pluginUniqueIdentifier'] as String?,
    openInlineAgentPanel: item['openInlineAgentPanel'] == true,
  );

  const ChecklistItem({
    required this.id,
    required this.type,
    required this.title,
    this.toolIcon,
    this.unConnected = false,
    this.errorMessages = const [],
    required this.canNavigate,
    this.disableGoTo = false,
    this.isPluginMissing = false,
    this.pluginUniqueIdentifier,
    this.openInlineAgentPanel = false,
  });

  final String id;

  /// The node type (`BlockEnum` value).
  final String type;
  final String title;

  /// A tool's icon (a URL, or Dify's emoji `{content, background}`), when known.
  final Object? toolIcon;
  final bool unConnected;
  final List<String> errorMessages;
  final bool canNavigate;
  final bool disableGoTo;
  final bool isPluginMissing;
  final String? pluginUniqueIdentifier;
  final bool openInlineAgentPanel;

  ChecklistItem copyWith({String? type, String? title, bool? openInlineAgentPanel}) => ChecklistItem(
    id: id,
    type: type ?? this.type,
    title: title ?? this.title,
    toolIcon: toolIcon,
    unConnected: unConnected,
    errorMessages: errorMessages,
    canNavigate: canNavigate,
    disableGoTo: disableGoTo,
    isPluginMissing: isPluginMissing,
    pluginUniqueIdentifier: pluginUniqueIdentifier,
    openInlineAgentPanel: openInlineAgentPanel ?? this.openInlineAgentPanel,
  );

  /// The item as Dify's JSON (what the store's `checklistItems` holds).
  DifyJson toJson() => {
    'id': id,
    'type': type,
    'title': title,
    'toolIcon': ?toolIcon,
    'unConnected': unConnected,
    'errorMessages': errorMessages,
    'canNavigate': canNavigate,
    'disableGoTo': disableGoTo,
    'isPluginMissing': isPluginMissing,
    'pluginUniqueIdentifier': ?pluginUniqueIdentifier,
    if (openInlineAgentPanel) 'openInlineAgentPanel': true,
  };

  @override
  bool operator ==(Object other) =>
      other is ChecklistItem &&
      other.id == id &&
      other.type == type &&
      other.title == title &&
      other.toolIcon == toolIcon &&
      other.unConnected == unConnected &&
      listEquals(other.errorMessages, errorMessages) &&
      other.canNavigate == canNavigate &&
      other.disableGoTo == disableGoTo &&
      other.isPluginMissing == isPluginMissing &&
      other.pluginUniqueIdentifier == pluginUniqueIdentifier &&
      other.openInlineAgentPanel == openInlineAgentPanel;

  @override
  int get hashCode => Object.hash(id, type, title, unConnected, Object.hashAll(errorMessages), canNavigate);

  @override
  String toString() => 'ChecklistItem($id, $type, "$title", $errorMessages${unConnected ? ', unConnected' : ''})';
}
