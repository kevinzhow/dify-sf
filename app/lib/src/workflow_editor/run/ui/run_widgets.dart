/// Small pieces the run panels and the chat share: base/chat/chat/loading-anim (the flashing dots), the file list of
/// results (base/file-uploader FileList), run/output-panel.tsx and run/result-text.tsx.
library;

import 'dart:convert';

import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';

import '../../../design/dify_icon.dart';
import '../../../design/dify_tokens.g.dart';
import '../../../i18n/dify_i18n.dart';
import '../../code_editor/code_editor.dart';
import '../../panel_fields/file_upload_setting.dart' show formatFileSize;
import '../../store/workflow_store.dart' show DifyJson;
import 'markdown.dart';
import 'status.dart';
import '../../../design/widgets/widgets.dart';

/// getProcessedFilesFromResponse: Dify's file JSON (`related_id`, `filename`, `mime_type`, ...) as FileEntity.
List<DifyJson> getProcessedFilesFromResponse(List<DifyJson> files) => [
  for (final f in files)
    {
      'id': f['related_id'],
      'name': f['filename'],
      'size': f['size'] ?? 0,
      'type': f['mime_type'],
      'progress': 100,
      'transferMethod': f['transfer_method'],
      'supportFileType': f['type'],
      'uploadedId': f['upload_file_id'] ?? f['related_id'],
      'url': f['url'] ?? f['remote_url'],
    },
];

/// FileList (file-uploader-in-chat-input/file-list.tsx): `flex flex-wrap gap-2` of 144 x 68 file cards (name in two
/// lines, the type icon, "EXT · size").
class RunFileList extends StatelessWidget {
  const RunFileList({super.key, required this.files});
  final List<DifyJson> files;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [for (final f in files) _FileCard(file: f)],
  );
}

class _FileCard extends StatelessWidget {
  const _FileCard({required this.file});
  final DifyJson file;

  @override
  Widget build(BuildContext context) {
    final name = '${file['name'] ?? ''}';
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toUpperCase();
    final size = file['size'];
    return Semantics(
      label: name,
      child: Container(
        width: 144,
        height: 68,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: DifyColors.componentsCardBg,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(color: DifyColors.componentsPanelBorder, width: 0.5),
          boxShadow: DifyShadows.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DifyText(name, DifyType.systemXsMedium, color: DifyColors.textTertiary, maxLines: 2),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 16,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: RemixIcon('file-3-fill', size: 16, color: DifyFileTypeColors.code),
                  ),
                  Flexible(
                    child: DifyText(
                      [if (ext.isNotEmpty) ext, if (size is num && size > 0) formatFileSize(size)].join(' · '),
                      DifyType.system2xsMediumUppercase,
                      color: DifyColors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Object? _tryDecode(String s) {
  try {
    return jsonDecode(s);
  } on FormatException {
    return null;
  }
}

bool _isFile(Object? v) => v is Map && v['dify_model_identity'] == '__dify__file__';

/// OutputPanel (run/output-panel.tsx): the dots while running, the error (copyable), "No Output", a single text output
/// as Markdown, a single file output as files, or the outputs as JSON in half the available [height].
class OutputPanel extends StatelessWidget {
  const OutputPanel({super.key, this.isRunning = false, this.outputs, this.error, this.height});
  final bool isRunning;
  final Object? outputs;
  final String? error;
  final double? height;

  @override
  Widget build(BuildContext context) {
    // Dify's type says the run detail's outputs are a JSON string, its API sends an object: read either.
    final o = switch (outputs) {
      final String s when s.trimLeft().startsWith('{') => _tryDecode(s) ?? s,
      final v => v,
    };
    final map = o is Map ? o : null;
    final keys = map?.keys.toList() ?? const [];
    final first = keys.isEmpty ? null : map![keys.first];
    final isTextOutput =
        map != null && keys.length == 1 && (first is String || (first is List && first.every((i) => i is String)));
    final files = <DifyJson>[];
    if (map != null && keys.length <= 1) {
      for (final v in map.values) {
        if (v is List) {
          files.addAll(v.where(_isFile).cast<DifyJson>());
        } else if (_isFile(v)) {
          files.add(v as DifyJson);
        }
      }
    }
    final empty = o == null || (o is String && o.isEmpty);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isRunning)
            const Padding(
              padding: EdgeInsets.only(top: 16, left: 26),
              child: Align(alignment: Alignment.centerLeft, child: DifyLoadingAnim()),
            ),
          if (!isRunning && (error ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: StatusContainer(status: 'failed', copyContent: error, child: DifyTextLine(error!)),
            ),
          if (!isRunning && empty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: DifyMarkdown(content: 'No Output'),
            ),
          if (isTextOutput)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: DifyMarkdown(content: first is List ? first.join('\n') : '$first'),
            ),
          if (files.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: RunFileList(files: getProcessedFilesFromResponse(files)),
            ),
          // `Object.keys(outputs).length > 0`: a non-empty string counts too (shown JSON-quoted).
          if (!isTextOutput && ((map != null && map.isNotEmpty) || (o is String && o.isNotEmpty)) && (height ?? 0) > 0)
            DifyCodeEditor(
              readOnly: true,
              titleWidget: const ExcludeFocus(child: DifyTextLine('Output')),
              language: CodeLanguage.json,
              value: const JsonEncoder.withIndent('  ').convert(map ?? o),
              isJSONStringifyBeauty: true,
              height: (height! - 16) / 2,
            ),
        ],
      ),
    );
  }
}

/// ResultText (run/result-text.tsx): the dots while waiting, the error, the empty state with its "view detail" link,
/// or the text result as Markdown and the result files per variable.
class ResultText extends StatelessWidget {
  const ResultText({
    super.key,
    this.isRunning = false,
    this.isPaused = false,
    this.outputs,
    this.error,
    this.onClick,
    this.allFiles,
  });

  final bool isRunning;
  final bool isPaused;
  final Object? outputs;
  final String? error;
  final VoidCallback? onClick;

  /// `[{varName, list: [FileEntity]}]`.
  final List<DifyJson>? allFiles;

  @override
  Widget build(BuildContext context) {
    final has = outputs != null && outputs != '';
    final files = allFiles ?? const [];
    String tr(String k) => DifyI18n.tr('run-log', k);
    return ColoredBox(
      color: DifyColors.backgroundSectionBurn,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isRunning && !has)
            const Padding(
              padding: EdgeInsets.only(top: 16, left: 26),
              child: Align(alignment: Alignment.centerLeft, child: DifyLoadingAnim()),
            ),
          if (!isRunning && (error ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: StatusContainer(status: 'failed', child: DifyTextLine(error!)),
            ),
          if (!isPaused && !isRunning && !has && (error ?? '').isEmpty && files.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 128, 16, 8),
              child: DefaultTextStyle.merge(
                style: difyTextStyle(DifyTw.text13Leading18, DifyTailwind.gray500),
                child: Column(
                  children: [
                    DifyIcon('vender/line/editor/image-indent-left', size: 24, color: DifyTailwind.gray400),
                    Padding(padding: const EdgeInsets.only(right: 8), child: DifyTextLine(tr('resultEmpty.title'))),
                    DifyTextLine.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: tr('resultEmpty.tipLeft')),
                          WidgetSpan(
                            alignment: PlaceholderAlignment.baseline,
                            baseline: TextBaseline.alphabetic,
                            child: GestureDetector(
                              onTap: onClick,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: DifyTextLine(
                                  tr('resultEmpty.link'),
                                  style: difyTextStyle(DifyTw.text13Leading18, DifyTailwind.primary600),
                                ),
                              ),
                            ),
                          ),
                          TextSpan(text: tr('resultEmpty.tipRight')),
                        ],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          if (has)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: DifyMarkdown(content: outputs is String ? outputs! as String : jsonEncode(outputs)),
            ),
          for (final item in files)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: DifyText(
                      '${item['varName'] ?? ''}',
                      DifyType.systemXsRegular,
                      color: DifyColors.textTertiary,
                    ),
                  ),
                  RunFileList(files: [for (final f in (item['list'] as List? ?? const [])) f as DifyJson]),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// ReasoningPanel (base/chat/chat/answer/reasoning-panel.tsx) in ThinkingDetails: "Thinking…(1.2s)" while [done] is
/// false (counting every 100 ms), then "Thought(3.4s)" collapsed; the nodes' reasoning joined as Markdown.
class ReasoningPanel extends StatefulWidget {
  const ReasoningPanel({super.key, required this.content, required this.done});

  /// LLM node id → reasoning text.
  final Map<Object?, Object?> content;
  final bool done;

  static String textOf(Map<Object?, Object?>? content) => [
    for (final v in (content ?? const {}).values)
      if (v is String && v.isNotEmpty) v,
  ].join('\n\n');

  @override
  State<ReasoningPanel> createState() => _ReasoningPanelState();
}

class _ReasoningPanelState extends State<ReasoningPanel> {
  final _start = DateTime.now();
  double _elapsed = 0;
  late bool _complete = widget.done;
  bool _open = false;
  Ticker? _ticker;

  @override
  void initState() {
    super.initState();
    if (!_complete) {
      _ticker = Ticker((_) {
        final e = (DateTime.now().difference(_start).inMilliseconds ~/ 100) / 10;
        if (e != _elapsed) setState(() => _elapsed = e);
      })..start();
    }
  }

  @override
  void didUpdateWidget(ReasoningPanel old) {
    super.didUpdateWidget(old);
    if (widget.done && !_complete) {
      setState(() => _complete = true);
      _ticker?.dispose();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = ReasoningPanel.textOf(widget.content);
    if (text.isEmpty) return const SizedBox.shrink();
    final open = _complete ? _open : true;
    final label =
        '${DifyI18n.tr('common', _complete ? 'chat.thought' : 'chat.thinking')}(${_elapsed.toStringAsFixed(1)}s)';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: _complete ? () => setState(() => _open = !_open) : null,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: open ? 0.25 : 0,
                      duration: const Duration(milliseconds: 500),
                      child: RemixIcon('arrow-right-s-line', size: 12, color: DifyColors.textSecondary),
                    ),
                    const SizedBox(width: 8),
                    DifyTextLine(
                      label,
                      style: difyTextStyle(DifyTw.fontBold, DifyColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (open)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: DifyColors.componentsPanelBgAlt,
                border: Border(left: BorderSide(color: DifyColors.componentsPanelBorder)),
              ),
              child: DifyMarkdown(content: text, color: DifyColors.textSecondary),
            ),
        ],
      ),
    );
  }
}

/// `aria-expanded` on a pressable (whose own semantics are merged): one node with the label and the expanded state.
class ExpandedSemantics extends StatelessWidget {
  const ExpandedSemantics({super.key, required this.expanded, required this.child});
  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(expanded: expanded, child: child),
  );
}
