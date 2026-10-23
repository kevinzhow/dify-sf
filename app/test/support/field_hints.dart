import 'package:flutter/material.dart';
import 'package:dify_sf_app/src/design/widgets/text_line.dart';

/// Locate the rendered hint after the design system switched from Material's
/// unstrutted hintText to a typography-controlled hint widget. Test fixtures
/// that still use a plain Material TextField remain supported.
String? hintTextOf(TextField field) {
  final decoration = field.decoration;
  if (decoration?.hintText != null) return decoration!.hintText;
  return switch (decoration?.hint) {
    DifyTextLine(:final data) => data,
    Text(:final data) => data,
    _ => null,
  };
}
