// dify-sf phone layout (no Dify spec), batch 4a round 2, from batch 4b's probe (logs-b4b/nested-portal-probe): a
// popover shown as a sheet (the environment variable form) over a DifySheetPortal (the variables sheet). With its
// trigger directly in the sheet's column the platform got an empty tree; with the trigger in a list the form was read
// but the sheet behind it was not hidden. Now, in both, only the form is read, and the sheet is back after it closes.

import 'phone_harness.dart';
import '../../support/platform_semantics.dart';

class _Host extends StatefulWidget {
  const _Host({required this.picker, required this.inList});
  final bool picker, inList;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool open = false, form = false;

  @override
  Widget build(BuildContext context) {
    final popover = DifyPopover(
      open: form,
      onOpenChange: (v) => setState(() => form = v),
      surface: false,
      sheetOnCompact: widget.picker ? true : null,
      builder: (context, c) => DifyButton(onPressed: c.toggle, child: const DifyTextLine('Add')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DifySheetHeader(title: 'Form title'),
          const DifyInput(key: ValueKey('field'), value: '', placeholder: 'Name field'),
          DifyButton(onPressed: () {}, child: const DifyTextLine('Save')),
        ],
      ),
    );
    return DifyPage(
      edgeToEdge: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: DifyButton(onPressed: () => setState(() => open = true), child: const DifyTextLine('Open')),
          ),
          DifySheetPortal(
            open: open,
            onDismiss: () => setState(() => open = false),
            builder: (context) => Column(
              children: [
                DifySheetHeader(title: 'Env sheet'),
                const DifyTextLine('Env row'),
                if (widget.inList)
                  Expanded(child: ListView(children: [popover]))
                else
                  Align(alignment: Alignment.centerLeft, child: popover),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The labels in the framework's own traversal order (what batch 4b's probe read): the same as the platform's.
List<String> _traversalLabels(WidgetTester t) {
  final out = <String>[];
  void walk(SemanticsNode n) {
    if (n.label.isNotEmpty) out.add(n.label);
    n.debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder).forEach(walk);
  }

  for (final view in t.binding.renderViews) {
    if (view.owner?.semanticsOwner?.rootSemanticsNode case final root?) walk(root);
  }
  return out;
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  for (final inList in [false, true]) {
    for (final picker in [false, true]) {
      final where = inList ? 'in a list' : 'directly in the sheet\'s column';
      testWidgets(
        'a popover sheet (sheetOnCompact ${picker ? 'true' : 'by default'}) over a sheet, its trigger $where: '
        'only the form is read; the sheet is back after it closes',
        (t) async {
          final semantics = t.ensureSemantics();
          phoneView(t, size: const Size(411, 914), padding: gestureInsets);
          await pumpPhoneApp(t, _Host(picker: picker, inList: inList), edgeToEdge: true);
          await t.tap(find.text('Open'));
          await _settle(t);
          var labels = platformLabels(t);
          expect(labels, containsAll(['Env sheet', 'Env row', 'Add']), reason: 'the sheet: $labels');
          expect(labels, isNot(contains('Open')), reason: 'the page is hidden: $labels');
          await t.tap(find.text('Add'));
          await _settle(t);
          expect(find.text('Form title'), findsOneWidget);
          labels = platformLabels(t);
          expect(labels, containsAll(['Form title', 'Save']), reason: 'the form is read: $labels');
          for (final below in ['Env sheet', 'Env row', 'Add', 'Open']) {
            expect(labels, isNot(contains(below)), reason: '"$below" (below the form) is hidden: $labels');
          }
          expect(_traversalLabels(t), labels, reason: 'the framework\'s traversal order agrees');
          expect(await t.binding.handlePopRoute(), isTrue);
          await _settle(t);
          labels = platformLabels(t);
          expect(labels, containsAll(['Env sheet', 'Env row', 'Add']), reason: 'the sheet is back: $labels');
          expect(labels, isNot(contains('Form title')), reason: labels.toString());
          semantics.dispose();
        },
      );
    }
  }
}
