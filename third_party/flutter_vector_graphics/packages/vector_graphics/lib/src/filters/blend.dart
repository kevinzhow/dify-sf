// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// Local extension: see flutter_vector_graphics/PATCHES.md.

import 'dart:ui';

import 'package:vector_graphics_codec/vector_graphics_codec.dart';

import 'filter_context.dart';

/// SVG feBlend composites the first input over the second in the chosen color space.
FilterImage blend(FilterContext context, VectorFilter primitive) {
  final FilterImage input = context.input(primitive.attributes['in']);
  FilterImage background = context.input(
    primitive.attributes['in2'] ?? 'SourceGraphic',
  );
  final BlendMode mode = switch (primitive.attributes['mode'] ?? 'normal') {
    'normal' => BlendMode.srcOver,
    'multiply' => BlendMode.multiply,
    'screen' => BlendMode.screen,
    'darken' => BlendMode.darken,
    'lighten' => BlendMode.lighten,
    'overlay' => BlendMode.overlay,
    'color-dodge' => BlendMode.colorDodge,
    'color-burn' => BlendMode.colorBurn,
    'hard-light' => BlendMode.hardLight,
    'soft-light' => BlendMode.softLight,
    'difference' => BlendMode.difference,
    'exclusion' => BlendMode.exclusion,
    'hue' => BlendMode.hue,
    'saturation' => BlendMode.saturation,
    'color' => BlendMode.color,
    'luminosity' => BlendMode.luminosity,
    final String value => throw UnsupportedError(
      'SVG blend mode $value is not implemented',
    ),
  };
  // Materialize the repeated effect branch before the final composition. If
  // the foreground is SourceGraphic, flattening the whole blend instead would
  // resample otherwise sharp vector edges at fractional display positions.
  if (input.replayCost + background.replayCost >
          FilterContext.maxPictureReplays &&
      !context.isSource(background) &&
      !background.region.isEmpty) {
    background = context.raster(background, background.region);
  }
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
    // Skia's hard clip rounds half-pixel boundaries inward. Keep one subpixel
    // of coverage fringe; AA clipping here would multiply the foreground's
    // existing edge coverage again on CanvasKit.
    clipOutset: 1 / (256 * context.rasterScale),
  );
}
