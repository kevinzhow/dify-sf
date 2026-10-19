// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// Local extension: see flutter_vector_graphics/PATCHES.md.

import 'dart:ui';

import 'package:vector_graphics_codec/vector_graphics_codec.dart';

import 'filter_context.dart';

/// SVG feComposite's Porter-Duff operators. Arithmetic is outside the current extension's scope.
FilterImage composite(FilterContext context, VectorFilter primitive) {
  final FilterImage input = context.input(primitive.attributes['in']);
  final FilterImage background = context.input(
    primitive.attributes['in2'] ?? 'SourceGraphic',
  );
  final BlendMode mode = switch (primitive.attributes['operator'] ?? 'over') {
    'over' => BlendMode.srcOver,
    'in' => BlendMode.srcIn,
    'out' => BlendMode.srcOut,
    'atop' => BlendMode.srcATop,
    'xor' => BlendMode.xor,
    'lighter' => BlendMode.plus,
    final String value => throw UnsupportedError(
      'SVG composite operator $value is not implemented',
    ),
  };
  return context.recordColor(
    primitive,
    context.subregion(
      primitive,
      input.region.expandToInclude(background.region),
    ),
    (Canvas canvas, bool linear) {
      context.drawInput(canvas, background, linear);
      context.drawInput(canvas, input, linear, mode: mode);
    },
  );
}
