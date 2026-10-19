/// The form content preview (components/form-content-preview.tsx, variable-in-markdown.tsx).
///
/// dify-sf has no Markdown renderer yet: the content is shown as blocks (paragraphs, `#` headings, `-` / `*` list
/// items) run through Dify's rehype plugins, so variables show as `{{Node/var}}` and form inputs as their notes.
library;

import 'package:flutter/material.dart';

import '../../../../../design/css_metrics.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../../design/widgets/widgets.dart';
import '../../../../../i18n/dify_i18n.dart';
import '../../../../../workflow/dify_json.dart';
import '../data_common.dart';
import 'human_input_kit.dart';
import 'human_input_model.dart';
import 'user_action.dart';

/// Variable: the path as `{{node/var}}` in `text-text-accent`.
class VariablePath extends StatelessWidget {
  const VariablePath(this.path, {super.key});
  final String path;

  @override
  Widget build(BuildContext context) =>
      Text(formatVariablePath(path), style: difyStyle(DifyType.systemSmRegular, DifyColors.textAccent));
}

/// Note: how a form input shows in the preview — a paragraph's default (or its variable path), a select preview of
/// the options (or the variable path), upload tiles for files.
class FormInputNote extends StatelessWidget {
  const FormInputNote({super.key, required this.input, required this.nodeName});
  final Object? input;
  final String Function(String nodeId) nodeName;

  static Widget _box(Widget child) => Container(
    margin: const EdgeInsets.symmetric(vertical: 12),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(color: DifyColors.componentsInputBgNormal, borderRadius: BorderRadius.circular(10)),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    List<String> strings(Object? x) => [for (final e in jsList(x)) jsKey(e)];
    if (isSelectFormInput(input)) {
      final source = jsGet(input, 'option_source');
      if (jsGet(source, 'type') == 'variable') {
        final path = sourceToVariablePath(strings(jsGet(source, 'selector')), nodeName);
        return _box(path.isEmpty ? Text(hi('insertInputField.variable')) : VariablePath(path));
      }
      final options = strings(jsGet(source, 'value'));
      return _SelectPreview(
        label: options.firstOrNull ?? DifyI18n.tr('app-debug', 'variableConfig.select'),
        options: options,
      );
    }
    if (isFileFormInput(input) || isFileListFormInput(input)) {
      return _FilePreview(methods: strings(jsGet(input, 'allowed_file_upload_methods')));
    }
    final def = jsGet(input, 'default');
    return _box(
      jsGet(def, 'type') == 'variable'
          ? VariablePath(sourceToVariablePath(strings(jsGet(def, 'selector')), nodeName))
          : Text('${jsGet(def, 'value') ?? ''}'),
    );
  }
}

class _SelectPreview extends StatefulWidget {
  const _SelectPreview({required this.label, required this.options});
  final String label;
  final List<String> options;

  @override
  State<_SelectPreview> createState() => _SelectPreviewState();
}

class _SelectPreviewState extends State<_SelectPreview> {
  late String _value = widget.options.firstOrNull ?? widget.label;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('human-input-note-select-preview'),
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Semantics(
      label: 'human-input-note-select',
      child: DifySelect<String>(
        value: _value,
        options: [for (final o in widget.options) (value: o, label: o)],
        onChanged: (v) => setState(() => _value = v),
        placeholder: widget.label,
      ),
    ),
  );
}

class _FilePreview extends StatelessWidget {
  const _FilePreview({required this.methods});
  final List<String> methods;

  @override
  Widget build(BuildContext context) {
    final m = methods.isEmpty ? const ['local_file', 'remote_url'] : methods;
    final actions = [
      if (m.contains('local_file')) ('upload-cloud-2-line', cm('fileUploader.uploadFromComputer')),
      if (m.contains('remote_url')) ('link', cm('fileUploader.pasteFileLink')),
    ];
    return Padding(
      key: const ValueKey('human-input-note-file-preview'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        spacing: 8,
        children: [
          for (final (icon, label) in actions)
            Expanded(
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: DifyColors.componentsInputBgNormal,
                  borderRadius: BorderRadius.circular(DifyRadius.xl),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    RemixIcon(icon, size: 20, color: DifyColors.textTertiary),
                    const SizedBox(width: 8),
                    Flexible(child: DifyText(label, DifyType.systemSmMedium, color: DifyColors.textTertiary)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The content as hast-like blocks: `#`-headings (`h1`..`h6`), list items (`li`), paragraphs (`p`).
MdNode markdownBlocks(String content) {
  final root = MdNode(tagName: 'root');
  for (final block in content.split(RegExp(r'\n\s*\n'))) {
    final para = <String>[];
    void flush() {
      if (para.isEmpty) return;
      root.children.add(MdNode(type: 'element', tagName: 'p', children: [MdNode.text(para.join('\n'))]));
      para.clear();
    }

    for (final line in block.split('\n')) {
      final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
      final li = RegExp(r'^\s*[-*]\s+(.*)$').firstMatch(line);
      if (h != null) {
        flush();
        root.children.add(
          MdNode(type: 'element', tagName: 'h${h[1]!.length}', children: [MdNode.text(h[2]!)]),
        );
      } else if (li != null) {
        flush();
        root.children.add(MdNode(type: 'element', tagName: 'li', children: [MdNode.text(li[1]!)]));
      } else if (line.trim().isNotEmpty) {
        para.add(line);
      }
    }
    flush();
  }
  rehypeVariable(root);
  rehypeNotes(root);
  return root;
}

/// FormContentPreview (`w-150 rounded-2xl`, placed left of the panel by its host): the "Preview" badge and close
/// button, the content with variables as `{{Node/var}}` and form inputs as notes ("Can't find note:" for unknown
/// ones), the action buttons and the tip that they do nothing here.
class FormContentPreview extends StatelessWidget {
  const FormContentPreview({
    super.key,
    required this.content,
    required this.formInputs,
    required this.userActions,
    required this.onClose,
    required this.nodeName,
  });

  final String content;
  final List<Object?> formInputs, userActions;
  final VoidCallback onClose;
  final String Function(String nodeId) nodeName;

  Widget _node(MdNode n) {
    InlineSpan inline(MdNode c) => switch (c.tagName) {
      'variable' => TextSpan(
        text: formatVariablePath(
          replaceNodeIdsWithNames(c.properties?['dataPath'] ?? '', nodeName),
        ),
        style: TextStyle(color: DifyColors.textAccent),
      ),
      _ => TextSpan(text: c.value ?? ''),
    };
    if (n.tagName == 'div') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in n.children)
            if (c.tagName == 'section')
              () {
                final name = c.properties?['dataName'] ?? '';
                final input = formInputs.where((i) => inputNameOf(i) == name).firstOrNull;
                return input == null ? Text("Can't find note:$name") : FormInputNote(input: input, nodeName: nodeName);
              }()
            else if ((c.value ?? '').trim().isNotEmpty)
              Text(c.value!.trim()),
        ],
      );
    }
    // web/app/styles/markdown.css: `.markdown-body h1` 18px, h2 16px, h3-h6 14px over streamdown's `font-semibold`.
    final style = switch (n.tagName) {
      'h1' => DifyMarkdownHeadingStyles.h1,
      'h2' => DifyMarkdownHeadingStyles.h2,
      'h3' || 'h4' || 'h5' || 'h6' => DifyMarkdownHeadingStyles.h3,
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text.rich(
        TextSpan(
          children: [
            if (n.tagName == 'li') const TextSpan(text: '•  '),
            for (final c in n.children) inline(c),
          ],
        ),
        style: style,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tree = markdownBlocks(content);
    return Container(
      width: 600,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.xxl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        boxShadow: DifyShadows.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 26,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  HiBadge(
                    hi('formContent.preview'),
                    color: DifyColors.textAccentSecondary,
                    border: DifyColors.textAccentSecondary,
                  ),
                  DifyIconButton(
                    label: cm('operation.close'),
                    onPressed: onClose,
                    icon: RemixIcon('close-line', size: 20, color: DifyColors.textTertiary),
                  ),
                ],
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DefaultTextStyle.merge(
                style: difyStyle(DifyType.bodyMdRegular, DifyColors.textPrimary),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final n in tree.children) _node(n),
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final a in userActions)
                            DifyButton(
                              variant: buttonVariantOf(jsStr(jsGet(a, 'button_style'))),
                              onPressed: () {},
                              child: Text('${jsGet(a, 'title') ?? ''}'),
                            ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: DifyText(
                        hi('editor.previewTip'),
                        DifyType.systemXsRegular,
                        color: DifyColors.textTertiary,
                        maxLines: null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
