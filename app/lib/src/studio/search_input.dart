/// base/search-input (`SearchInput`) and its search-state helpers: an InputGroup with the search icon in front and,
/// once there is text (and it is enabled), a clear button that empties it and keeps the focus in the field. IME
/// composition is Flutter's text input's own business (the composing range is part of the editing value).
library;

import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/widgets.dart';
import '../i18n/dify_i18n.dart';
import '../workflow_editor/panel_fields/controls.dart' show DifyInput;

String _c(String key) => DifyI18n.tr('common', key);

class SearchInput extends StatefulWidget {
  const SearchInput({
    super.key,
    required this.value,
    required this.onValueChange,
    this.placeholder,
    this.semanticLabel,
    this.description,
    this.disabled = false,
    this.autofocus = false,
    this.focusNode,
    this.width,
  });

  final String value;
  final ValueChanged<String> onValueChange;

  /// `common.operation.search` by default, as the accessible name.
  final String? placeholder, semanticLabel;

  /// `aria-describedby`'s text.
  final String? description;
  final bool disabled, autofocus;

  /// The field's focus node (Dify's `ref` to the input).
  final FocusNode? focusNode;

  /// A call site's width (`w-50` in the Studio).
  final double? width;

  @override
  State<SearchInput> createState() => _SearchInputState();
}

class _SearchInputState extends State<SearchInput> {
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode(debugLabel: 'SearchInput'));

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _focus.requestFocus() : null);
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  void _clear() {
    widget.onValueChange('');
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    Widget field = DifyInput(
      value: widget.value,
      focusNode: _focus,
      height: 32,
      disabled: widget.disabled,
      placeholder: widget.placeholder ?? _c('operation.search'),
      semanticLabel: widget.semanticLabel ?? _c('operation.search'),
      onChanged: widget.onValueChange,
      textInputAction: TextInputAction.search,
      focusInteractiveAddons: false,
      leading: Padding(
        padding: const EdgeInsets.only(left: 7, right: 5),
        child: RemixIcon('search-line', size: 16, color: DifyColors.componentsInputTextPlaceholder),
      ),
      trailing: widget.value.isEmpty || widget.disabled
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 3, right: 5),
              child: DifyIconButton(
                key: const ValueKey('search-input-clear'),
                label: _c('operation.clear'),
                size: DifyIconButtonSize.sm,
                icon: RemixIcon('close-circle-fill', size: 16, color: DifyColors.textQuaternary),
                onPressed: _clear,
              ),
            ),
    );
    if (widget.description != null) field = Semantics(hint: widget.description, child: field);
    return widget.width == null ? field : SizedBox(width: widget.width, child: field);
  }
}

/// search-state.ts `hasSearchText`.
bool hasSearchText([String? searchText]) => searchText?.trim().isNotEmpty ?? false;

/// search-state.ts `isSearchResultEmpty`: a filter (the search text unless [hasActiveFilter] says) narrowed existing
/// data down to nothing; loading and a truly empty source are not.
bool isSearchResultEmpty({
  bool? hasActiveFilter,
  required bool isLoading,
  required int resultCount,
  String? searchText,
  required int sourceCount,
}) {
  final filtering = hasActiveFilter ?? hasSearchText(searchText);
  return !isLoading && sourceCount > 0 && resultCount == 0 && filtering;
}
