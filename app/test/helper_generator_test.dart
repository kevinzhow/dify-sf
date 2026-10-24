import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_helpers/generator_dialog.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/base_form/_harness.dart';

class _FixtureHelpersApi extends HelpersApi {
  _FixtureHelpersApi(this.answer) : super(Uri.parse('https://fixture.invalid'));
  final Future<HelperJson> Function(HelperJson body) answer;
  @override
  Future<HelperJson> generate(String kind, HelperJson body, {HelperCancellation? cancellation}) => answer(body);
}

void main() {
  testWidgets('generation refusal preserves instructions, retries and applies only on request', (tester) async {
    var calls = 0, applies = 0;
    final api = _FixtureHelpersApi((body) async {
      expect(body['instruction'], 'Keep this instruction');
      calls++;
      if (calls == 1) throw const TransportException('Local model refused');
      return {'code': 'def main(): return {}', 'error': ''};
    });
    addTearDown(api.close);
    await renderForm(
      tester,
      HelperGeneratorDialog(
        api: api,
        kind: 'rule-code-generate',
        parameters: const {'code_language': 'python3'},
        apply: (_) async => applies++,
      ),
    );
    final input = find.descendant(of: find.byKey(const Key('helper-instruction')), matching: find.byType(EditableText));
    await tester.enterText(input, 'Keep this instruction');
    await tester.pump();
    await tester.tap(find.byKey(const Key('helper-generate')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(calls, 1);
    expect(find.textContaining('Local model refused'), findsOneWidget);
    expect(tester.widget<EditableText>(input).controller.text, 'Keep this instruction');
    await tester.tap(find.byKey(const Key('helper-generate')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('def main(): return {}'), findsOneWidget);
    expect(applies, 0);
    await tester.tap(find.byKey(const Key('helper-apply')));
    await tester.pump();
    expect(applies, 1);
    expect(calls, 2);
  });
  testWidgets('a concurrent edit prevents applying an old generated proposal', (tester) async {
    var applies = 0;
    final api = _FixtureHelpersApi((_) async => {'prompt': 'Generated', 'error': ''});
    addTearDown(api.close);
    await renderForm(
      tester,
      HelperGeneratorDialog(
        api: api,
        kind: 'rule-generate',
        parameters: const {},
        unchanged: () => false,
        apply: (_) async => applies++,
      ),
    );
    await tester.enterText(find.byType(EditableText), 'Instruction');
    await tester.pump();
    await tester.tap(find.byKey(const Key('helper-generate')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.tap(find.byKey(const Key('helper-apply')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byKey(const Key('helper-error')), findsOneWidget);
    expect(applies, 0);
  });
}
