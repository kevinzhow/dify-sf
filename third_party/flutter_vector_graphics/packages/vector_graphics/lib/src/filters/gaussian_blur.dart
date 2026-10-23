// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
// Local extension: see flutter_vector_graphics/PATCHES.md.

import 'dart:ui';

import 'package:vector_graphics_codec/vector_graphics_codec.dart';

import 'filter_context.dart';

/// SVG Gaussian blur: independent deviations in primitive coordinates, in the declared color space.
FilterImage gaussianBlur(FilterContext context, VectorFilter primitive) {
  final FilterImage input = context.input(primitive.attributes['in']);
  final List<double> values = FilterContext.numbers(
    primitive.attributes['stdDeviation'] ?? '0',
  );
  if (values.isEmpty ||
      values.length > 2 ||
      values.any((double value) => value < 0)) {
    throw const FormatException('Invalid feGaussianBlur stdDeviation');
  }
  final double sigmaX = context.primitiveNumber(
    '${values.first}',
    horizontal: true,
  );
  final double sigmaY = context.primitiveNumber(
    '${values.length == 1 ? values.first : values.last}',
    horizontal: false,
  );
  final Rect bounds = context.subregion(primitive, input.region);
  return context.record(bounds, (Canvas canvas) {
    if (sigmaX == 0 && sigmaY == 0) {
      context.draw(canvas, input);
      return;
    }
    canvas.saveLayer(
      bounds,
      Paint()
        ..imageFilter = context.inColorSpace(
          primitive,
          ImageFilter.blur(
            sigmaX: sigmaX,
            sigmaY: sigmaY,
            tileMode: TileMode.decal,
          ),
        ),
    );
    context.draw(canvas, input);
    canvas.restore();
  });
}
