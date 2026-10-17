// dify-spec: web/app/components/workflow/block-selector/snippets/__tests__/index.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/snippets_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _review = SnippetItem(id: 'snippet-1', name: 'Customer Review', description: 'Snippet description');

Widget _snippets({String search = '', ValueChanged<String>? onChange}) => SizedBox(
  width: 400,
  child: SnippetsPanel(searchText: search, onSearchTextChange: onChange),
);

void main() {
  setUpBlockSelectorTests();

  group('Snippets', () {
    group('Rendering', () {
      testWidgets('should render loading skeleton when loading', (t) async {
        final semantics = t.ensureSemantics();
        await pumpSelector(
          t,
          _snippets(),
          data: BlockSelectorData(searchSnippets: (_) => Completer<List<SnippetItem>>().future),
        );
        expect(find.bySemanticsLabel('common.loading'), findsOneWidget);
        semantics.dispose();
      });

      testWidgets('should render empty state when snippet list is empty', (t) async {
        await pumpSelector(t, _snippets(), data: BlockSelectorData(searchSnippets: (_) async => const []));
        await t.pump();
        expect(find.text('workflow.tabs.noSnippetsFound'), findsOneWidget);
        expect(find.text('workflow.tabs.createSnippet'), findsNothing);
      });

      testWidgets('should keep cached snippet rows visible while refetching', (t) async {
        final keywords = <String>[];
        final data = BlockSelectorData(
          searchSnippets: (k) {
            keywords.add(k);
            return k.isEmpty ? Future.value(const [_review]) : Completer<List<SnippetItem>>().future;
          },
        );
        await pumpSelector(t, _snippets(), data: data);
        await t.pump();
        await pumpSelector(t, _snippets(search: 'customer'), data: data);
        expect(keywords, ['', 'customer']);
        expect(find.text('Customer Review'), findsOneWidget);
      });
    });

    group('User Interactions', () {
      testWidgets('should delegate embedded search changes', (t) async {
        final changes = <String>[];
        var search = '';
        await pumpSelector(
          t,
          StatefulBuilder(
            builder: (context, setState) => _snippets(
              search: search,
              onChange: (v) {
                setState(() => search = v);
                changes.add(v);
              },
            ),
          ),
          data: BlockSelectorData(searchSnippets: (_) async => const []),
        );
        await t.enterText(
          find.descendant(of: searchField('workflow.tabs.searchSnippets'), matching: find.byType(EditableText)),
          'review',
        );
        await t.pump();
        expect(changes.last, 'review');

        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        final clear = find.byWidgetPredicate(
          (w) => w is DifyIconButton && w.label == 'workflow.tabs.clearSnippetSearch',
        );
        expect(hasFocusOn(t, clear), isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
        await t.pump();
        expect(changes.last, '');
      });

      testWidgets('should expose snippet rows as buttons and delegate insertion', (t) async {
        final inserted = <(SnippetItem, Map<String, Object?>?)>[];
        await pumpSelector(
          t,
          _snippets(),
          data: BlockSelectorData(
            searchSnippets: (_) async => const [_review],
            onInsertSnippet: (s, p) async {
              inserted.add((s, p));
              return true;
            },
          ),
        );
        await t.pump();
        await tapText(t, 'Customer Review');
        expect(inserted.single.$1.id, 'snippet-1');
        expect(inserted.single.$2, isNull);
      });

      testWidgets('should show a preview from the keyboard when a snippet has no description', (t) async {
        await pumpSelector(
          t,
          _snippets(),
          data: BlockSelectorData(
            searchSnippets: (_) async => const [SnippetItem(id: 'snippet-1', name: 'No Description')],
          ),
        );
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.tab); // search
        await t.sendKeyEvent(LogicalKeyboardKey.tab); // the snippet
        await settle(t, 500);
        expect(hasFocusOn(t, find.text('No Description').first), isTrue);
        expect(find.text('No Description'), findsNWidgets(2), reason: 'the row and its preview');
      });
    });
  });
}
