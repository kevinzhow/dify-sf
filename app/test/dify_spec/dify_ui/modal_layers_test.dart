// dify-sf phone layout (no Dify spec), batch 4a round 2: modal layers shown from a page's tree (DifySheetPortal, a
// picker sheet, DifyPortalPage) nest, and for accessibility only the topmost one is in the tree the platform gets:
// every layer below it, the page included, is hidden, and the topmost is never missing.

import 'phone_harness.dart';
import '../../support/platform_semantics.dart';

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

/// A page whose sheet ("Settings") holds the layers a node's settings hold: a nested sheet's trigger outside the
/// scrolling body (as the environment variables' Add), and in the body a select, a picker inside another picker's
/// trigger (as the model selector inside Model Settings' trigger), an editor that expands into a page, and rows
/// before and after them.
class _Layers extends StatefulWidget {
  const _Layers();

  @override
  State<_Layers> createState() => _LayersState();
}

class _LayersState extends State<_Layers> {
  bool open = false;
  bool expanded = false;
  String type = 'a';

  Widget _editor() => const SizedBox(height: 48, child: DifyTextLine('Inline code'));

  @override
  Widget build(BuildContext context) => DifyPage(
    edgeToEdge: true,
    body: Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: DifyButton(onPressed: () => setState(() => open = true), child: const DifyTextLine('Open')),
        ),
        DifySheetPortal(
          open: open,
          detents: const [DifySheetDetent.full],
          onDismiss: () => setState(() => open = false),
          builder: (context) => Column(
            children: [
              DifySheetHeader(title: 'Settings'),
              DifyFloating(
                sheetOnCompact: true,
                sheetTitle: 'Add variable',
                builder: (context, c) => DifyButton(onPressed: c.toggle, child: const DifyTextLine('Create')),
                popupBuilder: (context) => const Padding(
                  padding: EdgeInsets.all(16),
                  child: DifyTextLine('Variable form'),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    const SizedBox(height: 48, child: DifyTextLine('Row before')),
                    DifySelect<String>(
                      value: type,
                      semanticLabel: 'Type',
                      options: const [(value: 'a', label: 'Alpha'), (value: 'b', label: 'Beta')],
                      onChanged: (v) => setState(() => type = v),
                    ),
                    DifyFloating(
                      sheetOnCompact: true,
                      sheetTitle: 'Model settings',
                      builder: (context, settings) => Row(
                        children: [
                          DifyFloating(
                            sheetOnCompact: true,
                            sheetTitle: 'Configure model',
                            builder: (context, c) =>
                                DifyButton(onPressed: c.toggle, child: const DifyTextLine('Model')),
                            popupBuilder: (context) => const SizedBox(height: 48, child: DifyTextLine('model-a')),
                          ),
                          DifyButton(onPressed: settings.toggle, child: const DifyTextLine('Parameters')),
                        ],
                      ),
                      popupBuilder: (context) => const SizedBox(height: 48, child: DifyTextLine('Temperature')),
                    ),
                    DifyButton(onPressed: () => setState(() => expanded = true), child: const DifyTextLine('Expand')),
                    DifyPortalPage(
                      open: expanded,
                      onClose: () => setState(() => expanded = false),
                      title: 'Code page',
                      builder: (_) => _editor(),
                      child: expanded ? const SizedBox.shrink() : _editor(),
                    ),
                    for (var i = 0; i < 4; i++) SizedBox(height: 48, child: DifyTextLine('Row after $i')),
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

void main() {
  Future<SemanticsHandle> pump(WidgetTester t) async {
    phoneView(t, size: const Size(411, 914), padding: gestureInsets);
    await pumpPhoneApp(t, const _Layers(), edgeToEdge: true);
    final semantics = t.ensureSemantics();
    await t.tap(find.text('Open'));
    await _settle(t);
    final labels = platformLabels(t);
    expect(labels, containsAll(['Settings', 'Row before', 'Row after 0']), reason: 'the sheet: $labels');
    expect(labels, isNot(contains('Open')), reason: 'the page under the sheet: $labels');
    return semantics;
  }

  /// Only [topmost] of the layers is read: the sheet's header, its rows before and after the trigger and the page
  /// are not.
  void onlyTopmost(WidgetTester t, List<String> topmost, String what) {
    final labels = platformLabels(t);
    // (A page's title and text merge into one label.)
    for (final label in topmost) {
      expect(labels, contains(contains(label)), reason: '$what is in the tree: $labels');
    }
    for (final below in ['Settings', 'Row before', 'Row after 0', 'Create', 'Open']) {
      expect(labels, isNot(contains(contains(below))), reason: '$what: "$below" (a layer below) is hidden: $labels');
    }
  }

  Future<void> back(WidgetTester t, String what) async {
    expect(await t.binding.handlePopRoute(), isTrue);
    await _settle(t);
    final labels = platformLabels(t);
    expect(labels, containsAll(['Settings', 'Row before', 'Row after 0']), reason: 'after $what the sheet is back');
    expect(labels, isNot(contains('Open')));
  }

  testWidgets('sheet → picker: the picker\'s options, not the sheet around its trigger', (t) async {
    final semantics = await pump(t);
    await t.tap(find.text('Alpha'));
    await _settle(t);
    onlyTopmost(t, ['Type', 'Beta'], 'the select');
    await back(t, 'the select');
    semantics.dispose();
  });

  testWidgets('sheet → a picker inside another picker\'s trigger (the model selector): the inner picker', (t) async {
    final semantics = await pump(t);
    await t.tap(find.text('Model'));
    await _settle(t);
    onlyTopmost(t, ['Configure model', 'model-a'], 'the inner picker');
    expect(platformLabels(t), isNot(contains('Parameters')));
    await back(t, 'the inner picker');
    semantics.dispose();
  });

  testWidgets('sheet → expanded page: the page, not the sheet behind it', (t) async {
    final semantics = await pump(t);
    await t.tap(find.text('Expand'));
    await _settle(t);
    onlyTopmost(t, ['Code page', 'Inline code'], 'the page');
    await back(t, 'the page');
    semantics.dispose();
  });

  testWidgets('sheet → nested sheet (a trigger outside the sheet\'s scrolling body): the nested sheet; the tree is '
      'never empty', (t) async {
    final semantics = await pump(t);
    await t.tap(find.text('Create'));
    await _settle(t);
    onlyTopmost(t, ['Add variable', 'Variable form'], 'the nested sheet');
    await back(t, 'the nested sheet');
    semantics.dispose();
  });

  testWidgets('a page → picker: the page\'s content after the trigger is hidden too; it is back after closing', (
    t,
  ) async {
    phoneView(t, size: const Size(411, 914), padding: gestureInsets);
    await pumpPhoneApp(
      t,
      DifyPage(
        body: ListView(
          children: [
            const SizedBox(height: 48, child: DifyTextLine('Before')),
            DifySelect<String>(
              value: 'a',
              semanticLabel: 'Type',
              options: const [(value: 'a', label: 'Alpha'), (value: 'b', label: 'Beta')],
              onChanged: (_) {},
            ),
            const SizedBox(height: 48, child: DifyTextLine('After')),
          ],
        ),
      ),
    );
    final semantics = t.ensureSemantics();
    await t.tap(find.text('Alpha'));
    await _settle(t);
    var labels = platformLabels(t);
    expect(labels, containsAll(['Type', 'Beta']), reason: labels.toString());
    expect(labels, isNot(contains('Before')), reason: labels.toString());
    expect(labels, isNot(contains('After')), reason: labels.toString());
    expect(await t.binding.handlePopRoute(), isTrue);
    await _settle(t);
    labels = platformLabels(t);
    expect(labels, containsAll(['Before', 'After']), reason: labels.toString());
    semantics.dispose();
  });
}
