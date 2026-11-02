/// dify-sf's phone layout tokens.
///
/// Dify 1.17.1 has no phone layout (its console and workflow editor need a desktop width), so the phone chrome is a
/// deliberate dify-sf divergence. Its sizes come from the approved phone mockups (mobile151/mockups/gen.py,
/// 2026-11-02). Colours, shadows and radii stay Dify tokens; only the type sizes Dify's scale lacks are added here.
library;

import 'package:flutter/painting.dart';

import 'dify_tokens.g.dart';

/// Phone type styles that Dify's utilities do not have. Use them through `difyTextStyle` / `DifyText` like
/// [DifyType]; everything else on a phone uses [DifyType] (subtitles `system-xs-regular`, navigation labels
/// `system-xs-regular` / `system-xs-semibold`, rows `body-lg-regular`, selection titles `system-md-semibold`).
abstract final class DifyPhoneType {
  /// App bar and sheet titles (gen.py `.appbar .title b`: 17 px, 600).
  static const title = DifyTextStyle(
    TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      height: 22 / 17,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// A top-level page's large title (mockup 1 "Studio": 22 px, 600).
  static const largeTitle = DifyTextStyle(
    TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      height: 28 / 22,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// Bottom toolbar and selection bar labels (gen.py `.tb`: 11 px).
  static const toolbarLabel = DifyTextStyle(
    TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w400,
      height: 14 / 11,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// The extended FAB's label and the action sheet's Cancel (mockup 1 "Create": 15 px, 600).
  static const labelStrong = DifyTextStyle(
    TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      height: 20 / 15,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );
}
