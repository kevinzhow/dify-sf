import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import 'editor_controller.dart';
import 'graph_info.dart';
import 'synced_text_field.dart';
import 'variable_picker.dart';

/// Edits a node's `config` tree. Every change is one small op on one register: a config path, or a single
/// item of a keyed list.
class ConfigEditor extends StatelessWidget {
  const ConfigEditor({super.key, required this.controller, required this.node});

  final EditorController controller;
  final Node node;

  @override
  Widget build(BuildContext context) {
    final keys = node.config.keys.toList()..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final k in keys)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ValueEditor(controller: controller, node: node, path: [k], label: k, value: node.config[k]!),
          ),
        if (keys.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('No configuration yet.', style: TextStyle(color: Colors.black54)),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('add-field'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add field'),
            onPressed: () => _addField(context),
          ),
        ),
      ],
    );
  }

  Future<void> _addField(BuildContext context) async {
    final seen = controller.seenVersion;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NameDialog(title: 'New field', hint: 'field name, e.g. temperature'),
    );
    if (name == null || name.trim().isEmpty || name.startsWith(r'$')) return;
    controller.setConfig(node.id, [name.trim()], const VString(''), base: seen);
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.hint});
  final String title;
  final String hint;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const Key('name-dialog-field'),
      controller: _text,
      autofocus: true,
      decoration: InputDecoration(hintText: widget.hint),
      onSubmitted: (v) => Navigator.pop(context, v),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(context, _text.text), child: const Text('Add')),
    ],
  );
}

class _ValueEditor extends StatelessWidget {
  const _ValueEditor({
    required this.controller,
    required this.node,
    required this.path,
    required this.label,
    required this.value,
  });

  final EditorController controller;
  final Node node;
  final List<String> path;
  final String label;
  final Value value;

  void _set(Value v, {int? base}) => controller.setConfig(node.id, path, v, base: base);

  @override
  Widget build(BuildContext context) {
    switch (value) {
      case VString(:final value):
        return _row(
          SyncedTextField(
            key: ValueKey('cfg-${node.id}-${path.join('.')}'),
            value: value,
            label: label,
            maxLines: value.contains('\n') || value.length > 60 || label == 'prompt' || label == 'code' ? 6 : 1,
            minLines: 1,
            monospace: label == 'code',
            currentVersion: () => controller.seenVersion,
            onCommit: (text, base) => _set(VString(text), base: base),
          ),
          trailing: VariablePickerButton(
            controller: controller,
            selfNodeId: node.id,
            tooltip: 'Replace with a variable',
            onPick: (ref, base) => _set(VRef(ref), base: base),
          ),
        );
      case VInt(:final value):
        return SyncedTextField(
          key: ValueKey('cfg-${node.id}-${path.join('.')}'),
          value: '$value',
          label: label,
          keyboardType: TextInputType.number,
          currentVersion: () => controller.seenVersion,
          onCommit: (text, base) {
            final n = int.tryParse(text.trim());
            if (n != null) _set(VInt(n), base: base);
          },
        );
      case VBool(:final value):
        return SwitchListTile(
          key: ValueKey('cfg-${node.id}-${path.join('.')}'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(label),
          value: value,
          onChanged: (v) => _set(VBool(v)),
        );
      case VNull():
        return _row(
          Text('$label: null', style: const TextStyle(color: Colors.black54)),
          trailing: IconButton(
            tooltip: 'Set to empty text',
            icon: const Icon(Icons.edit, size: 18),
            onPressed: () => _set(const VString('')),
          ),
        );
      case VRef(:final ref):
        return _row(
          InputDecorator(
            decoration: InputDecoration(labelText: label, isDense: true, border: const OutlineInputBorder()),
            child: _RefChip(controller: controller, ref: ref),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              VariablePickerButton(
                controller: controller,
                selfNodeId: node.id,
                tooltip: 'Pick another variable',
                icon: Icons.swap_horiz,
                onPick: (r, base) => _set(VRef(r), base: base),
              ),
              IconButton(
                tooltip: 'Replace with text',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => _set(const VString('')),
              ),
            ],
          ),
        );
      case VBroken(:final ref):
        return _row(
          InputDecorator(
            decoration: InputDecoration(
              labelText: label,
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: 'Broken reference',
            ),
            child: _BrokenChip(controller: controller, ref: ref),
          ),
          trailing: VariablePickerButton(
            controller: controller,
            selfNodeId: node.id,
            tooltip: 'Pick a variable',
            onPick: (r, base) => _set(VRef(r), base: base),
          ),
        );
      case VMap(:final entries):
        final keys = entries.keys.toList()..sort();
        return InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.all(8),
          ),
          child: Column(
            children: [
              for (final k in keys)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: _ValueEditor(
                    controller: controller,
                    node: node,
                    path: [...path, k],
                    label: k,
                    value: entries[k]!,
                  ),
                ),
            ],
          ),
        );
      case VItems(:final items):
        return _ItemsEditor(controller: controller, node: node, path: path, label: label, items: items);
      case VList():
        return InputDecorator(
          decoration: InputDecoration(
            labelText: '$label (list, read-only)',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          child: Text(jsonEncode(value.toJson()), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        );
    }
  }

  Widget _row(Widget child, {Widget? trailing}) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: child),
      ?trailing,
    ],
  );
}

class _RefChip extends StatelessWidget {
  const _RefChip({required this.controller, required this.ref});
  final EditorController controller;
  final OutputRef ref;

  @override
  Widget build(BuildContext context) {
    final exists = controller.doc.nodes.containsKey(ref.node);
    return Wrap(
      spacing: 6,
      children: [
        Chip(
          visualDensity: VisualDensity.compact,
          avatar: const Icon(Icons.data_object, size: 16),
          label: Text('${exists ? controller.titleOf(ref.node) : ref.node} › ${ref.output}'),
        ),
      ],
    );
  }
}

class _BrokenChip extends StatelessWidget {
  const _BrokenChip({required this.controller, required this.ref});
  final EditorController controller;
  final OutputRef ref;

  @override
  Widget build(BuildContext context) {
    final red = Theme.of(context).colorScheme.error;
    return Container(
      key: Key('broken-${ref.node}-${ref.output}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.1),
        border: Border.all(color: red),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.link_off, size: 16, color: red),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${controller.titleOf(ref.node)} › ${ref.output} was deleted',
              style: TextStyle(color: red, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemsEditor extends StatelessWidget {
  const _ItemsEditor({
    required this.controller,
    required this.node,
    required this.path,
    required this.label,
    required this.items,
  });

  final EditorController controller;
  final Node node;
  final List<String> path;
  final String label;
  final List<Item> items;

  bool get _structured => items.isEmpty || items.any((i) => i.value is VMap);

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.all(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items)
            Padding(
              key: ValueKey('item-${item.id}'),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _ItemRow(controller: controller, node: node, path: path, item: item),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: Key('add-item-${path.join('.')}'),
              icon: const Icon(Icons.add, size: 18),
              label: Text('Add ${label.endsWith('s') ? label.substring(0, label.length - 1) : 'item'}'),
              onPressed: () => controller.insertItem(
                node.id,
                path,
                _structured ? const VMap({'name': VString(''), 'type': VString('string')}) : const VString(''),
                after: items.isEmpty ? null : items.last.id,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.controller, required this.node, required this.path, required this.item});

  final EditorController controller;
  final Node node;
  final List<String> path;
  final Item item;

  @override
  Widget build(BuildContext context) {
    final v = item.value;
    final Widget body;
    if (v is VMap) {
      final keys = v.entries.keys.toList()..sort((a, b) => a == 'name' ? -1 : (b == 'name' ? 1 : a.compareTo(b)));
      body = Row(
        children: [
          for (final k in keys)
            if (v.entries[k] case final VString s)
              Expanded(
                flex: k == 'name' ? 3 : 2,
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: SyncedTextField(
                    key: ValueKey('item-${item.id}-$k'),
                    value: s.value,
                    label: k,
                    currentVersion: () => controller.seenVersion,
                    // One item register: replace this item's value with the one field changed.
                    onCommit: (text, base) => controller.updateItem(
                      node.id,
                      path,
                      item.id,
                      VMap({...v.entries, k: VString(text)}),
                      base: base,
                    ),
                  ),
                ),
              ),
        ],
      );
    } else if (v is VString) {
      body = Expanded(
        child: SyncedTextField(
          key: ValueKey('item-${item.id}-value'),
          value: v.value,
          currentVersion: () => controller.seenVersion,
          onCommit: (text, base) => controller.updateItem(node.id, path, item.id, VString(text), base: base),
        ),
      );
    } else {
      body = Expanded(child: Text(previewValue(v)));
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (v is VMap) Expanded(child: body) else body,
        IconButton(
          key: Key('remove-item-${item.id}'),
          tooltip: 'Remove',
          icon: const Icon(Icons.delete_outline, size: 20),
          onPressed: () => controller.removeItem(node.id, path, item.id),
        ),
      ],
    );
  }
}
