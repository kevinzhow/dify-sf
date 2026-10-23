import 'package:dify_sf_app/src/workflow_editor/run/ui/markdown.dart';
import 'package:flutter/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/thinking_details.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_spec/workflow/run/run_harness.dart';

String rendered(WidgetTester t) =>
    t.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText()).join('\n');
void main() {
  testWidgets('completed inline thinking is initially collapsed and can be expanded', (t) async {
    await renderRun(t, const DifyMarkdown(content: '<think>private reasoning</think>\n\nFinal reply'));
    expect(rendered(t), contains('Final reply'));
    expect(rendered(t), isNot(contains('private reasoning')));
    await t.tap(find.textContaining('chat.thought'));
    await t.pumpAndSettle();
    expect(rendered(t), contains('private reasoning'));
  });
  testWidgets('HTML comments are invisible but adjacent answer text survives', (t) async {
    await renderRun(t, const DifyMarkdown(content: '<!--dify-deepseek-reasoning-->Visible answer'));
    expect(rendered(t), contains('Visible answer'));
    expect(rendered(t), isNot(contains('dify-deepseek-reasoning')));
  });

  testWidgets('stopping an unclosed stream collapses without changing content', (t) async {
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await renderRun(
      t,
      ValueListenableBuilder(
        valueListenable: active,
        builder: (_, streaming, _) => DifyMarkdown(content: '<think>Partial thought', isStreaming: streaming),
      ),
    );
    expect(rendered(t), contains('Partial thought'));
    active.value = false;
    await t.pump();
    expect(rendered(t), isNot(contains('Partial thought')));
    expect(rendered(t), contains('chat.thought'));
  });
  testWidgets('code examples retain literal think tags and HTML comments', (t) async {
    await renderRun(
      t,
      const DifyMarkdown(
        content: '```html\n<think>code</think>\n<!--keep-->\n```\n\n`<think>inline</think>` and `<!--inline-->`',
      ),
    );
    expect(find.byType(ThinkingDetails), findsNothing);
    expect(rendered(t), contains('<think>code</think>'));
    expect(rendered(t), contains('<!--keep-->'));
    expect(rendered(t), contains('<think>inline</think>'));
    expect(rendered(t), contains('<!--inline-->'));
  });
  testWidgets('multiline comments vanish while following Markdown survives', (t) async {
    await renderRun(
      t,
      const DifyMarkdown(content: 'Before <!--hidden--> after\n\n<!--multi\nline-->**Visible**\n\n# Heading'),
    );
    expect(rendered(t), contains('Before  after'));
    expect(rendered(t), contains('Visible'));
    expect(rendered(t), contains('Heading'));
    expect(rendered(t), isNot(contains('hidden')));
    expect(rendered(t), isNot(contains('multi')));
  });
  testWidgets('consecutive think blocks keep both answers and independent disclosure', (t) async {
    await renderRun(t, const DifyMarkdown(content: '<think>one</think>First\n\n<think>two</think>Second'));
    expect(find.byType(ThinkingDetails), findsNWidgets(2));
    expect(rendered(t), contains('First'));
    expect(rendered(t), contains('Second'));
    expect(rendered(t), isNot(contains('one')));
    expect(rendered(t), isNot(contains('two')));
  });
  testWidgets('a standalone hidden comment contributes no extra layout block', (t) async {
    await renderRun(t, const DifyMarkdown(content: 'Visible'));
    final original = t.getTopLeft(find.text('Visible', findRichText: true));
    await renderRun(t, const DifyMarkdown(content: '<!--hidden-->\n\nVisible'));
    expect(t.getTopLeft(find.text('Visible', findRichText: true)), original);
  });
}
