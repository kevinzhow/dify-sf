// difyFocusInTextInput (the page shortcuts' "is the person typing" guard) with a focus whose widget is gone: after a
// re-presentation (a rotation moving a form between a sheet and a side panel) the primary focus, or one of its
// ancestors, can still name an element that was unmounted. The guard must answer, not throw (device check: "Null
// check operator used on a null value" at text_input_scope.dart <- workflow_shortcuts.dart).
import 'package:dify_sf_app/src/design/widgets/text_input_scope.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Attaches [node] to its own element and never detaches it: when the element goes, the node still names it.
class _Leaky extends StatefulWidget {
  const _Leaky({required this.node});
  final FocusNode node;

  @override
  State<_Leaky> createState() => _LeakyState();
}

class _LeakyState extends State<_Leaky> {
  late final FocusAttachment _attachment = widget.node.attach(context);

  @override
  Widget build(BuildContext context) {
    _attachment.reparent();
    return const SizedBox(width: 10, height: 10);
  }
}

void main() {
  testWidgets('a focused node whose element was unmounted: not typing, and no exception', (t) async {
    final node = FocusNode(debugLabel: 'leaky');
    addTearDown(node.dispose);
    await t.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: _Leaky(node: node)));
    node.requestFocus();
    await t.pump();
    expect(FocusManager.instance.primaryFocus, same(node));
    await t.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: SizedBox()));
    expect(FocusManager.instance.primaryFocus, same(node), reason: 'the focus still names the unmounted element');
    expect(node.context, isNotNull);
    expect(node.context!.mounted, isFalse);
    expect(difyFocusInTextInput(), isFalse);
    expect(t.takeException(), isNull);
  });

  testWidgets('a focused field is still typing', (t) async {
    final controller = TextEditingController();
    final node = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(node.dispose);
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: EditableText(
          controller: controller,
          focusNode: node,
          style: const TextStyle(),
          cursorColor: const Color(0xFF000000),
          backgroundCursorColor: const Color(0xFF000000),
        ),
      ),
    );
    node.requestFocus();
    await t.pump();
    expect(difyFocusInTextInput(), isTrue);
  });
}
