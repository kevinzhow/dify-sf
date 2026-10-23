// Colours Dify writes as literals (arbitrary Tailwind values such as `text-[#6938EF]`, hex strings in TS/TSX, Tailwind's
// own `white`/`black`), grouped by the Dify source that hard-codes them. Theme colours are DifyColors (generated);
// these do NOT follow the theme: Dify paints the same value in light and dark. Getters (no const/static final caches),
// like DifyColors, so a value that becomes a theme token in a later Dify can switch without touching call sites.
import 'dart:ui';

/// Tailwind v4's default `white` / `black` (Dify does not override them in packages/dify-ui/src/styles/styles.css):
/// `bg-white`, `text-white`, `bg-black/5`, `shadow-black/…` in Dify's components. Opacity modifiers:
/// `.withValues(alpha: …)` or the named values below.
abstract final class DifyTailwind {
  /// packages/dify-ui/src/styles/styles.css legacy @theme overrides (fixed in both themes).
  static Color get gray300 => const Color(0xFFD0D5DD);
  static Color get gray400 => const Color(0xFF98A2B3);
  static Color get gray500 => const Color(0xFF667085);
  static Color get primary600 => const Color(0xFF155EEF);

  /// `white` (#fff)
  static Color get white => const Color(0xFFFFFFFF);

  /// `black` (#000)
  static Color get black => const Color(0xFF000000);

  /// `orange-400`: Tailwind's default `oklch(75% 0.183 55.934)` (dify-ui does not override orange), e.g.
  /// web/app/components/app/overview/app-chart.tsx `text-orange-400`.
  static Color get orange400 => const Color(0xFFFF8904);

  /// `orange-50`: Tailwind's default `oklch(98% 0.016 73.684)`, e.g. members-page/invited-modal `bg-orange-50`.
  static Color get orange50 => const Color(0xFFFFF7ED);

  /// `red-300`: Tailwind's default `oklch(80.8% 0.114 19.571)` (dify-ui does not override red), e.g.
  /// members-page/invited-modal `border-red-300`, `text-red-300`.
  static Color get red300 => const Color(0xFFFFA2A2);
}

/// Avatar and cursor colours of collaborators: web/app/components/workflow/collaboration/utils/user-color.ts
/// (`getUserColor`), in its order.
abstract final class DifyUserColors {
  static List<Color> get all => const [
    Color(0xFF155AEF),
    Color(0xFF0BA5EC),
    Color(0xFF444CE7),
    Color(0xFF7839EE),
    Color(0xFF4CA30D),
    Color(0xFF0E9384),
    Color(0xFFDD2590),
    Color(0xFFFF4405),
    Color(0xFFD92D20),
    Color(0xFFF79009),
    Color(0xFF828DAD),
  ];
}

/// FileTypeIcon's colours per file appearance type: web/app/components/base/file-uploader/file-type-icon.tsx
/// (`FILE_TYPE_ICON_MAP`, `text-[#…]`).
abstract final class DifyFileTypeColors {
  /// pdf: `text-[#EA3434]`
  static Color get pdf => const Color(0xFFEA3434);

  /// image, gif: `text-[#00B2EA]`
  static Color get image => const Color(0xFF00B2EA);

  /// video: `text-[#844FDA]`
  static Color get video => const Color(0xFF844FDA);

  /// audio: `text-[#FF3093]`
  static Color get audio => const Color(0xFFFF3093);

  /// document (also the fallback): `text-[#6F8BB5]`
  static Color get document => const Color(0xFF6F8BB5);

  /// code, custom: `text-[#BCC0D1]`
  static Color get code => const Color(0xFFBCC0D1);

  /// markdown: `text-[#309BEC]`
  static Color get markdown => const Color(0xFF309BEC);

  /// excel: `text-[#01AC49]`
  static Color get excel => const Color(0xFF01AC49);

  /// word: `text-[#2684FF]`
  static Color get word => const Color(0xFF2684FF);

  /// ppt: `text-[#FF650F]`
  static Color get ppt => const Color(0xFFFF650F);
}

/// The overview charts' literal colours: web/app/components/app/overview/app-chart-utils.ts (`COLOR_TYPE_MAP`,
/// `COMMON_COLOR_MAP`, the tooltip's inline styles) and the ECharts defaults Dify leaves (tooltip box, symbol fill).
/// ECharts gets no theme, so they are the same in both themes, as in Dify.
abstract final class DifyChartColors {
  /// `COLOR_TYPE_MAP.green.lineColor` `rgba(6, 148, 162, 1)`
  static Color get greenLine => const Color.fromRGBO(6, 148, 162, 1);

  /// `COLOR_TYPE_MAP.green.bgColor`
  static Color get greenAreaTop => const Color.fromRGBO(6, 148, 162, 0.2);
  static Color get greenAreaBottom => const Color.fromRGBO(67, 174, 185, 0.08);

  /// `COLOR_TYPE_MAP.orange.lineColor` `rgba(255, 138, 76, 1)`
  static Color get orangeLine => const Color.fromRGBO(255, 138, 76, 1);

  /// `COLOR_TYPE_MAP.orange.bgColor`
  static Color get orangeAreaTop => const Color.fromRGBO(254, 145, 87, 0.2);
  static Color get orangeAreaBottom => const Color.fromRGBO(255, 138, 76, 0.1);

  /// `COLOR_TYPE_MAP.blue.lineColor` `rgba(28, 100, 242, 1)`
  static Color get blueLine => const Color.fromRGBO(28, 100, 242, 1);

  /// `COLOR_TYPE_MAP.blue.bgColor`
  static Color get blueAreaTop => const Color.fromRGBO(28, 100, 242, 0.3);
  static Color get blueAreaBottom => const Color.fromRGBO(28, 100, 242, 0.1);

  /// `COMMON_COLOR_MAP.label` `#9CA3AF`
  static Color get label => const Color(0xFF9CA3AF);

  /// `COMMON_COLOR_MAP.splitLineLight` `#F3F4F6`
  static Color get splitLineLight => const Color(0xFFF3F4F6);

  /// `COMMON_COLOR_MAP.splitLineDark` `#E5E7EB`
  static Color get splitLineDark => const Color(0xFFE5E7EB);

  /// The tooltip's date `color:#6B7280`, value `color:#1F2A37` and price `color:#FF8A4C`.
  static Color get tooltipName => const Color(0xFF6B7280);
  static Color get tooltipValue => const Color(0xFF1F2A37);
  static Color get tooltipPrice => const Color(0xFFFF8A4C);

  /// ECharts' tooltip box: `backgroundColor` (`tokens.color.neutral00`, #fff) and its `rgba(0, 0, 0, 0.2)` shadow.
  static Color get tooltipBackground => const Color(0xFFFFFFFF);
  static Color get tooltipShadow => const Color.fromRGBO(0, 0, 0, 0.2);

  /// ECharts' `symbolInnerColor` (#fff) inside the `emptyCircle` symbols.
  static Color get symbolInner => const Color(0xFFFFFFFF);
}

/// The line drawn while dragging a new connection: web/app/components/workflow/custom-connection-line.tsx
/// (`stroke="#D0D5DD"`, the target marker `fill="#2970FF"`).
abstract final class DifyConnectionLineColors {
  /// `stroke="#D0D5DD"`
  static Color get stroke => const Color(0xFFD0D5DD);

  /// `fill="#2970FF"`
  static Color get marker => const Color(0xFF2970FF);
}

/// The prompt editor's inline blocks, whose colours Dify writes as arbitrary values
/// (web/app/components/base/prompt-editor/plugins/*/component.tsx) and repeats on the component picker's icons
/// (plugins/component-picker-block/hooks.tsx).
abstract final class DifyPromptBlockColors {
  /// context-block: `bg-[#F4F3FF]`, `hover:bg-[#EBE9FE]` (and open), `border-[#9B8AFB]!` when selected, text and icon
  /// `text-[#6938EF]` (also `bg-[#6938EF]` on the open count button).
  static Color get contextBg => const Color(0xFFF4F3FF);
  static Color get contextBgHover => const Color(0xFFEBE9FE);
  static Color get contextBorderSelected => const Color(0xFF9B8AFB);
  static Color get context => const Color(0xFF6938EF);

  /// context-block's dataset folder box: `border-[#EAECF5] bg-[#F5F8FF]`.
  static Color get contextFolderBorder => const Color(0xFFEAECF5);
  static Color get contextFolderBg => const Color(0xFFF5F8FF);

  /// history-block: `text-[#DD2590]` (also `bg-[#DD2590]` when open), `bg-[#FDF2FA]`, `hover:bg-[#FCE7F6]` (and open),
  /// `border-[#F670C7]!` when selected.
  static Color get history => const Color(0xFFDD2590);
  static Color get historyBg => const Color(0xFFFDF2FA);
  static Color get historyBgHover => const Color(0xFFFCE7F6);
  static Color get historyBorderSelected => const Color(0xFFF670C7);

  /// query-block: `bg-[#FFF6ED]`, `hover:bg-[#FFEAD5]`, `border-[#FD853A]!` when selected, icon `text-[#FD853A]`, text
  /// `text-[#EC4A0A]`.
  static Color get queryBg => const Color(0xFFFFF6ED);
  static Color get queryBgHover => const Color(0xFFFFEAD5);
  static Color get queryAccent => const Color(0xFFFD853A);
  static Color get query => const Color(0xFFEC4A0A);

  /// request-url-block: `hover:border-[#7839ee]`, `border-[#7839ee]!` when selected.
  static Color get requestUrlBorderHover => const Color(0xFF7839EE);
}

/// ErrorHandleTip's warning wash: web/app/components/workflow/nodes/_base/components/error-handle/error-handle-tip.tsx
/// (an `opacity-40` overlay, `linear-gradient(92deg, rgba(247, 144, 9, 0.25) 0%, rgba(255, 255, 255, 0.00) 100%)`);
/// the stops below have the overlay's 0.4 applied.
abstract final class DifyErrorHandleTipColors {
  /// `rgba(247, 144, 9, 0.25)` at `opacity-40`
  static Color get gradientStart => const Color(0x1AF79009);

  /// `rgba(255, 255, 255, 0.00)`
  static Color get gradientEnd => const Color(0x00FFFFFF);
}

/// The default icon of a knowledge base without its own (`icon: '📙'`, `icon_background: '#FFF4ED'`):
/// web/app/components/workflow/nodes/knowledge-retrieval/node.tsx (also datasets/list/dataset-card, app-sidebar).
abstract final class DifyDatasetIconColors {
  /// `icon_background: '#FFF4ED'`
  static Color get defaultBackground => const Color(0xFFFFF4ED);
}

/// The note node's resize handle icon: web/app/components/workflow/note-node/index.tsx (`fill="black"`,
/// `fillOpacity="0.16"`).
abstract final class DifyNoteNodeColors {
  /// `fill="black" fillOpacity="0.16"`
  static Color get resizeGlyph => const Color(0x29000000);
}

/// AppIcon's background when the app has none: web/app/components/base/app-icon/index.tsx
/// (`background || '#FFEAD5'`).
abstract final class DifyAppIconColors {
  /// `'#FFEAD5'`
  static Color get defaultBackground => const Color(0xFFFFEAD5);
}

/// The expanded editor's lift (prompt and code editors): web/app/components/workflow/nodes/_base/hooks/use-toggle-expend.ts
/// (`boxShadow: '0px 0px 12px -4px rgba(16, 24, 40, 0.05), 0px -3px 6px -2px rgba(16, 24, 40, 0.03)'`).
abstract final class DifyToggleExpendColors {
  /// `rgba(16, 24, 40, 0.05)` (`0px 0px 12px -4px`)
  static Color get shadow => const Color.fromRGBO(16, 24, 40, 0.05);

  /// `rgba(16, 24, 40, 0.03)` (`0px -3px 6px -2px`)
  static Color get shadowTop => const Color.fromRGBO(16, 24, 40, 0.03);
}

/// The moderation settings' "OpenAI is not set up" note:
/// web/app/components/base/features/new-feature-panel/moderation/moderation-setting-modal.tsx
/// (`border-[#FEF0C7] bg-[#FFFAEB]`, the info icon `text-[#F79009]`).
abstract final class DifyModerationColors {
  static Color get openAINotConfiguredBg => const Color(0xFFFFFAEB);
  static Color get openAINotConfiguredBorder => const Color(0xFFFEF0C7);
  static Color get openAINotConfiguredIcon => const Color(0xFFF79009);
}

/// The conversation opener's "add these variables?" overlay:
/// web/app/components/app/configuration/config-prompt/confirm-add-var/index.tsx (inline `backgroundColor:
/// 'rgba(35, 56, 118, 0.2)'` behind it, `boxShadow: '0px 12px 16px -4px rgba(16, 24, 40, 0.08), 0px 4px 6px -2px
/// rgba(16, 24, 40, 0.03)'` on the card), and its VarHighlight chips
/// (web/app/components/app/configuration/base/var-highlight/style.module.css `.item`).
abstract final class DifyConfirmAddVarColors {
  static Color get backdrop => const Color.fromRGBO(35, 56, 118, 0.2);
  static Color get shadow => const Color.fromRGBO(16, 24, 40, 0.08);
  static Color get shadowNear => const Color.fromRGBO(16, 24, 40, 0.03);

  /// VarHighlight `.item { background-color: rgba(21, 94, 239, 0.05) }`
  static Color get varHighlightBg => const Color.fromRGBO(21, 94, 239, 0.05);
}

/// The checklist's issue marker: web/app/components/workflow/header/checklist/item-indicator.tsx (`<circle
/// fill="#F79009" stroke="white">`).
abstract final class DifyChecklistColors {
  /// `fill="#F79009"`
  static Color get indicatorDot => const Color(0xFFF79009);

  /// `stroke="white"`
  static Color get indicatorRing => const Color(0xFFFFFFFF);
}

/// `caret-[#295EFF]`: web/app/components/base/tag-input/index.tsx, also workflow/nodes/_base/components/
/// title-description-input.tsx and the JSON schema editor's edit card
/// (workflow/nodes/llm/components/json-schema-config-modal/visual-editor/edit-card/{index,auto-width-input}.tsx).
abstract final class DifyCaretColors {
  static Color get tagInput => const Color(0xFF295EFF);
}

/// The tone icons of the model parameters' "Load Presets" menu:
/// web/app/components/header/account-setting/model-provider-page/model-parameter-modal/presets-parameter.tsx
/// (`TONE_ICONS`: `text-[#6938EF]`, `text-indigo-600` = DifyColors.indigo600, `text-[#107569]`).
abstract final class DifyPresetsParameterColors {
  /// Brush01 (tone 1)
  static Color get creative => const Color(0xFF6938EF);

  /// Target04 (tone 3)
  static Color get precise => const Color(0xFF107569);
}

/// The LLM panel's warning tips (context not set in the prompt, `sys.query` missing from the user message):
/// web/app/components/workflow/nodes/llm/panel.tsx, components/panel-memory-section.tsx (`text-[#DC6803]`).
abstract final class DifyLlmPanelColors {
  static Color get warningTip => const Color(0xFFDC6803);
}

/// The blobs of the knowledge-base option cards' effects (`fill` of the blurred circle):
/// packages/iconify-collections/assets/public/knowledge/option-card-effect-*.svg.
abstract final class DifyOptionCardEffectColors {
  /// option-card-effect-blue.svg
  static Color get blue => const Color(0xFF6172F3);

  /// option-card-effect-blue-light.svg
  static Color get blueLight => const Color(0xFF0BA5EC);

  /// option-card-effect-orange.svg
  static Color get orange => const Color(0xFFEF6820);

  /// option-card-effect-purple.svg
  static Color get purple => const Color(0xFF6938EF);

  /// option-card-effect-teal.svg
  static Color get teal => const Color(0xFF0E9384);
}

/// Agent roster icons: web/features/agent-v2/roster/components/agent-form.ts (`defaultAgentIcon.background`).
abstract final class DifyAgentRosterColors {
  static Color get defaultIconBackground => const Color(0xFFF5F3FF);
}

/// The block selector's letter index bar: web/app/components/workflow/block-selector/index-bar.tsx (its 1 px left
/// line, `bg-[linear-gradient(270deg,rgba(255,255,255,0)_0%,rgba(16,24,40,0.08)_30%, … ,rgba(255,255,255,0)_100%)]`).
abstract final class DifyIndexBarColors {
  /// `rgba(16,24,40,0.08)`, the line's middle stops
  static Color get line => const Color.fromRGBO(16, 24, 40, 0.08);
}

/// The run history list's status icons: web/app/components/workflow/header/view-history.tsx (`text-[#F79009]`
/// stopped, `text-[#F04438]` failed, `text-[#12B76A]` succeeded).
abstract final class DifyViewHistoryColors {
  /// `text-[#F79009]`
  static Color get stopped => const Color(0xFFF79009);

  /// `text-[#F04438]`
  static Color get failed => const Color(0xFFF04438);

  /// `text-[#12B76A]`
  static Color get succeeded => const Color(0xFF12B76A);
}

/// web/app/signin/split.tsx: `bg-[linear-gradient(90deg,rgba(255,255,255,0.01)_0%,rgba(16,24,40,0.08)_50.5%,
/// rgba(255,255,255,0.01)_100%)]`.
abstract final class DifySigninSplitColors {
  static Color get edge => const Color(0x03FFFFFF);
  static Color get middle => const Color(0x14101828);
}

/// web/app/components/header/account-setting/model-provider-page: the "none configured" warning's glow (index.tsx
/// `bg-[linear-gradient(119deg,rgba(247,144,9,0.25)_0%,rgba(255,255,255,0)_100%)]`) and the quota card grid's mask
/// (provider-added-card/quota-panel.module.css `radial-gradient(ellipse at center, rgba(0, 0, 0, 0.6), transparent
/// 70%)`).
abstract final class DifyModelProviderColors {
  static Color get noneConfiguredGlowStart => const Color(0x40F79009);
  static Color get noneConfiguredGlowEnd => const Color(0x00FFFFFF);
  static Color get quotaGridMask => const Color(0x99000000);
  static Color get quotaGridMaskEnd => const Color(0x00000000);
}

/// web/app/components/header/account-setting/members-page/invited-modal/index.tsx: the check icon `text-[#039855]`.
abstract final class DifyInvitedModalColors {
  static Color get check => const Color(0xFF039855);
}

/// web/app/components/apps/list.tsx: the drop overlay `bg-[rgba(21,90,239,0.14)]`.
abstract final class DifyAppListColors {
  static Color get dropOverlay => const Color(0x24155AEF);
}

/// web/app/components/app/create-app-modal/index.tsx: the stripes `repeating-linear-gradient(135deg, transparent,
/// transparent 2px, rgba(16,24,40,0.04) 4px, transparent 3px, transparent 6px)`.
abstract final class DifyCreateAppColors {
  static Color get stripe => const Color(0x0A101828);
}

/// The canvas image export: web/app/components/workflow/operator/more-actions.tsx (`backgroundColor: '#1a1a1a'` of the
/// whole-workflow export).
abstract final class DifyImageExportColors {
  /// `'#1a1a1a'`
  static Color get workflowBackground => const Color(0xFF1A1A1A);
}

/// workflow/run/status-container.tsx and run/assets/bg-line-{success,error,warning,running}.svg.
/// Borders use 80% and glows 20% of these literal colours in both themes; dark glows use 25%.
abstract final class DifyRunStatusColors {
  static Color get success => const Color(0xFF17B26A);

  /// Also base/chat/chat/answer/basic-content.tsx `text-[#F04438]!`.
  static Color get error => const Color(0xFFF04438);
  static Color get warning => const Color(0xFFF79009);
  static Color get running => const Color(0xFF0BA5EC);
  static Color get successBorder => const Color(0xCC17B26A);
  static Color get errorBorder => const Color(0xCCF04438);
  static Color get warningBorder => const Color(0xCCF79009);
  static Color get runningBorder => const Color(0xCC0BA5EC);
  static Color get successGlow => const Color(0x3317B26A);
  static Color get errorGlow => const Color(0x33F04438);
  static Color get warningGlow => const Color(0x33F79009);
  static Color get runningGlow => const Color(0x330BA5EC);
  static Color innerShade(bool dark) => dark ? const Color(0x66000000) : const Color(0x1F000000);
  static Color innerLight(bool dark) => dark ? const Color(0x1FFFFFFF) : const Color(0x80FFFFFF);

  /// highlight.svg / highlight-dark.svg: original opacity 0.5 is already multiplied into these stops.
  static List<Color> highlight(bool dark) => dark
      ? const [Color.fromRGBO(255, 255, 255, 0.015), Color.fromRGBO(255, 255, 255, 0.025)]
      : const [Color(0x0FFFFFFF), Color(0x40FFFFFF)];
}

/// workflow/run/tracing-panel.tsx and panel/debug-and-preview/conversation-variable-modal.tsx.
abstract final class DifyRunDividerColors {
  static Color get start => const Color(0x14101828);
  static Color get transparentWhite => const Color(0x00FFFFFF);

  /// run/agent-log/agent-result-panel.tsx: warning gradient alpha 0.25 times wrapper opacity 0.4.
  static Color get warningStart => const Color(0x1AF79009);
}

/// The Flutter Scene capture placeholder (our renderer, before a card capture is ready). It has no Dify DOM
/// equivalent; retain the existing lavender in light mode and use workflowBlockBg in dark at the call site.
abstract final class DifyCanvasPlaceholderColors {
  static Color get light => const Color(0xFFF8F7FF);
}
