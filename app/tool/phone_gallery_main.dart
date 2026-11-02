// dify-sf phone component gallery: every phone building block of app/lib/src/design on one scrollable page, plus the
// sheets and an edge-to-edge page, for screenshots on a device. A dev tool: the app never imports it.
//
//   flutter run -t tool/phone_gallery_main.dart            (an Android device or emulator)
//   flutter run -t tool/phone_gallery_main.dart -d linux   (desktop: the same page in a window)
import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/dify_theme_mode.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/platform_input.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Starts like lib/main.dart: platform input, the UI strings, the system theme, Dify's font stack (the system UI
/// font; Noto Sans on Linux and the web, whose CJK subsets load on the web only).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDifyPlatformInput();
  const lang = 'en-US';
  await Future.wait([if (kIsWeb) DifyFonts.loadFor(lang), DifyI18n.load(lang)]);
  DifyColors.useDark(WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark);
  cardFontFamily ??= kIsWeb || defaultTargetPlatform == TargetPlatform.linux ? 'Noto Sans' : null;
  runApp(const PhoneGalleryApp());
}

/// The gallery app (public for its smoke test, test/dify_spec/dify_ui/phone_gallery_test.dart).
class PhoneGalleryApp extends StatefulWidget {
  const PhoneGalleryApp({super.key});

  @override
  State<PhoneGalleryApp> createState() => _GalleryAppState();
}

class _GalleryAppState extends State<PhoneGalleryApp> {
  final _toasts = DifyToastManager();

  Future<void> _toggleTheme() async {
    await DifyTheme.apply(!DifyColors.isDark);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => DifyApplication(
    title: 'dify-sf phone gallery',
    theme: difyTheme(
      fontFamily: cardFontFamily,
      fontFamilyFallback: DifyFonts.fallbackFamilies,
      brightness: DifyColors.isDark ? Brightness.dark : Brightness.light,
    ),
    home: _Gallery(onToggleTheme: _toggleTheme, toasts: _toasts),
    builder: (context, child) => Stack(
      fit: StackFit.expand,
      children: [
        child!,
        DifyToastHost(manager: _toasts),
      ],
    ),
  );
}

// ----- the gallery page -----

class _Gallery extends StatefulWidget {
  const _Gallery({required this.onToggleTheme, required this.toasts});
  final VoidCallback onToggleTheme;
  final DifyToastManager toasts;

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  String _query = '', _chip = 'All';
  String _view = 'steps';
  int _tab = 0, _touchTaps = 0;

  void _toast(String title) =>
      widget.toasts.add(DifyToastData(id: '${DateTime.now().microsecondsSinceEpoch}', title: title));

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return DifyPage(
      body: Column(
        children: [
          DifyTopAppBar.large(
            title: 'Phone gallery',
            actions: [
              DifyTouchIconButton(
                label: 'Theme',
                icon: RemixIcon(DifyColors.isDark ? 'sun-line' : 'moon-line', size: 22),
                onPressed: widget.onToggleTheme,
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                _Section(
                  'Window and touch',
                  child: DifyText(
                    '${size.width.round()} x ${size.height.round()} dp: ${DifyWindowClass.of(context).name}, '
                    '${DifyTouch.isCoarse(context) ? 'coarse' : 'fine'} pointer, min target ${DifyTouch.minTarget.round()} dp',
                    DifyType.systemSmRegular,
                    color: DifyColors.textSecondary,
                    maxLines: 2,
                  ),
                ),
                _Section(
                  'Open',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _open('Sheet: half', () => _openSettingsSheet(context, DifySheetDetent.half)),
                      _open('Sheet: full', () => _openVariablesSheet(context)),
                      _open('Sheet: keyboard', () => _openKeyboardSheet(context)),
                      _open('Action sheet', () => _openActionSheet(context)),
                      _open('Persistent peek sheet', () => _push(context, const _RunPage(), edgeToEdge: true)),
                      _open('Edge to edge: before', () => _push(context, const _BarsPage(edgeToEdge: false))),
                      _open(
                        'Edge to edge: after',
                        () => _push(context, const _BarsPage(edgeToEdge: true), edgeToEdge: true),
                      ),
                    ],
                  ),
                ),
                _Section(
                  'DifyTopAppBar',
                  child: _Framed(
                    child: DifyTopAppBar(
                      title: 'Self-host check',
                      subtitle: 'Saved · editing with Winnie',
                      leading: DifyAppBarBackButton(onPressed: () => _toast('Back')),
                      actions: _editorActions(),
                    ),
                  ),
                ),
                _Section(
                  'DifyTopAppBar.large',
                  child: _Framed(
                    child: DifyTopAppBar.large(
                      title: 'Studio',
                      actions: [
                        DifyTouchIconButton(
                          label: 'Search',
                          icon: const RemixIcon('search-line', size: 22),
                          onPressed: () {},
                        ),
                      ],
                    ),
                  ),
                ),
                _Section(
                  'DifySegmentedControl (touch size)',
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _ViewSwitch(value: _view, onChanged: (v) => setState(() => _view = v)),
                  ),
                ),
                _Section(
                  'DifyTouchTarget: a 24 px button with a 48 px hit area (taps: $_touchTaps)',
                  child: SizedBox(
                    height: 56,
                    child: Center(
                      child: DifyTouchTarget(
                        child: DifyIconButton(
                          label: 'Add',
                          icon: const RemixIcon('add-line', size: 16),
                          onPressed: () => setState(() => _touchTaps++),
                        ),
                      ),
                    ),
                  ),
                ),
                _Section(
                  'DifyFab',
                  child: Row(
                    spacing: 16,
                    children: [
                      DifyFab(
                        icon: const RemixIcon('add-line', size: 28),
                        label: 'Add step',
                        onPressed: () => _toast('Add step'),
                      ),
                      DifyFab.extended(
                        icon: const RemixIcon('add-line', size: 22),
                        label: 'Create',
                        onPressed: () => _toast('Create'),
                      ),
                      const DifyFab(icon: RemixIcon('add-line', size: 28), label: 'Disabled', disabled: true),
                    ],
                  ),
                ),
                _Section(
                  'DifyNavigationBar',
                  child: _Framed(
                    child: DifyNavigationBar(
                      destinations: _destinations,
                      selectedIndex: _tab,
                      onDestinationSelected: (i) => setState(() => _tab = i),
                    ),
                  ),
                ),
                _Section(
                  'DifyBottomToolbar',
                  child: _Framed(child: _toolbar(context)),
                ),
                _Section(
                  'DifySelectionBar',
                  child: _Framed(child: _selectionBar(() => _toast('Selection closed'))),
                ),
                _Section(
                  'DifySheetHeader (with a tabs row)',
                  child: _Framed(child: _settingsHeader(onClose: () => _toast('Close'))),
                ),
                _Section(
                  'DifyCountBadge',
                  child: const Row(spacing: 8, children: [DifyCountBadge(1), DifyCountBadge(12), DifyCountBadge(120)]),
                ),
                _Section(
                  'DifyTopAppBar.search',
                  child: _Framed(
                    child: DifyTopAppBar.search(
                      onBack: () => _toast('Search closed'),
                      field: DifySearchInput(
                        value: _query,
                        height: 40,
                        onValueChange: (v) => setState(() => _query = v),
                      ),
                    ),
                  ),
                ),
                _Section(
                  'DifyChipBar / DifyFilterChip',
                  child: DifyChipBar(
                    children: [
                      for (final c in const ['All', 'Workflow', 'Chatflow'])
                        DifyFilterChip(label: c, selected: _chip == c, onPressed: () => setState(() => _chip = c)),
                      DifyFilterChip(
                        label: 'Creators',
                        leading: const RemixIcon('filter-3-line', size: 16),
                        onPressed: () => _toast('Creators'),
                      ),
                      DifyFilterChip(
                        label: 'Last modified',
                        leading: const RemixIcon('sort-desc', size: 16),
                        onPressed: () => _toast('Sort'),
                      ),
                    ],
                  ),
                ),
                _Section(
                  'DifyListRow / DifyListSectionHeader',
                  child: ColoredBox(
                    color: DifyColors.componentsPanelBg,
                    child: Column(
                      children: [
                        DifyListRow(
                          leading: const RemixIcon('group-2-line', size: 20),
                          title: 'Members',
                          trailing: const [DifyListChevron()],
                          onTap: () => _toast('Members'),
                        ),
                        DifyListRow(
                          leading: DifyAppIcon(size: DifyAppIconSize.large, iconType: 'emoji', icon: '🧪'),
                          title: 'Self-host check',
                          subtitle: 'Workflow · Edited at 22:52',
                          strong: true,
                          onTap: () => _toast('Open'),
                          onLongPress: () => _toast('Long press'),
                          actions: [
                            DifyTouchIconButton(
                              label: 'More actions for Self-host check',
                              icon: const RemixIcon('more-fill', size: 20),
                              onPressed: () => _toast('More'),
                            ),
                          ],
                        ),
                        const DifyListSectionHeader('Account'),
                        DifyListRow(
                          leading: const RemixIcon('shut-down-line', size: 20),
                          title: 'Log out',
                          destructive: true,
                          divider: false,
                          onTap: () => _toast('Log out'),
                        ),
                      ],
                    ),
                  ),
                ),
                _Section(
                  'DifyRefreshIndicator (pull the list)',
                  child: SizedBox(
                    height: 160,
                    child: DifyRefreshIndicator(
                      onRefresh: () => Future<void>.delayed(const Duration(seconds: 1), () => _toast('Refreshed')),
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [for (var i = 0; i < 3; i++) DifyListRow(title: 'Row ${i + 1}')],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _open(String label, VoidCallback onPressed) => DifyButton(
    size: DifyButtonSize.large,
    onPressed: onPressed,
    child: DifyTextLine(label),
  );

  Widget _toolbar(BuildContext context) => DifyBottomToolbar(
    actions: [
      DifyToolbarAction(
        icon: const RemixIcon('arrow-go-back-line', size: 22),
        label: 'Undo',
        onTap: () => _toast('Undo'),
      ),
      const DifyToolbarAction(icon: RemixIcon('arrow-go-forward-fill', size: 22), label: 'Redo', enabled: false),
      DifyToolbarAction(
        icon: const RemixIcon('sticky-note-add-line', size: 22),
        label: 'Note',
        onTap: () => _toast('Note'),
      ),
      DifyToolbarAction(
        icon: const RemixIcon('history-line', size: 22),
        label: 'Versions',
        onTap: () => _toast('Versions'),
      ),
    ],
    center: DifyFab(
      icon: const RemixIcon('add-line', size: 28),
      label: 'Add step',
      onPressed: () => _openAddSheet(context),
    ),
  );

  Widget _selectionBar(VoidCallback onClose) => DifySelectionBar(
    leading: const _Block(icon: 'code-s-slash-line'),
    title: 'Count Android',
    subtitle: 'selected',
    onClose: onClose,
    actions: [
      DifyToolbarAction(
        icon: const RemixIcon('settings-3-line', size: 22),
        label: 'Settings',
        onTap: () => _toast('Settings'),
      ),
      DifyToolbarAction(
        icon: const RemixIcon('play-line', size: 22),
        label: 'Run step',
        onTap: () => _toast('Run step'),
      ),
      DifyToolbarAction(
        icon: RemixIcon('add-circle-fill', size: 22, color: DifyColors.textAccent),
        label: 'Add next',
        onTap: () => _toast('Add next'),
      ),
      DifyToolbarAction(
        icon: const RemixIcon('links-line', size: 22),
        label: 'Connect…',
        onTap: () => _toast('Connect'),
      ),
      DifyToolbarAction(
        icon: const RemixIcon('file-copy-line', size: 22),
        label: 'Duplicate',
        onTap: () => _toast('Duplicate'),
      ),
      DifyToolbarAction(
        icon: const RemixIcon('delete-bin-line', size: 22),
        label: 'Delete',
        destructive: true,
        onTap: () => _toast('Delete'),
      ),
    ],
  );

  List<Widget> _editorActions() => [
    DifyButton(
      variant: DifyButtonVariant.primary,
      size: DifyButtonSize.large,
      leading: const RemixIcon('play-large-fill', size: 16),
      onPressed: () => _toast('Run'),
      child: const DifyTextLine('Run'),
    ),
    DifyTouchIconButton(
      label: 'More',
      icon: const RemixIcon('more-fill', size: 22),
      onPressed: () => _openActionSheet(context),
    ),
  ];

  // ----- sheets -----

  Widget _settingsHeader({VoidCallback? onClose}) => DifySheetHeader(
    leading: const _Block(icon: 'sparkling-fill', size: 30),
    title: 'Summarize',
    subtitle: 'LLM',
    onClose: onClose,
    actions: [
      DifyTouchIconButton(label: 'Run step', icon: const RemixIcon('play-line', size: 20), onPressed: () {}),
      DifyTouchIconButton(label: 'More', icon: const RemixIcon('more-fill', size: 20), onPressed: () {}),
    ],
    tabs: SizedBox(
      height: 40,
      child: Row(
        spacing: 22,
        children: [
          DifyText('Settings', DifyType.systemMdSemibold, color: DifyColors.textPrimary),
          DifyText('Last run', DifyType.systemMdRegular, color: DifyColors.textTertiary),
        ],
      ),
    ),
  );

  void _openSettingsSheet(BuildContext context, DifySheetDetent initial) => showDifyBottomSheet<void>(
    context,
    (context) => Column(
      children: [
        _settingsHeader(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final label in [
                'Model',
                'Context',
                'System prompt',
                'Vision',
                'Structured output',
                'Retry on failure',
              ])
                SizedBox(
                  height: 52,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: DifyText(label, DifyType.bodyLgRegular, color: DifyColors.textSecondary),
                  ),
                ),
              for (var i = 0; i < 12; i++)
                SizedBox(
                  height: 48,
                  child: DifyText('Field $i', DifyType.bodyMdRegular, color: DifyColors.textTertiary),
                ),
            ],
          ),
        ),
      ],
    ),
    detents: const [DifySheetDetent.half, DifySheetDetent.full],
    initialDetent: initial,
  );

  void _openVariablesSheet(BuildContext context) => showDifyBottomSheet<void>(
    context,
    (context) => Column(
      children: [
        const DifySheetHeader(title: 'Insert variable'),
        Expanded(
          child: ListView(
            children: [
              for (final (node, vars) in [
                ('Count Android', ['words', 'python']),
                ('Start', ['text', 'sys.user_id', 'sys.files']),
                ('Environment', ['SVC_BASE']),
              ]) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: DifyText(node, DifyType.systemSmSemibold, color: DifyColors.textTertiary),
                ),
                for (final v in vars)
                  SizedBox(
                    height: 48,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 52, right: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: DifyText(v, DifyType.bodyLgRegular, color: DifyColors.textPrimary),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    ),
  );

  void _openKeyboardSheet(BuildContext context) => showDifyBottomSheet<void>(
    context,
    (context) => Column(
      children: [
        const DifySheetHeader(title: 'Rename', subtitle: 'The sheet grows with the keyboard'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (var i = 0; i < 4; i++)
                SizedBox(height: 48, child: DifyText('Row $i', DifyType.bodyMdRegular, color: DifyColors.textTertiary)),
              const _RenameField(),
            ],
          ),
        ),
      ],
    ),
    detents: const [DifySheetDetent.half, DifySheetDetent.full],
  );

  void _openAddSheet(BuildContext context) => showDifyBottomSheet<void>(
    context,
    (context) => Column(
      children: [
        const DifySheetHeader(title: 'Add step', subtitle: 'after Count Android · connects automatically'),
        Expanded(
          child: ListView(
            children: [
              for (final (name, icon) in [
                ('LLM', 'sparkling-fill'),
                ('Knowledge Retrieval', 'book-open-line'),
                ('IF/ELSE', 'git-branch-line'),
                ('Code', 'code-s-slash-line'),
                ('HTTP Request', 'global-line'),
              ])
                SizedBox(
                  height: 60,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      spacing: 12,
                      children: [
                        _Block(icon: icon, size: 32),
                        DifyText(name, DifyType.systemMdSemibold, color: DifyColors.textPrimary),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
    detents: const [DifySheetDetent.half, DifySheetDetent.full],
  );

  void _openActionSheet(BuildContext context) => showDifyActionSheet(
    context,
    title: 'Self-host check',
    actions: [
      DifyActionSheetAction(
        icon: const RemixIcon('edit-line', size: 20),
        label: 'Rename',
        onTap: () => _toast('Rename'),
      ),
      DifyActionSheetAction(
        icon: const RemixIcon('file-copy-line', size: 20),
        label: 'Duplicate',
        onTap: () => _toast('Duplicate'),
      ),
      const DifyActionSheetAction(icon: RemixIcon('download-2-line', size: 20), label: 'Export DSL', enabled: false),
      DifyActionSheetAction(
        icon: const RemixIcon('delete-bin-line', size: 20),
        label: 'Delete',
        destructive: true,
        onTap: () => _toast('Delete'),
      ),
    ],
  );
}

void _push(BuildContext context, Widget page, {bool edgeToEdge = false}) =>
    Navigator.of(context).push(difyPageRoute<void>(builder: (_) => page, edgeToEdge: edgeToEdge));

const _destinations = [
  DifyNavigationDestination(icon: RemixIcon('apps-2-line', size: 22), label: 'Studio'),
  DifyNavigationDestination(icon: RemixIcon('puzzle-2-line', size: 22), label: 'Integrations', badgeCount: 2),
  DifyNavigationDestination(icon: RemixIcon('user-line', size: 22), label: 'Account'),
];

class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => DifySegmentedControl<String>(
    value: value,
    size: DifySegmentedControlSize.touch,
    semanticLabel: 'View',
    onChanged: onChanged,
    segments: const [
      (
        value: 'steps',
        label: 'Steps',
        child: DifySegmentLabel(icon: RemixIcon('list-unordered', size: 16), text: 'Steps'),
      ),
      (
        value: 'canvas',
        label: 'Canvas',
        child: DifySegmentLabel(icon: RemixIcon('flow-chart', size: 16), text: 'Canvas'),
      ),
    ],
  );
}

// ----- the bars page: before (safe area) and after (edge to edge) -----

/// A phone page with every bar: the app bar, a list, the extended FAB, the editor toolbar with its FAB (or the
/// selection bar while a row is selected) and the bottom navigation. Pushed edge to edge, the bars paint under the
/// status and navigation bars; pushed the old way, grey app-background bands stay above and below.
class _BarsPage extends StatefulWidget {
  const _BarsPage({required this.edgeToEdge});
  final bool edgeToEdge;

  @override
  State<_BarsPage> createState() => _BarsPageState();
}

class _BarsPageState extends State<_BarsPage> {
  int _tab = 0;
  int? _selected;
  String _view = 'steps';

  @override
  Widget build(BuildContext context) => DifyPage(
    edgeToEdge: widget.edgeToEdge,
    backgroundColor: DifyColors.componentsPanelBg,
    body: Column(
      children: [
        DifyTopAppBar(
          title: 'Self-host check',
          subtitle: widget.edgeToEdge ? 'Edge to edge (after)' : 'Inside the safe area (before)',
          backgroundColor: DifyColors.backgroundBody,
          actions: [
            DifyButton(
              variant: DifyButtonVariant.primary,
              size: DifyButtonSize.large,
              leading: const RemixIcon('play-large-fill', size: 16),
              onPressed: () {},
              child: const DifyTextLine('Run'),
            ),
          ],
        ),
        ColoredBox(
          color: DifyColors.backgroundBody,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _ViewSwitch(value: _view, onChanged: (v) => setState(() => _view = v)),
            ),
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final (i, name) in ['Start', 'Count Android', 'Has words?', 'Summarize', 'End'].indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: DifyPressable(
                        onPressed: () => setState(() => _selected = _selected == i ? null : i),
                        builder: (context, hovered, focused) => Container(
                          height: 64,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: DifyColors.componentsPanelBg,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: _selected == i ? DifyColors.textAccent : DifyColors.componentsPanelBorder,
                              width: _selected == i ? 2 : 1,
                            ),
                          ),
                          child: Row(
                            spacing: 12,
                            children: [
                              const _Block(icon: 'code-s-slash-line', size: 32),
                              DifyText(name, DifyType.systemMdSemibold, color: DifyColors.textPrimary),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (_selected == null)
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: DifyFab.extended(
                    icon: const RemixIcon('add-line', size: 22),
                    label: 'Create',
                    onPressed: () {},
                  ),
                ),
            ],
          ),
        ),
        if (_selected case final s?)
          DifySelectionBar(
            title: ['Start', 'Count Android', 'Has words?', 'Summarize', 'End'][s],
            subtitle: 'selected',
            leading: const _Block(icon: 'code-s-slash-line'),
            onClose: () => setState(() => _selected = null),
            actions: [
              DifyToolbarAction(icon: const RemixIcon('settings-3-line', size: 22), label: 'Settings', onTap: () {}),
              DifyToolbarAction(icon: const RemixIcon('file-copy-line', size: 22), label: 'Duplicate', onTap: () {}),
              DifyToolbarAction(
                icon: const RemixIcon('delete-bin-line', size: 22),
                label: 'Delete',
                destructive: true,
                onTap: () => setState(() => _selected = null),
              ),
            ],
          )
        else
          DifyBottomToolbar(
            actions: [
              DifyToolbarAction(icon: const RemixIcon('arrow-go-back-line', size: 22), label: 'Undo', onTap: () {}),
              const DifyToolbarAction(
                icon: RemixIcon('arrow-go-forward-fill', size: 22),
                label: 'Redo',
                enabled: false,
              ),
              DifyToolbarAction(icon: const RemixIcon('sticky-note-add-line', size: 22), label: 'Note', onTap: () {}),
              DifyToolbarAction(icon: const RemixIcon('history-line', size: 22), label: 'Versions', onTap: () {}),
            ],
            center: DifyFab(icon: const RemixIcon('add-line', size: 28), label: 'Add step', onPressed: () {}),
          ),
        DifyNavigationBar(
          destinations: _destinations,
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
        ),
      ],
    ),
  );
}

// ----- the run page: a persistent peek sheet over an interactive page -----

class _RunPage extends StatefulWidget {
  const _RunPage();

  @override
  State<_RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<_RunPage> {
  final _sheet = DifySheetController();
  int _taps = 0;

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DifyPage(
    edgeToEdge: true,
    body: Stack(
      fit: StackFit.expand,
      children: [
        Column(
          children: [
            DifyTopAppBar(
              title: 'Self-host check',
              subtitle: 'Test run · 4.1 s',
              backgroundColor: DifyColors.backgroundBody,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  DifyText(
                    'The page stays interactive behind the sheet (taps: $_taps)',
                    DifyType.systemSmRegular,
                    color: DifyColors.textTertiary,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 8),
                  for (final name in ['Start', 'Count Android', 'Has words?', 'Summarize', 'End'])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: DifyButton(
                        size: DifyButtonSize.large,
                        onPressed: () => setState(() => _taps++),
                        child: DifyTextLine(name),
                      ),
                    ),
                  DifyButton(
                    variant: DifyButtonVariant.secondaryAccent,
                    onPressed: () => _sheet.animateTo(DifySheetDetent.full),
                    child: const DifyTextLine('Expand the result'),
                  ),
                ],
              ),
            ),
          ],
        ),
        DifyPersistentSheet(
          controller: _sheet,
          child: Column(
            children: [
              DifySheetHeader(
                title: 'Result',
                showClose: false,
                tabs: SizedBox(
                  height: 36,
                  child: DifyToolbarStrip(
                    child: Row(
                      spacing: 18,
                      children: [
                        for (final (i, tab) in ['Input', 'Result', 'Detail', 'Tracing'].indexed)
                          DifyText(
                            tab,
                            i == 1 ? DifyType.systemMdSemibold : DifyType.systemMdRegular,
                            color: i == 1 ? DifyColors.textPrimary : DifyColors.textTertiary,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    DifyText(
                      'The input "hello from phone" is a short greeting sent from a mobile device.',
                      DifyType.bodyMdRegular,
                      color: DifyColors.textSecondary,
                      maxLines: null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ----- helpers -----

/// The keyboard sheet's field: the design system's input (controlled, like every DifyInput).
class _RenameField extends StatefulWidget {
  const _RenameField();

  @override
  State<_RenameField> createState() => _RenameFieldState();
}

class _RenameFieldState extends State<_RenameField> {
  String _value = 'Self-host check';

  @override
  Widget build(BuildContext context) => DifyInput(
    value: _value,
    placeholder: 'App name',
    semanticLabel: 'App name',
    onChanged: (v) => setState(() => _value = v),
  );
}

class _Section extends StatelessWidget {
  const _Section(this.title, {required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        DifyText(title, DifyType.systemXsSemiboldUppercase, color: DifyColors.textTertiary, maxLines: 2),
        child,
      ],
    ),
  );
}

/// A sample bar in a frame, laid out without the system insets (they belong to the gallery page, not the sample).
class _Framed extends StatelessWidget {
  const _Framed({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: DifyColors.backgroundBody,
      border: Border.all(color: DifyColors.dividerRegular),
      borderRadius: BorderRadius.circular(DifyRadius.lg),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(DifyRadius.lg),
      child: MediaQuery.removePadding(
        context: context,
        removeLeft: true,
        removeTop: true,
        removeRight: true,
        removeBottom: true,
        child: child,
      ),
    ),
  );
}

/// A node icon tile, as the steps list draws it.
class _Block extends StatelessWidget {
  const _Block({required this.icon, this.size = 22});
  final String icon;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: DifyColors.textAccent, borderRadius: BorderRadius.circular(size * 0.25)),
    alignment: Alignment.center,
    child: RemixIcon(icon, size: size * 0.6, color: DifyColors.componentsPanelBg),
  );
}
