/// Dify's prompt string format (web/app/components/base/prompt-editor: constants.tsx, utils.ts, hooks.ts and the
/// `*-replacement-block.tsx` transforms): plain text in which `{{#node.var#}}` references and the special
/// placeholders (`{{#context#}}`, `{{#histories#}}`, …) become inline blocks, and `{{name}}` is highlighted.
///
/// Pure Dart: which tokens become blocks follows Dify's Lexical transforms, quirks included (two identical special
/// placeholders back to back stay text; `{{a}}{{b}}` is not highlighted).
library;

// ---- constants.tsx -----------------------------------------------------------------------------------------------

const contextPlaceholderText = '{{#context#}}';
const historyPlaceholderText = '{{#histories#}}';
const queryPlaceholderText = '{{#query#}}';
const requestUrlPlaceholderText = '{{#url#}}';
const currentPlaceholderText = '{{#current#}}';
const errorMessagePlaceholderText = '{{#error_message#}}';
const lastRunPlaceholderText = '{{#last_run#}}';
const prePromptPlaceholderText = '{{#pre_prompt#}}';

bool checkHasContextBlock(String? text) => text != null && text.isNotEmpty && text.contains(contextPlaceholderText);
bool checkHasHistoryBlock(String? text) => text != null && text.isNotEmpty && text.contains(historyPlaceholderText);
bool checkHasQueryBlock(String? text) => text != null && text.isNotEmpty && text.contains(queryPlaceholderText);

/// `getInputVars`: the value selectors of the `{{#…#}}` references (those with a dot); `{{#<digits>.sys.x#}}` is
/// `[sys, x]`.
List<List<String>> getInputVars(Object? text) {
  if (text is! String || text.isEmpty) return const [];
  return [
    for (final m in RegExp(r'\{\{#([^#]*)#\}\}').allMatches(text))
      if (m[0]!.contains('.'))
        () {
          final sel = m[1]!.split('.');
          return sel.length > 1 && sel[1] == 'sys' && RegExp(r'^\d+$').hasMatch(sel[0]) ? sel.sublist(1) : sel;
        }(),
  ];
}

/// `FILE_EXTS` (by SupportUploadFileTypes).
const fileExts = <String, List<String>>{
  'image': ['JPG', 'JPEG', 'PNG', 'GIF', 'WEBP', 'SVG'],
  'document': [
    'TXT', 'MD', 'MDX', 'MARKDOWN', 'PDF', 'HTML', 'XLSX', 'XLS', 'DOC', 'DOCX', 'CSV', 'EML', 'MSG', 'PPTX', //
    'PPT', 'XML', 'EPUB',
  ],
  'audio': ['MP3', 'M4A', 'WAV', 'AMR', 'MPGA'],
  'video': ['MP4', 'MOV', 'MPEG', 'WEBM'],
};

/// `VAR_REGEX` (web/config): a workflow variable reference.
final varRegex = RegExp(r'\{\{(#[\w-]{1,50}(\.\d+)?(\.[a-z_]\w{0,29}){1,10}#)\}\}', caseSensitive: false);

/// variable-value-block/utils.ts `getHashtagRegexString`.
final variableValueRegex = RegExp(r'\{\{[a-zA-Z_][a-zA-Z0-9_]{0,29}\}\}', caseSensitive: false);

// ---- blocks ------------------------------------------------------------------------------------------------------

/// The inline blocks (Lexical decorator nodes) of the prompt editor, in the order their transforms are registered
/// (prompt-editor-content.tsx).
enum PromptBlockKind {
  context(contextPlaceholderText),
  query(queryPlaceholderText),
  history(historyPlaceholderText),
  workflowVariable(null),
  current(currentPlaceholderText),
  requestUrl(requestUrlPlaceholderText),
  errorMessage(errorMessagePlaceholderText),
  lastRun(lastRunPlaceholderText),

  /// Not a Dify block: a character of the prompt that the editor uses internally to mark blocks, kept as text.
  literal(null);

  const PromptBlockKind(this.placeholder);
  final String? placeholder;
}

/// One inline block: its kind and, for a workflow variable, the value selector.
final class PromptBlock {
  const PromptBlock(this.kind, [this.variables = const []]) : _char = null;
  const PromptBlock.variable(this.variables) : kind = PromptBlockKind.workflowVariable, _char = null;
  const PromptBlock.literal(String char) : kind = PromptBlockKind.literal, variables = const [], _char = char;

  final PromptBlockKind kind;
  final List<String> variables;
  final String? _char;

  /// The block's text in the prompt (Lexical's `getTextContent`).
  String get text => switch (kind) {
    PromptBlockKind.workflowVariable => '{{#${variables.join('.')}#}}',
    PromptBlockKind.literal => _char!,
    _ => kind.placeholder!,
  };

  @override
  bool operator ==(Object other) => other is PromptBlock && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'PromptBlock($text)';
}

/// Which blocks the editor turns tokens into (the `show` of each `*Block` prop; the workflow variable block also
/// covers env / conversation / rag / sys references) and whether `{{name}}` is highlighted
/// (`variableBlock.show || externalToolBlock.show || isSupportFileVar`).
final class PromptBlockSet {
  const PromptBlockSet(this.kinds, {this.variableValue = false});
  static const none = PromptBlockSet({});

  final Set<PromptBlockKind> kinds;
  final bool variableValue;

  @override
  bool operator ==(Object other) =>
      other is PromptBlockSet &&
      other.variableValue == variableValue &&
      other.kinds.length == kinds.length &&
      other.kinds.containsAll(kinds);

  @override
  int get hashCode => Object.hash(variableValue, Object.hashAllUnordered(kinds));
}

/// A matched range.
typedef TextMatch = ({int start, int end});

TextMatch? _first(RegExp re, String text) {
  final m = re.firstMatch(text);
  return m == null ? null : (start: m.start, end: m.end);
}

final _placeholderPatterns = {
  for (final k in PromptBlockKind.values)
    if (k.placeholder != null) k: RegExp(RegExp.escape(k.placeholder!)),
};

/// One run of `decoratorTransform` (utils.ts) for [kind] over a text node: the pieces it splits [text] into, or null
/// when it leaves the node alone. The special placeholders use a plain RegExp, so a match followed directly by
/// another stops the run; VAR_REGEX is global, and its `lastIndex` makes that check never fire.
List<Object>? _decorate(PromptBlockKind kind, String text) {
  final global = kind == PromptBlockKind.workflowVariable;
  final re = global ? varRegex : _placeholderPatterns[kind]!;
  final out = <Object>[];
  var rest = text;
  while (true) {
    final m = _first(re, rest);
    final next = m == null ? '' : rest.substring(m.end);
    if (next.isNotEmpty && !global && _first(re, next)?.start == 0) break;
    if (m == null) break;
    if (m.start > 0) out.add(rest.substring(0, m.start));
    final token = rest.substring(m.start, m.end);
    out.add(global ? PromptBlock.variable(token.substring(3, token.length - 3).split('.')) : PromptBlock(kind));
    rest = next;
  }
  if (out.isEmpty) return null;
  if (rest.isNotEmpty) out.add(rest);
  return out;
}

/// The transforms of every enabled kind run over [text] (one text node) until nothing changes, as Lexical runs node
/// transforms on dirty nodes: pieces split off are new nodes and are transformed again.
List<Object> transformText(String text, PromptBlockSet blocks) {
  final kinds = [
    for (final k in PromptBlockKind.values)
      if (blocks.kinds.contains(k) && k != PromptBlockKind.literal) k,
  ];
  if (kinds.isEmpty || text.isEmpty) return [if (text.isNotEmpty) text];
  List<Object> run(String t) {
    for (final k in kinds) {
      final pieces = _decorate(k, t);
      if (pieces == null) continue;
      return [
        for (final p in pieces)
          if (p is String && p != t) ...run(p) else p,
      ];
    }
    return [t];
  }

  return run(text);
}

/// Parses a prompt (Dify's `textToEditorState` and the replacement transforms): one paragraph per line, each a run
/// of text and blocks. Lines are separated by `'\n'` strings.
List<Object> parsePrompt(String text, PromptBlockSet blocks) {
  final lines = text.split('\n');
  return [
    for (final (i, line) in lines.indexed) ...[if (i > 0) '\n', ...transformText(line, blocks)],
  ];
}

/// The `{{name}}` ranges of one text node that Dify highlights (`registerLexicalTextEntity` on a fresh node: a match
/// followed directly by another stops the run).
List<TextMatch> variableValueRanges(String text) {
  final out = <TextMatch>[];
  var offset = 0;
  var rest = text;
  while (true) {
    final m = _first(variableValueRegex, rest);
    final next = m == null ? '' : rest.substring(m.end);
    if (next.isNotEmpty && _first(variableValueRegex, next)?.start == 0) break;
    if (m == null) break;
    out.add((start: offset + m.start, end: offset + m.end));
    offset += m.end;
    rest = next;
  }
  return out;
}

// ---- typeahead (hooks.ts useBasicTypeaheadTriggerMatch) ------------------------------------------------------------

/// `MenuTextMatch`.
typedef MenuTextMatch = ({int leadOffset, String matchingString, String replaceableString});

/// `useBasicTypeaheadTriggerMatch(trigger, …)` applied to the text before the caret.
MenuTextMatch? basicTypeaheadTriggerMatch(
  String trigger,
  String text, {
  int minLength = 1,
  int maxLength = 75,
  bool requireTriggerBoundary = false,
}) {
  final t = trigger.replaceAllMapped(RegExp(r'[[\]\\^-]'), (m) => '\\${m[0]}');
  final valid = '[^$t\\n\\r]';
  final prefix = requireTriggerBoundary ? r'(^|\s)' : '(.*)';
  final m = RegExp('$prefix([$t]((?:$valid){0,$maxLength}))\$').firstMatch(text);
  if (m == null || m[3]!.length < minLength) return null;
  return (leadOffset: m.start + m[1]!.length, matchingString: m[3]!, replaceableString: m[2]!);
}

/// The component picker's trigger (component-picker-block/index.tsx): `/` only after whitespace or at the start,
/// `{` anywhere; no minimum query length.
MenuTextMatch? pickerTriggerMatch(String trigger, String text) =>
    basicTypeaheadTriggerMatch(trigger, text, minLength: 0, requireTriggerBoundary: trigger == '/');
