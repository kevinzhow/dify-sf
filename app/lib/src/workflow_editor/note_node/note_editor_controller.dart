import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../../cards/bodies/note_text.dart';

/// note-editor/store.ts: what the toolbar shows about the selection, and the link popup's state. The popup's anchor
/// ([linkAnchor], Dify's `linkAnchorElement`) is the range of the link it is for; a link's key is where it starts.
class NoteEditorStore extends ChangeNotifier {
  NoteEditorStore({this.resolveAnchor});

  /// The anchor for `setLinkAnchor(true)`: the link around the selection (Dify reads the DOM selection's parent).
  TextRange? Function()? resolveAnchor;

  TextRange? linkAnchor;
  int? dismissedLinkKey;
  bool linkOperatorShow = false;
  bool selectedIsBold = false, selectedIsItalic = false, selectedIsStrikeThrough = false;
  bool selectedIsLink = false, selectedIsBullet = false;
  String selectedLinkUrl = '';
  int? selectedLinkKey;

  Timer? _pendingAnchor;

  void _set(void Function() change) {
    change();
    notifyListeners();
  }

  /// Closes the popup and keeps it closed for this link until it is explicitly reopened.
  void dismissLinkEditor() {
    _pendingAnchor?.cancel();
    _set(() {
      linkAnchor = null;
      linkOperatorShow = false;
      dismissedLinkKey = selectedLinkKey;
    });
  }

  /// A range anchors the popup there; true anchors it, after the current update, to the link at the selection;
  /// null or false closes it.
  void setLinkAnchor(Object? open) {
    _pendingAnchor?.cancel();
    if (open is TextRange) {
      return _set(() {
        linkAnchor = open;
        dismissedLinkKey = null;
      });
    }
    if (open == true) {
      dismissedLinkKey = null;
      _pendingAnchor = Timer(Duration.zero, () {
        final at = resolveAnchor?.call();
        if (at != null) _set(() => linkAnchor = at);
      });
      return;
    }
    _set(() {
      linkAnchor = null;
      dismissedLinkKey = null;
    });
  }

  void setLinkOperatorShow(bool v) => _set(() => linkOperatorShow = v);
  void setSelectedIsBold(bool v) => _set(() => selectedIsBold = v);
  void setSelectedIsItalic(bool v) => _set(() => selectedIsItalic = v);
  void setSelectedIsStrikeThrough(bool v) => _set(() => selectedIsStrikeThrough = v);
  void setSelectedLinkUrl(String v) => _set(() => selectedLinkUrl = v);
  void setSelectedIsLink(bool v) => _set(() => selectedIsLink = v);
  void setSelectedIsBullet(bool v) => _set(() => selectedIsBullet = v);
  void setSelectedLinkKey(int? v) => _set(() {
    selectedLinkKey = v;
    if (v != dismissedLinkKey) dismissedLinkKey = null;
  });

  @override
  void dispose() {
    _pendingAnchor?.cancel();
    super.dispose();
  }
}

/// note-editor/utils.ts urlRegExp.
final noteUrlRegExp = RegExp(
  r'((([A-Za-z]{3,9}:(?:\/\/)?)(?:[-;:&=+$,\w]+@)?[A-Za-z0-9.-]+|(?:www.|[-;:&=+$,\w]+@)[A-Za-z0-9.-]+)((?:\/[+~%/.\w-]*)?\??[-+=&;%@.\w]*#?\w*)?)',
);

/// es-toolkit `escape`: the HTML entities of `&<>"'`.
String escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

/// The note editor's state (Dify's Lexical editor with its rich text, link, list and history plugins): the text with
/// one style per character ([NoteText]), the commands of the toolbar (format, font size, link, bullet list), and the
/// [store] the toolbar and link popup read, kept up to date with the selection (format-detector-plugin, and the
/// link-editor-plugin's `useOpenLink`).
///
/// Typing inherits the style of the text before the caret (the toggled style at a collapsed selection, Lexical's
/// selection format), never a link's URL at the link's edges. Enter in a list item starts another one; Enter in an
/// empty one, or Backspace at its start, turns it into a paragraph.
class NoteEditorController extends TextEditingController {
  NoteEditorController({String value = '', this.editable = true, this.openUrl, this.onInvalidUrl}) {
    store.resolveAnchor = _anchorAtSelection;
    load(value);
  }

  final store = NoteEditorStore();
  bool editable;

  /// Opens a link in a browser (Cmd/Ctrl + click, Open).
  void Function(String url)? openUrl;

  /// `toast.error(invalidUrl)`.
  VoidCallback? onInvalidUrl;

  List<NoteStyle> _styles = [];
  NoteStyle? _typing;
  Timer? _openLink;

  /// Bumped on every change of the content (text or styles), not of the selection.
  int revision = 0;

  NoteText get note => NoteText(text, List.unmodifiable(_styles));

  /// The style of each character.
  List<NoteStyle> get styles => List.unmodifiable(_styles);

  /// Replaces the content with Dify's [value] (NoteEditorContentSynchronizer); malformed values are an empty note.
  void load(String value) {
    final t = NoteText.fromLexical(value);
    _styles = [...t.styles];
    _typing = null;
    revision++;
    super.value = TextEditingValue(
      text: t.text,
      selection: TextSelection.collapsed(offset: t.text.length),
    );
    _detect();
  }

  static bool _structural(int c) => c == 0x0A || c == 0xE000;
  bool _isBulletAt(String t, int i) => i >= 0 && i < t.length && t.codeUnitAt(i) == 0xE000;
  int _lineStart(String t, int i) => i <= 0 ? 0 : t.lastIndexOf('\n', i - 1) + 1;

  @override
  set value(TextEditingValue v) {
    final old = super.value;
    if (v.text != old.text) {
      v = _edit(old, v);
      revision++;
    }
    v = v.copyWith(selection: _fixCaret(v.text, v.selection, old.selection));
    final changed = v.selection != old.selection || v.text != old.text;
    if (changed) _typing = null;
    super.value = v;
    _detect();
    // An update of the content or the selection (not focus or composing alone).
    if (changed) _scheduleOpenLink();
  }

  /// The edit from [old] to [v] (any change: typing, IME, paste, delete, undo) applied to the styles, with the list
  /// markers kept at the starts of their lines.
  TextEditingValue _edit(TextEditingValue old, TextEditingValue v) {
    final a = old.text, b = v.text;
    var p = 0;
    final most = min(a.length, b.length);
    while (p < most && a.codeUnitAt(p) == b.codeUnitAt(p)) {
      p++;
    }
    // Where the old selection began is where the edit began, when the text around it repeats.
    if (old.selection.isValid) p = min(p, old.selection.start);
    var s = 0;
    while (s < a.length - p && s < b.length - p && a.codeUnitAt(a.length - 1 - s) == b.codeUnitAt(b.length - 1 - s)) {
      s++;
    }
    final removedEnd = a.length - s;
    var ins = b.substring(p, b.length - s).replaceAll(noteBullet, '');
    final line = _lineStart(a, p);
    final bullet = _isBulletAt(a, line);
    // Enter in an empty list item leaves the list.
    if (ins == '\n' && removedEnd == p && bullet && p == line + 1 && (p == a.length || a.codeUnitAt(p) == 0x0A)) {
      _styles.removeAt(line);
      return TextEditingValue(
        text: a.replaceRange(line, p, ''),
        selection: TextSelection.collapsed(offset: line),
      );
    }
    if (bullet) ins = ins.replaceAll('\n', '\n$noteBullet');
    final style = _typing ?? _inherit(a, p, removedEnd);
    final inserted = [
      for (var i = 0; i < ins.length; i++) _structural(ins.codeUnitAt(i)) ? NoteStyle.plain : style,
    ];
    var text = a.replaceRange(p, removedEnd, ins);
    _styles.replaceRange(p, removedEnd, inserted);
    final end = p + ins.length;
    int map(int o) => o <= p ? o : (o >= b.length - s ? o - (b.length - s) + end : end);
    var base = map(v.selection.baseOffset), extent = map(v.selection.extentOffset);
    // A marker that is no longer at a line's start (its line break was deleted) goes.
    for (var i = text.length - 1; i > 0; i--) {
      if (text.codeUnitAt(i) == 0xE000 && text.codeUnitAt(i - 1) != 0x0A) {
        text = text.replaceRange(i, i + 1, '');
        _styles.removeAt(i);
        if (base > i) base--;
        if (extent > i) extent--;
      }
    }
    return TextEditingValue(
      text: text,
      selection: v.selection.isValid ? TextSelection(baseOffset: base, extentOffset: extent) : v.selection,
      composing: v.composing.isValid && v.composing.end <= text.length ? v.composing : TextRange.empty,
    );
  }

  /// The style typed text takes: the text before it (its link only inside the link), else the text after it.
  NoteStyle _inherit(String a, int p, int removedEnd) {
    final before = p > 0 && !_structural(a.codeUnitAt(p - 1)) ? _styles[p - 1] : null;
    final after = removedEnd < a.length && !_structural(a.codeUnitAt(removedEnd)) ? _styles[removedEnd] : null;
    final s = before ?? after ?? NoteStyle.plain;
    return before?.url != null && before?.url == after?.url ? s : s.withUrl(null);
  }

  /// A caret never sits in front of a list marker: it goes past it, or to the line above when moving left.
  TextSelection _fixCaret(String t, TextSelection sel, TextSelection old) {
    if (!sel.isValid || !sel.isCollapsed) return sel;
    final o = sel.baseOffset;
    if (!_isBulletAt(t, o) || _lineStart(t, o) != o) return sel;
    final left = old.isValid && old.isCollapsed && old.baseOffset == o + 1 && o > 0;
    return TextSelection.collapsed(offset: left ? o - 1 : o + 1);
  }

  void _restyle() {
    revision++;
    notifyListeners();
    _detect();
    _scheduleOpenLink();
  }

  // ----- the selection -----

  /// The style at the caret (the text before it on its line, else after it) or of the selection's first character.
  NoteStyle get selectionStyle {
    final sel = selection;
    if (!sel.isValid) return NoteStyle.plain;
    if (sel.isCollapsed) {
      final o = sel.baseOffset;
      if (_typing != null) return _typing!;
      if (o > 0 && !_structural(text.codeUnitAt(o - 1))) return _styles[o - 1];
      if (o < text.length && !_structural(text.codeUnitAt(o))) return _styles[o];
      return NoteStyle.plain;
    }
    for (var i = sel.start; i < sel.end; i++) {
      if (!_structural(text.codeUnitAt(i))) return _styles[i];
    }
    return NoteStyle.plain;
  }

  /// The link around [o] (Lexical's selection is in a link when the text before the caret is, or at the start of
  /// its line the text after it).
  TextRange? linkAt(int o) {
    int? i;
    if (o > 0 && o <= text.length && _styles[o - 1].url != null && !_structural(text.codeUnitAt(o - 1))) {
      i = o - 1;
    } else if (o < text.length &&
        _styles[o].url != null &&
        !_structural(text.codeUnitAt(o)) &&
        (o == 0 || _structural(text.codeUnitAt(o - 1)))) {
      i = o;
    }
    if (i == null) return null;
    final url = _styles[i].url;
    var s = i, e = i + 1;
    while (s > 0 && _styles[s - 1].url == url && !_structural(text.codeUnitAt(s - 1))) {
      s--;
    }
    while (e < text.length && _styles[e].url == url && !_structural(text.codeUnitAt(e))) {
      e++;
    }
    return TextRange(start: s, end: e);
  }

  TextRange? get _selectedLink {
    final sel = selection;
    if (!sel.isValid) return null;
    return linkAt(sel.isCollapsed ? sel.baseOffset : sel.start + 1);
  }

  /// The lines the selection touches: (start, end) of each.
  List<(int, int)> get _selectedLines {
    final sel = selection;
    final out = <(int, int)>[];
    var s = _lineStart(text, sel.start);
    while (true) {
      var e = text.indexOf('\n', s);
      if (e < 0) e = text.length;
      out.add((s, e));
      if (e >= sel.end || e == text.length) break;
      s = e + 1;
    }
    return out;
  }

  TextRange? _anchorAtSelection() {
    final sel = selection;
    if (!sel.isValid) return null;
    return _selectedLink ?? TextRange(start: sel.start, end: sel.end);
  }

  /// format-detector-plugin: the selection's format, link and list state into the store (not while composing).
  void _detect() {
    if (value.composing.isValid || !selection.isValid) return;
    final s = selectionStyle;
    final link = _selectedLink;
    final st = store
      ..selectedIsBold = s.has(NoteFormat.bold)
      ..selectedIsItalic = s.has(NoteFormat.italic)
      ..selectedIsStrikeThrough = s.has(NoteFormat.strikethrough)
      ..selectedLinkUrl = link == null ? '' : _styles[link.start].url!
      ..selectedIsLink = link != null
      ..selectedIsBullet = _isBulletAt(text, _lineStart(text, selection.start));
    final key = link?.start;
    if (key != st.selectedLinkKey) {
      st.selectedLinkKey = key;
      if (key != st.dismissedLinkKey) st.dismissedLinkKey = null;
    }
    st.notifyListeners();
  }

  /// link-editor-plugin `useOpenLink`, after each update: the popup follows the selection into and out of links
  /// (a dismissed one stays closed), showing the link's actions when it has a URL and the URL input otherwise.
  void _scheduleOpenLink() {
    _openLink?.cancel();
    _openLink = Timer(Duration.zero, () {
      final s = store;
      if (s.selectedIsLink) {
        if (s.dismissedLinkKey != null && s.dismissedLinkKey == s.selectedLinkKey) return;
        s
          ..setLinkAnchor(true)
          ..setLinkOperatorShow(s.selectedLinkUrl.isNotEmpty);
      } else {
        s
          ..setLinkAnchor(null)
          ..setLinkOperatorShow(false);
      }
    });
  }

  /// `CLICK_COMMAND`: Cmd/Ctrl + click opens the link at the selection; a click in a link shows its actions, even
  /// after they were dismissed.
  void handleClick({bool meta = false}) => Timer(Duration.zero, () {
    final s = store;
    final link = _selectedLink;
    if (link == null) return;
    if (meta) {
      if (s.selectedLinkUrl.isNotEmpty) openUrl?.call(s.selectedLinkUrl);
      return;
    }
    s
      ..setLinkAnchor(link)
      ..setLinkOperatorShow(s.selectedLinkUrl.isNotEmpty);
  });

  // ----- commands (toolbar/hooks.ts useCommand, useFontSize; link-editor-plugin useLink) -----

  /// `FORMAT_TEXT_COMMAND`: toggles [flag] on the selected text, or for what is typed next at a caret.
  void formatText(int flag) {
    final sel = selection;
    if (!sel.isValid) return;
    final on = !selectionStyle.has(flag);
    if (sel.isCollapsed) {
      _typing = selectionStyle.withFormat(flag, on);
      _detect();
      notifyListeners();
      return;
    }
    _restyleRange(sel.start, sel.end, (s) => s.withFormat(flag, on));
  }

  void _restyleRange(int start, int end, NoteStyle Function(NoteStyle) f) {
    for (var i = start; i < end; i++) {
      if (!_structural(text.codeUnitAt(i))) _styles[i] = f(_styles[i]);
    }
    _restyle();
  }

  /// The selection's font size (`$getSelectionStyleValueForProperty(selection, 'font-size', '12px')`): '' when the
  /// selected text has several.
  String get fontSize {
    final sel = selection;
    if (!sel.isValid) return '12px';
    if (sel.isCollapsed) return selectionStyle.fontSize ?? '12px';
    String? found;
    var any = false;
    for (var i = sel.start; i < sel.end; i++) {
      if (_structural(text.codeUnitAt(i))) continue;
      final v = _styles[i].fontSize ?? '12px';
      if (any && v != found) return '';
      (found, any) = (v, true);
    }
    return found ?? '12px';
  }

  /// `$patchStyleText(selection, {'font-size': size})`.
  void setFontSize(String size) {
    final sel = selection;
    if (!sel.isValid) return;
    if (sel.isCollapsed) {
      _typing = selectionStyle.withFontSize(size);
      notifyListeners();
      return;
    }
    _restyleRange(sel.start, sel.end, (s) => s.withFontSize(size));
  }

  /// The toolbar's Link: removes the link at the selection; else makes the selected text a link without a URL yet
  /// and opens the URL input (Lexical leaves a collapsed selection alone).
  void toggleLink() {
    final sel = selection;
    if (!sel.isValid) return;
    if (store.selectedIsLink) {
      _setUrl(null);
      store.setLinkAnchor(null);
      return;
    }
    if (sel.isCollapsed) return;
    _restyleRange(sel.start, sel.end, (s) => s.withUrl(''));
    store.setLinkAnchor(true);
  }

  /// `TOGGLE_LINK_COMMAND` with [url] (null unlinks): the link at the selection, else the selected text.
  void _setUrl(String? url) {
    final sel = selection;
    if (!sel.isValid) return;
    final link = _selectedLink ?? store.linkAnchor;
    final r = link ?? TextRange(start: sel.start, end: sel.end);
    if (r.isCollapsed) return;
    _restyleRange(r.start, r.end, (s) => s.withUrl(url));
  }

  /// useLink handleSaveLink: an invalid URL is refused (onInvalidUrl); a valid one is set, escaped, and the popup
  /// closes.
  void saveLink(String url) {
    if (url.isNotEmpty && !noteUrlRegExp.hasMatch(url)) {
      onInvalidUrl?.call();
      return;
    }
    _setUrl(escapeHtml(url));
    store.setLinkAnchor(null);
  }

  /// useLink handleUnlink.
  void unlink() {
    _setUrl(null);
    store.setLinkAnchor(null);
  }

  /// The toolbar's Bullet List: the selected lines become list items, or paragraphs when the selection is in a list.
  void toggleBullet() {
    final sel = selection;
    if (!sel.isValid) return;
    final lines = _selectedLines;
    final makeList = !store.selectedIsBullet;
    var t = text;
    var base = sel.baseOffset, extent = sel.extentOffset;
    for (final (s, _) in lines.reversed) {
      final has = _isBulletAt(t, s);
      if (makeList == has) continue;
      if (makeList) {
        t = t.replaceRange(s, s, noteBullet);
        _styles.insert(s, NoteStyle.plain);
        if (base >= s) base++;
        if (extent >= s) extent++;
      } else {
        t = t.replaceRange(s, s + 1, '');
        _styles.removeAt(s);
        if (base > s) base--;
        if (extent > s) extent--;
      }
    }
    revision++;
    super.value = TextEditingValue(
      text: t,
      selection: _fixCaret(
        t,
        TextSelection(baseOffset: base, extentOffset: extent),
        TextSelection.collapsed(offset: -1),
      ),
    );
    _detect();
    _scheduleOpenLink();
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) => TextSpan(
    style: style,
    children: [
      noteTextSpan(note, composing: withComposing && value.isComposingRangeValid ? value.composing : TextRange.empty),
    ],
  );

  @override
  void dispose() {
    _openLink?.cancel();
    store.dispose();
    super.dispose();
  }
}
