/// The building blocks of Dify's sign-in, install and activate pages: the page frames (signin/layout.tsx,
/// install/page.tsx), the header with the locale menu (signin/_header.tsx, _locale-menu.tsx), dify-ui's Field / Input /
/// InputGroup as those forms use them (Base UI validation: errors after a submit, then live).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' show Material, MaterialType;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_theme_mode.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/app_locale.dart';
import '../../i18n/dify_i18n.dart';
import '../../open_url.dart';

/// `t(key, { ns: 'login' })`, rebuilding the caller when the language changes.
String tLogin(BuildContext context, String key, [Map<String, Object?> params = const {}]) {
  AppLocaleScope.of(context);
  return DifyI18n.tr('login', key, params);
}

/// Tailwind's `md` breakpoint.
bool _md(BuildContext context) => MediaQuery.sizeOf(context).width >= 768;

// ---- form state ---------------------------------------------------------------------------------------------------

/// One field of a form (Base UI Field.Root): its value, the error shown (null: valid), and the focus. [validate] returns
/// the error text or null. Like Base UI's default `onSubmit` validation mode, a field shows no error until the form
/// was submitted; from then on it revalidates as the value changes.
class AuthField extends ChangeNotifier {
  AuthField({this._value = '', this.validate});

  String? Function(String value)? validate;
  final focusNode = FocusNode(debugLabel: 'AuthField');

  String _value;
  String? _error;
  bool _live = false;

  String get value => _value;
  String? get error => _error;
  bool get invalid => _error != null;

  set value(String v) {
    if (v == _value) return;
    _value = v;
    if (_live) _error = validate?.call(v);
    notifyListeners();
  }

  /// Validates now (and live from now on); true when valid.
  bool check() {
    _live = true;
    _error = validate?.call(_value);
    notifyListeners();
    return _error == null;
  }

  @override
  void dispose() {
    focusNode.dispose();
    super.dispose();
  }
}

/// Base UI Form's submit: validates every field; when one is invalid, focuses the first invalid field and returns
/// false (the submit handler does not run).
bool submitAuthForm(Iterable<AuthField> fields) {
  AuthField? first;
  for (final f in fields) {
    if (!f.check()) first ??= f;
  }
  first?.focusNode.requestFocus();
  return first == null;
}

// ---- fields -------------------------------------------------------------------------------------------------------

/// `Field` (`grid gap-1`) with `FieldLabel` (`py-1 system-sm-medium text-text-secondary`), an `Input` or an
/// `InputGroup` with the password visibility button, `FieldDescription` (`py-0.5 body-xs-regular`, shown while valid)
/// and `FieldError` (`py-0.5 body-xs-regular text-text-destructive`, shown while invalid). [labelTrailing] sits at the
/// label row's end (the password field's "Forgot your password?", `absolute inset-e-0 top-1`).
class AuthTextField extends StatefulWidget {
  const AuthTextField({
    super.key,
    required this.field,
    required this.label,
    this.placeholder,
    this.password = false,
    this.revealButtonSize = DifyIconButtonSize.md,
    this.disabled = false,
    this.keyboardType,
    this.autofillHints,
    this.maxLength,
    this.description,
    this.labelTrailing,
    this.onSubmitted,
    this.textInputAction,
  });

  final AuthField field;
  final String label;
  final String? placeholder;

  /// `type="password"` with the show / hide button (IconButton of [revealButtonSize]) in an InputGroup.
  final bool password;
  final DifyIconButtonSize revealButtonSize;
  final bool disabled;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final int? maxLength;
  final String? description;
  final Widget? labelTrailing;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  @override
  State<AuthTextField> createState() => _AuthTextFieldState();
}

class _AuthTextFieldState extends State<AuthTextField> {
  bool _show = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final label = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(w.label, style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary)),
    );
    return ListenableBuilder(
      listenable: w.field,
      builder: (context, _) {
        final f = w.field;
        Widget? reveal;
        if (w.password) {
          final name = tLogin(context, _show ? 'hidePassword' : 'showPassword');
          reveal = Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, end: 8),
            child: DifyIconButton(
              key: const ValueKey('reveal-password'),
              label: name,
              size: w.revealButtonSize,
              disabled: w.disabled,
              icon: RemixIcon(_show ? 'eye-off-line' : 'eye-line', size: 16),
              onPressed: () => setState(() => _show = !_show),
            ),
          );
        }
        // The lg button (32 px) makes the group 34 px high, as in the browser.
        final input = DifyInput(
          value: f.value,
          onChanged: (v) => f.value = v,
          onSubmitted: w.onSubmitted,
          placeholder: w.placeholder,
          semanticLabel: w.label,
          disabled: w.disabled,
          invalid: f.invalid,
          focusNode: f.focusNode,
          obscureText: w.password && !_show,
          keyboardType: w.keyboardType,
          autofillHints: w.autofillHints,
          maxLength: w.maxLength,
          textInputAction: w.textInputAction,
          trailing: reveal,
          height: reveal != null && w.revealButtonSize == DifyIconButtonSize.lg ? 34 : null,
        );
        final note = f.error ?? (f.invalid ? null : w.description);
        final trailing = w.labelTrailing;
        final column = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 4,
          children: [
            if (trailing == null)
              Align(alignment: AlignmentDirectional.centerStart, child: label)
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  label,
                  const Spacer(),
                  // In the DOM the trailing link follows the input (it is only drawn at the label's end): it comes
                  // after the input and its buttons in the tab order, not before them as reading order would put it.
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(2),
                    child: Padding(padding: const EdgeInsets.only(top: 4), child: trailing),
                  ),
                ],
              ),
            if (trailing == null)
              input
            else
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: FocusTraversalGroup(child: input),
              ),
            if (note != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  note,
                  key: f.error != null ? const ValueKey('field-error') : const ValueKey('field-description'),
                  style: difyTextStyle(
                    DifyType.bodyXsRegular,
                    f.error != null ? DifyColors.textDestructive : DifyColors.textSecondary,
                  ),
                ),
              ),
          ],
        );
        return trailing == null ? column : FocusTraversalGroup(policy: OrderedTraversalPolicy(), child: column);
      },
    );
  }
}

// ---- links --------------------------------------------------------------------------------------------------------

/// An inline link (`<Link>`): [onTap], or [url] opened outside the app; underlined on hover when [hoverUnderline].
class AuthLink extends StatefulWidget {
  const AuthLink(this.text, {super.key, required this.style, this.onTap, this.url, this.hoverUnderline = false});
  final String text;
  final TextStyle style;
  final VoidCallback? onTap;
  final String? url;
  final bool hoverUnderline;

  @override
  State<AuthLink> createState() => _AuthLinkState();
}

class _AuthLinkState extends State<AuthLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final tap = w.onTap ?? (w.url == null ? null : () => openExternalUrl(w.url!));
    return Semantics(
      link: true,
      onTap: tap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: tap,
          excludeFromSemantics: true,
          child: Text(
            w.text,
            style: _hover && w.hoverUnderline ? w.style.copyWith(decoration: TextDecoration.underline) : w.style,
          ),
        ),
      ),
    );
  }
}

/// Text followed by links, wrapping like inline HTML (`{text}&nbsp;<Link/>`).
class AuthInlineLinks extends StatelessWidget {
  const AuthInlineLinks({super.key, required this.spans, required this.style});

  /// Plain strings and ([text], [onTap]) links, in order.
  final List<Object> spans;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      style: style,
      children: [
        for (final s in spans)
          switch (s) {
            final String text => TextSpan(text: text),
            final AuthSpanLink l => WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: AuthLink(l.text, style: l.style, onTap: l.onTap, url: l.url, hoverUnderline: l.hoverUnderline),
            ),
            _ => const TextSpan(),
          },
      ],
    ),
  );
}

class AuthSpanLink {
  const AuthSpanLink(this.text, {required this.style, this.onTap, this.url, this.hoverUnderline = false});
  final String text;
  final TextStyle style;
  final VoidCallback? onTap;
  final String? url;
  final bool hoverUnderline;
}

// ---- headings -----------------------------------------------------------------------------------------------------

/// An `<h1>`.
class AuthHeading extends StatelessWidget {
  const AuthHeading(this.text, {super.key, required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    header: true,
    headingLevel: 1,
    child: Text(text, style: style),
  );
}

// ---- document title -----------------------------------------------------------------------------------------------

/// hooks/use-document-title.ts: the window's (browser tab's) title, `{title} - Dify` (`Dify` alone for an empty one).
class DifyDocumentTitle extends StatelessWidget {
  const DifyDocumentTitle({super.key, required this.title, required this.child});
  final String title;
  final Widget child;

  static String format(String title) => title.isEmpty ? 'Dify' : '$title - Dify';

  @override
  Widget build(BuildContext context) => Title(title: format(title), color: DifyColors.textAccent, child: child);
}

// ---- locale menu --------------------------------------------------------------------------------------------------

/// signin/_locale-menu.tsx: a `w-56 text-right` box with the trigger (`rounded-lg border
/// border-components-button-secondary-border px-2.5 py-1.5 text-[13px] font-medium text-text-primary`, the globe
/// 20 px, hover `bg-state-base-hover`) and the radio menu (`bottom-end`, 8 px below, `w-50`, items `px-3 py-2 text-sm
/// text-text-secondary`).
class LocaleMenu extends StatefulWidget {
  const LocaleMenu({super.key, required this.items, required this.value, this.onChange});

  final List<({String value, String name})> items;
  final String value;
  final ValueChanged<String>? onChange;

  @override
  State<LocaleMenu> createState() => _LocaleMenuState();
}

class _LocaleMenuState extends State<LocaleMenu> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.items.where((i) => i.value == widget.value).firstOrNull;
    // `w-56 text-right` around an inline-block trigger, which may be wider than the box.
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 224),
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        widthFactor: 1,
        child: DifyDropdownMenu(
          placement: DifyPlacement.bottomEnd,
          sideOffset: 8,
          width: 200,
          builder: (context, controller) => Semantics(
            button: true,
            label: selected?.name ?? '',
            onTap: controller.toggle,
            excludeSemantics: true,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: GestureDetector(
                key: const ValueKey('locale-menu'),
                onTap: controller.toggle,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _hover ? DifyColors.stateBaseHover : null,
                    border: Border.all(color: DifyColors.componentsButtonSecondaryBorder),
                    borderRadius: BorderRadius.circular(DifyRadius.lg),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: EdgeInsetsDirectional.only(end: 4),
                        child: HeroIcon('globe-alt', size: 20, color: DifyColors.textPrimary),
                      ),
                      Text(
                        selected?.name ?? '',
                        // `text-[13px] font-medium` (the row: the size-5 icon's 20 px)
                        style: difyTextStyle(DifyTw.text13MediumLeading20, DifyColors.textPrimary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          children: [
            DifyMenuRadioGroup<String>(
              value: widget.value,
              onValueChange: widget.onChange,
              children: [
                for (final i in widget.items)
                  DifyMenuRadioItem<String>(
                    value: i.value,
                    closeOnClick: true,
                    child: Text(i.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---- frames -------------------------------------------------------------------------------------------------------

/// signin/_header.tsx: `flex w-full items-center justify-between p-6`, the Dify logo (`large`), then (`gap-1`) the
/// locale menu, a vertical divider (`mx-0 ml-2 h-4`) and the [ThemeSelector] (when the app provides a theme).
class SignInHeader extends StatelessWidget {
  const SignInHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final locale = AppLocaleScope.read(context);
    final theme = AppThemeScope.of(context);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      // role="banner"
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            const DifyLogo(alt: 'Dify', size: DifyLogoSize.large),
            const Spacer(),
            LocaleMenu(
              items: AppLocale.supported,
              value: AppLocaleScope.of(context),
              onChange: locale == null ? null : (v) => locale.set(v),
            ),
            if (theme != null) ...[
              const SizedBox(width: 4),
              const DifyDivider.vertical(margin: EdgeInsets.only(left: 8), length: 16),
              const SizedBox(width: 4),
              ThemeSelector(theme: theme),
            ],
          ],
        ),
      ),
    );
  }
}

/// base/theme-selector.tsx: an `IconButton size=lg` named "Theme" showing the current choice's icon (`size-4
/// text-text-tertiary`: sun, moon, computer; `bg-state-base-hover` while open), opening `bottom-end` 6 px away a
/// `w-36` radio group: light, dark, system (`theme.auto`), each closing the menu.
class ThemeSelector extends StatelessWidget {
  const ThemeSelector({super.key, required this.theme});

  final AppTheme theme;

  static String _icon(DifyThemeMode mode) => switch (mode) {
    DifyThemeMode.light => 'sun-line',
    DifyThemeMode.dark => 'moon-line',
    DifyThemeMode.system => 'computer-line',
  };

  @override
  Widget build(BuildContext context) {
    AppLocaleScope.of(context);
    String tr(String key) => DifyI18n.tr('common', key);
    Widget item(DifyThemeMode mode, String key) => DifyMenuRadioItem<DifyThemeMode>(
      key: ValueKey('theme-${mode.name}'),
      value: mode,
      closeOnClick: true,
      leading: RemixIcon(_icon(mode), size: 16, color: DifyColors.textTertiary),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(tr(key), style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textSecondary)),
      ),
    );
    return DifyDropdownMenu(
      placement: DifyPlacement.bottomEnd,
      sideOffset: 6,
      width: 144 - 2 * Css.hairline,
      builder: (context, controller) => DifyIconButton(
        key: const ValueKey('theme-selector'),
        label: tr('theme.theme'),
        size: DifyIconButtonSize.lg,
        onPressed: controller.toggle,
        restyle: controller.isOpen ? (look, _) => look.copyWith(background: DifyColors.stateBaseHover) : null,
        icon: RemixIcon(_icon(theme.mode), size: 16, color: DifyColors.textTertiary),
      ),
      children: [
        DifyMenuRadioGroup<DifyThemeMode>(
          value: theme.mode,
          onValueChange: (mode) => unawaited(theme.set(mode)),
          children: [
            item(DifyThemeMode.light, 'theme.light'),
            item(DifyThemeMode.dark, 'theme.dark'),
            item(DifyThemeMode.system, 'theme.auto'),
          ],
        ),
      ],
    );
  }
}

/// The header's height: `p-6` around the locale menu's trigger (`py-1.5`, a 20 px line, the border).
const signInHeaderHeight = 24 + 34 + 24.0;

/// `© {year} LangGenius, Inc. All rights reserved.` (Dify shows it while branding is off, as in the community edition).
String difyCopyright() => '© ${DateTime.now().year} LangGenius, Inc. All rights reserved.';

/// The page background and card shared by the sign-in, install and activate pages: `flex min-h-screen w-full
/// justify-center bg-background-default-burn p-6` around `rounded-2xl border border-effects-highlight
/// bg-background-default-subtle`.
class _AuthCard extends StatelessWidget {
  const _AuthCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: ColoredBox(
      color: DifyColors.backgroundDefaultBurn,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: DifyColors.backgroundDefaultSubtle,
            border: Border.all(color: DifyColors.effectsHighlight),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(1),
            child: DefaultTextStyle.merge(
              style: difyTextStyle(DifyTw.trackingNormal, DifyColors.textPrimary),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

/// signin/layout.tsx: the card with the header, the content centred in `<main>` (`px-6 md:px-27`, `w-full md:w-100`)
/// and the copyright footer (`px-8 py-6 system-xs-regular text-text-tertiary`).
class SignInLayout extends StatelessWidget {
  const SignInLayout({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final md = _md(context);
    return _AuthCard(
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          child: Column(
            children: [
              const SignInHeader(),
              // `<main className="grow">`: the space between the header and the footer, the content centred in it.
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: math.max(0, c.maxHeight - signInHeaderHeight - 64)),
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  // role="main"
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: md ? 108 : 24),
                    child: Center(
                      child: SizedBox(width: md ? 400 : double.infinity, child: child),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                child: Text(
                  difyCopyright(),
                  style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// install/page.tsx and activate/page.tsx: the card (`flex-col`) with the header, [child] and the copyright
/// (`px-8 py-6 text-sm text-text-tertiary`; at the bottom (`mt-auto`) when [footerAtBottom]).
class AuthPageFrame extends StatelessWidget {
  const AuthPageFrame({super.key, required this.child, this.footerAtBottom = true});
  final Widget child;
  final bool footerAtBottom;

  @override
  Widget build(BuildContext context) => _AuthCard(
    child: LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SignInHeader(),
            ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: footerAtBottom ? math.max(0, c.maxHeight - signInHeaderHeight - 68) : 0,
              ),
              child: child,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Text(
                difyCopyright(),
                style: difyTextStyle(DifyType.systemMdRegular, DifyColors.textTertiary), // `text-sm font-normal`
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Submits on Enter from any field of the form (a browser submits a form on Enter in a text input).
class AuthSubmitOnEnter extends StatelessWidget {
  const AuthSubmitOnEnter({super.key, required this.onSubmit, required this.child});
  final VoidCallback onSubmit;
  final Widget child;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.enter): onSubmit,
      const SingleActivator(LogicalKeyboardKey.numpadEnter): onSubmit,
    },
    child: AutofillGroup(child: child),
  );
}
