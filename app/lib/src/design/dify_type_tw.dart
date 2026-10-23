// Text styles Dify writes with Tailwind's font-size / line-height classes (`text-xs leading-[18px]`, `text-[13px]`)
// instead of a typography utility (DifyType, generated from packages/dify-ui/src/styles/utilities.css). Same shape as
// DifyType (use with difyTextStyle / DifyText); half-leading like CSS (TextLeadingDistribution.even). Each constant
// is named after its Tailwind classes: text<size>[<weight>][Leading<px>] (`text-[13px] font-medium leading-4` =
// text13MediumLeading16); a constant without a weight or a line height inherits it, like the Tailwind classes.
import 'package:flutter/painting.dart';

import 'dify_tokens.g.dart';

/// Tailwind font-size (`text-xs` 12/16, `text-sm` 14/20, `text-[13px]` …) + line-height (`leading-[18px]`, `leading-5`)
/// + weight (`font-medium` …) combinations Dify uses outside its typography utilities.
abstract final class DifyTw {
  /// CSS `letter-spacing: normal` (the application reset); keep all other text properties inherited.
  static const trackingNormal = DifyTextStyle(TextStyle(letterSpacing: 0));

  /// Tailwind `text-xs` (12/16), used by chat answer pagination and the file input controls.
  static const textXs = DifyTextStyle(
    TextStyle(fontSize: 12, height: 16 / 12, leadingDistribution: TextLeadingDistribution.even, letterSpacing: 0),
  );

  /// base/chat/chat/index.tsx `text-xs font-normal` on the stop-responding label.
  static const textXsNormal = DifyTextStyle(
    TextStyle(
      fontSize: 12,
      height: 16 / 12,
      fontWeight: FontWeight.w400,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// workflow/panel preview tabs: `text-[13px] leading-4.5 font-semibold`.
  static const text13SemiboldLeading18 = DifyTextStyle(
    TextStyle(
      fontSize: 13,
      height: 18 / 13,
      fontWeight: FontWeight.w600,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// The user-input section label: `text-[13px] font-semibold`, with line height inherited.
  static const text13Semibold = DifyTextStyle(TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0));

  /// `text-xs leading-[18px]`
  static const textXsLeading18 = DifyTextStyle(
    TextStyle(
      fontSize: 12,
      height: 18 / 12,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-xs font-medium leading-[18px]`
  static const textXsMediumLeading18 = DifyTextStyle(
    TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 18 / 12,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[13px]`
  static const text13 = DifyTextStyle(
    TextStyle(
      fontSize: 13,
      letterSpacing: 0,
    ),
  );

  /// `text-[13px] leading-4`
  static const text13Leading16 = DifyTextStyle(
    TextStyle(
      fontSize: 13,
      height: 16 / 13,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[13px] font-medium leading-4`
  static const text13MediumLeading16 = DifyTextStyle(
    TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      height: 16 / 13,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[13px] leading-[18px]`
  static const text13Leading18 = DifyTextStyle(
    TextStyle(
      fontSize: 13,
      height: 18 / 13,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[13px] font-medium leading-[18px]`
  static const text13MediumLeading18 = DifyTextStyle(
    TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      height: 18 / 13,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[13px] leading-5`
  static const text13Leading20 = DifyTextStyle(
    TextStyle(
      fontSize: 13,
      height: 20 / 13,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[11px] font-semibold` (prompt-editor context-block's dataset count)
  static const text11Semibold = DifyTextStyle(
    TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
    ),
  );

  /// `text-[13px] leading-4.5 font-normal` (the code editor's placeholder)
  static const text13NormalLeading18 = DifyTextStyle(
    TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 18 / 13,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-xs/6` (if-else node's condition value)
  static const textXsLeading24 = DifyTextStyle(
    TextStyle(
      fontSize: 12,
      height: 24 / 12,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-2xs font-medium tracking-wide uppercase` under the page's inherited `line-height: 1.5` (start / trigger
  /// node captions)
  static const text2xsMediumTrackingWideUppercaseLeading15 = DifyTextStyle(
    TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w500,
      height: 15 / 10,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0.25,
    ),
    uppercase: true,
  );

  /// `font-extrabold` (the iteration node's parallel-mode tooltip title)
  static const fontExtrabold = DifyTextStyle(TextStyle(fontWeight: FontWeight.w800));

  /// `text-[10px] font-medium` (dify-ui Avatar `sm`'s initial)
  static const text10Medium = DifyTextStyle(TextStyle(fontSize: 10, fontWeight: FontWeight.w500, letterSpacing: 0));

  /// `text-xl font-semibold` (the follow-up settings dialog title)
  static const textXlSemibold = DifyTextStyle(
    TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      height: 28 / 20,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-sm/6` (the prompt editor placeholder, base/prompt-editor/plugins/placeholder.tsx)
  static const textSmLeading24 = DifyTextStyle(
    TextStyle(
      fontSize: 14,
      height: 24 / 14,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-sm/9` (the conversation opener's question inputs)
  static const textSmLeading36 = DifyTextStyle(
    TextStyle(
      fontSize: 14,
      height: 36 / 14,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-xs` in an `h-5` line (VarHighlight, app/configuration/base/var-highlight)
  static const textXsLeading20 = DifyTextStyle(
    TextStyle(
      fontSize: 12,
      height: 20 / 12,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-2xs leading-none` (10 px, `--text-2xs` in packages/dify-ui/src/styles/styles.css; base/user-avatar-list's
  /// "+N")
  static const text2xsLeadingNone = DifyTextStyle(
    TextStyle(
      fontSize: 10,
      height: 1,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[13px] font-medium`
  static const text13Medium = DifyTextStyle(TextStyle(fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0));

  /// `text-[13px] leading-8 font-medium`
  static const text13MediumLeading32 = DifyTextStyle(
    TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      height: 32 / 13,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[14px] font-semibold`
  static const text14Semibold = DifyTextStyle(TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0));

  /// `font-semibold`
  static const fontSemibold = DifyTextStyle(TextStyle(fontWeight: FontWeight.w600));

  /// `text-xs leading-[150%] tracking-wider` (with `font-mono`: add the family)
  static const textXsLeading150TrackingWider = DifyTextStyle(
    TextStyle(fontSize: 12, height: 1.5, leadingDistribution: TextLeadingDistribution.even, letterSpacing: 12 * 0.05),
  );

  /// `text-xs/6 font-medium` (the memory config's "conversation role name", with `uppercase` upper-cased by the caller)
  static const textXsMediumLeading24 = DifyTextStyle(
    TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 24 / 12,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-2xs font-semibold` under a `text-xs` parent (header/running-title.tsx's VIEW ONLY badge): the inherited
  /// line height (`1 / 0.75` of 10 px) that Chrome lays out at 14 px.
  static const text2xsSemiboldLeading14 = DifyTextStyle(
    TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      height: 14 / 10,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[13px] font-medium` under an inherited `line-height: 1.5`
  static const text13MediumLeading150 = DifyTextStyle(
    TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      height: 1.5,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-sm` with the weight inherited (activate `text-sm!` on the primary button)
  static const textSm = DifyTextStyle(
    TextStyle(
      fontSize: 14,
      height: 20 / 14,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[14px]`; also an inherited 14 px with no class (the annotation CSV uploader's file name)
  static const text14 = DifyTextStyle(
    TextStyle(
      fontSize: 14,
      letterSpacing: 0,
    ),
  );

  /// `text-sm leading-tight font-medium` (app/overview/embedded chrome-plugin button)
  static const textSmMediumLeadingTight = DifyTextStyle(
    TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      height: 1.25,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[13px] leading-tight` (app/overview/embedded code block, with `font-mono`)
  static const text13LeadingTight = DifyTextStyle(
    TextStyle(
      fontSize: 13,
      height: 1.25,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[13px] font-medium` in a 20 px row (signin/_locale-menu.tsx trigger)
  static const text13MediumLeading20 = DifyTextStyle(
    TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      height: 20 / 13,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-base/5 font-medium` (main-nav/components/workspace-card.tsx)
  static const textBaseMediumLeading20 = DifyTextStyle(
    TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      height: 20 / 16,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-xl leading-7.5 font-semibold` (explore/create-app-modal title)
  static const textXlSemiboldLeading30 = DifyTextStyle(
    TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w600,
      height: 30 / 20,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[24px] font-semibold leading-8` (app/overview/apikey-info-panel title)
  static const text24SemiboldLeading32 = DifyTextStyle(
    TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w600,
      height: 32 / 24,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-2xl font-bold` (signin/invite-settings shrug)
  static const text2xlBold = DifyTextStyle(
    TextStyle(
      fontSize: 24,
      fontWeight: FontWeight.w700,
      height: 32 / 24,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[32px] font-bold` on the inherited 1.5 line height (activate, install headings)
  static const text32BoldLeading48 = DifyTextStyle(
    TextStyle(
      fontSize: 32,
      fontWeight: FontWeight.w700,
      height: 1.5,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );

  /// `text-[40px] font-bold` (activate/activateForm.tsx shrug)
  static const text40Bold = DifyTextStyle(
    TextStyle(
      fontSize: 40,
      fontWeight: FontWeight.w700,
      letterSpacing: 0,
    ),
  );

  /// `font-medium` (weight only)
  static const fontMedium = DifyTextStyle(
    TextStyle(
      fontWeight: FontWeight.w500,
    ),
  );

  /// `font-bold`; also `<strong>`/`<b>` (preflight `font-weight: bolder` over a 400 parent)
  static const fontBold = DifyTextStyle(
    TextStyle(
      fontWeight: FontWeight.w700,
    ),
  );

  /// `text-2xs font-semibold` (`--text-2xs: 0.625rem`, no line height of its own)
  static const text2xsSemibold = DifyTextStyle(TextStyle(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0));

  /// `text-base` (16/24): also the browser's 16 px under Tailwind preflight's `line-height: 1.5`, which is what Dify's
  /// header/view-workflow-history.tsx title gets (its `system-mg-regular` is not a defined utility)
  static const textBase = DifyTextStyle(
    TextStyle(
      fontSize: 16,
      height: 24 / 16,
      leadingDistribution: TextLeadingDistribution.even,
      letterSpacing: 0,
    ),
  );
}

/// web/app/styles/markdown.css `.markdown-body h1` (18px), h2 (16px), h3-h6 (14px), over Streamdown's
/// font-semibold. The human-input preview inherits its paragraph line height separately.
abstract final class DifyMarkdownHeadingStyles {
  static const h1 = TextStyle(fontSize: 18, fontWeight: FontWeight.w600);
  static const h2 = TextStyle(fontSize: 16, fontWeight: FontWeight.w600);
  static const h3 = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
}
