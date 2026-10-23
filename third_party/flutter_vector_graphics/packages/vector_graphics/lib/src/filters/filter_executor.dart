// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:ui';

import 'package:vector_graphics_codec/vector_graphics_codec.dart';

import 'color_matrix.dart';
import 'gaussian_blur.dart';
import 'blend.dart';
import 'composite.dart';
import 'filter_context.dart';
import 'flood.dart';
import 'merge.dart';
import 'offset.dart';

/// Evaluates the contributing graph in document order, preserving named results.
FilterImage executeFilter(FilterContext context) {
  if (context.region.isEmpty || context.definition.children.isEmpty) {
    return context.record(Rect.zero, (Canvas canvas) {});
  }
  // These four operators belong to the explicitly deferred effects group. Preserve the prior renderer's
  // unfiltered graphic for the whole effect graph, rather than producing an empty icon or an invalid partial DAG.
  const deferred = <String>{
    'feMorphology',
    'feTurbulence',
    'feDisplacementMap',
    'feComponentTransfer',
  };
  if (context.definition.activePrimitives.any(
    (VectorFilter p) => deferred.contains(p.name),
  )) {
    return context.sourceGraphic;
  }
  for (final VectorFilter primitive in context.definition.activePrimitives) {
    context.publish(primitive, executePrimitive(context, primitive));
  }
  return context.previous;
}

/// Dispatches one primitive. Each supported operation has a separate implementation.
FilterImage executePrimitive(FilterContext context, VectorFilter primitive) {
  switch (primitive.name) {
    case 'feGaussianBlur':
      return gaussianBlur(context, primitive);
    case 'feBlend':
      return blend(context, primitive);
    case 'feComposite':
      return composite(context, primitive);
    case 'feOffset':
      return offset(context, primitive);
    case 'feColorMatrix':
      return colorMatrix(context, primitive);
    case 'feFlood':
      return flood(context, primitive);
    case 'feMerge':
      return merge(context, primitive);
    default:
      throw UnsupportedError(
        'SVG filter primitive ${primitive.name} is not implemented',
      );
  }
}
