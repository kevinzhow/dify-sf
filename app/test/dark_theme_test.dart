// The dark theme switch (Dify's next-themes `theme`: light | dark | system): the tokens follow DifyColors.useDark,
// DifyTheme.apply rebuilds const subtrees and repaints painters that never repaint on their own, the canvas starts its
// renderer over (also mid-drag and mid-run), and AppTheme remembers the choice, follows the platform in system mode
// and takes the `--theme` / `?theme=` launch option.
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme_mode.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/launch_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_fonts.dart';

class _Swatch extends StatelessWidget {
  const _Swatch();

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: DifyColors.componentsPanelBg, child: const SizedBox(width: 10));
}

class _NeverRepaints extends CustomPainter {
  _NeverRepaints(this.seen);
  final List<Color> seen;

  @override
  void paint(Canvas canvas, Size size) => seen.add(DifyColors.textPrimary);

  @override
  bool shouldRepaint(_NeverRepaints old) => false;
}

class _Painted extends StatefulWidget {
  const _Painted(this.seen);
  final List<Color> seen;

  @override
  State<_Painted> createState() => _PaintedState();
}

class _PaintedState extends State<_Painted> {
  late final _painter = _NeverRepaints(widget.seen);

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _painter, size: const Size(10, 10));
}

Future<void> settle(WidgetTester t, [int steps = 20]) async {
  for (var i = 0; i < steps; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<DemoBackend> openEditor(WidgetTester t) async {
  await useAppFonts();
  t.view.physicalSize = const Size(1600, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final demo = DemoBackend(withBo: false);
  await t.pumpWidget(
    MaterialApp(
      home: EditorPage(backend: demo, docId: 'demo', clientId: 'me-abc123', journaled: false),
    ),
  );
  await settle(t);
  return demo;
}

Future<void> closeEditor(WidgetTester t, DemoBackend demo) async {
  await t.pumpWidget(const SizedBox());
  await demo.dispose();
  await t.pump(const Duration(seconds: 20));
}

/// The card's own surface (card_chrome.dart: `bg-workflow-block-bg`) under the widgets renderer's node.
Iterable<Color?> cardColors(WidgetTester t, String id) => t
    .widgetList<Container>(find.descendant(of: find.byKey(ValueKey('node-$id')), matching: find.byType(Container)))
    .map((c) => (c.decoration as BoxDecoration?)?.color);

void main() {
  tearDown(() => DifyColors.useDark(false));

  test('the tokens answer the dark values of Dify 1.17.1 while the switch is on', () {
    expect(DifyColors.isDark, isFalse);
    expect(DifyColors.textPrimary, const Color(0xFF101828));
    expect(DifyColors.workflowCanvasWorkflowBg, const Color(0xFFF2F4F7));
    DifyColors.useDark(true);
    expect(DifyColors.isDark, isTrue);
    expect(DifyColors.textPrimary, const Color(0xFFFBFBFC));
    expect(DifyColors.componentsPanelBg, const Color(0xFF222225));
    expect(DifyColors.workflowBlockBg, const Color(0xFF27272B));
    expect(DifyColors.workflowCanvasWorkflowBg, const Color(0xFF1D1D20));
    expect(DifyGradients.chatBubbleBg.colors.first, const Color(0xFF2A2B30));
  });

  testWidgets('apply rebuilds const subtrees and repaints painters that never repaint by themselves', (t) async {
    final seen = <Color>[];
    await t.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Column(children: [_Swatch()]),
      ),
    );
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(children: [const _Swatch(), _Painted(seen)]),
      ),
    );
    expect(t.widget<ColoredBox>(find.byType(ColoredBox)).color, const Color(0xFFFFFFFF));
    expect(seen.last, const Color(0xFF101828));
    await DifyTheme.apply(true);
    await t.pump();
    expect(t.widget<ColoredBox>(find.byType(ColoredBox)).color, const Color(0xFF222225));
    expect(seen.last, const Color(0xFFFBFBFC));
    await DifyTheme.apply(false);
    await t.pump();
    expect(t.widget<ColoredBox>(find.byType(ColoredBox)).color, const Color(0xFFFFFFFF));
    expect(seen.last, const Color(0xFF101828));
  });

  testWidgets('a theme switch starts the canvas renderer over: cards in the new colours, also mid-drag and mid-run', (
    t,
  ) async {
    final demo = await openEditor(t);
    final state = t.state<WorkflowCanvasState>(find.byType(WorkflowCanvas));
    expect(cardColors(t, 'llm'), contains(const Color(0xFFFCFCFD)));
    final first = state.renderer;

    // A run in progress: a running node keeps its status border through the switch.
    state.setStatus('start', 'running');
    await t.pump();
    expect(find.byKey(const Key('status-border-start')), findsOneWidget);

    // Mid-drag: the new renderer takes the moving node over, the drag goes on and lands.
    final before = demo.server.doc.nodes['llm']!;
    final g = await t.startGesture(t.getCenter(find.byKey(const ValueKey('node-llm'))));
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(10, 6));
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(state.input.moving, isNotEmpty);
    await DifyTheme.apply(true);
    await t.pump();
    expect(state.renderer, isNot(same(first)));
    // The card's surfaces: #fcfcfd in light, #222225 (background-default-subtle / components-card-bg) in dark.
    expect(cardColors(t, 'llm'), isNot(contains(const Color(0xFFFCFCFD))));
    expect(cardColors(t, 'llm'), contains(const Color(0xFF222225)));
    expect(find.byKey(const Key('status-border-start')), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(10, 6));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await settle(t);
    final after = demo.server.doc.nodes['llm']!;
    expect(after.x, greaterThan(before.x + 50));
    expect(after.y, greaterThan(before.y + 30));
    expect(state.input.moving, isEmpty);
    expect(t.takeException(), isNull);

    // And back.
    await DifyTheme.apply(false);
    await t.pump();
    expect(cardColors(t, 'llm'), contains(const Color(0xFFFCFCFD)));
    await closeEditor(t, demo);
  });

  group('AppTheme', () {
    testWidgets('defaults to system: the platform brightness, followed live', (t) async {
      SharedPreferences.setMockInitialValues({});
      t.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
      final theme = await AppTheme.load();
      addTearDown(theme.dispose);
      expect(theme.mode, DifyThemeMode.system);
      expect(DifyColors.isDark, isTrue);
      var notified = 0;
      theme.addListener(() => notified++);
      t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await t.pump();
      expect(DifyColors.isDark, isFalse);
      expect(notified, 1);
    });

    testWidgets('remembers the choice as `theme` and restores it; a fixed choice ignores the platform', (t) async {
      SharedPreferences.setMockInitialValues({});
      final theme = await AppTheme.load();
      addTearDown(theme.dispose);
      await theme.set(DifyThemeMode.dark);
      expect(DifyColors.isDark, isTrue);
      expect((await SharedPreferences.getInstance()).getString('theme'), 'dark');
      t.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(t.platformDispatcher.clearPlatformBrightnessTestValue);
      await t.pump();
      expect(DifyColors.isDark, isTrue);
      DifyColors.useDark(false);
      final restored = await AppTheme.load();
      addTearDown(restored.dispose);
      expect(restored.mode, DifyThemeMode.dark);
      expect(DifyColors.isDark, isTrue);
      await restored.set(DifyThemeMode.light);
      expect(DifyColors.isDark, isFalse);
      expect((await SharedPreferences.getInstance()).getString('theme'), 'light');
    });

    testWidgets('the launch option wins over the remembered choice for this run, without replacing it', (t) async {
      SharedPreferences.setMockInitialValues({'theme': 'light'});
      expect(LaunchOptions.parse(['--theme', 'dark']).theme, 'dark');
      expect(LaunchOptions.fromQuery({'theme': 'dark'}).theme, 'dark');
      final theme = await AppTheme.load(override: LaunchOptions.fromQuery({'theme': 'dark'}).theme);
      addTearDown(theme.dispose);
      expect(theme.mode, DifyThemeMode.dark);
      expect(DifyColors.isDark, isTrue);
      expect((await SharedPreferences.getInstance()).getString('theme'), 'light');
      expect(DifyThemeMode.parse('nonsense'), isNull);
    });
  });
}
