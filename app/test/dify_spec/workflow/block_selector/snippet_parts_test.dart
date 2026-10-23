// dify-spec: web/app/components/workflow/block-selector/snippets/__tests__/snippet-empty-state.spec.tsx
// dify-spec: web/app/components/workflow/block-selector/snippets/__tests__/snippet-list-item.spec.tsx
// dify-spec: web/app/components/workflow/block-selector/snippets/__tests__/snippet-detail-card.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/selector_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/snippets_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _snippet = SnippetItem(
  id: 'snippet-1',
  name: 'Customer Review',
  description: 'Snippet description',
  authorName: 'Evan',
);

void main() {
  setUpBlockSelectorTests();

  group('SnippetEmptyState', () {
    group('Rendering', () {
      testWidgets('should render empty state copy without create action', (t) async {
        await pumpSelector(t, const SnippetEmptyState());
        expect(find.text('workflow.tabs.noSnippetsFound'), findsOneWidget);
        expect(find.byType(GestureDetector), findsNothing);
      });
    });
  });

  group('SnippetListItem', () {
    group('Rendering', () {
      testWidgets('should render snippet title and description', (t) async {
        await pumpSelector(t, const SizedBox(width: 400, child: SnippetListItem(snippet: _snippet)));
        expect(find.text('Customer Review'), findsOneWidget);
        expect(find.text('Snippet description'), findsOneWidget);
      });

      testWidgets('should not render metadata or tags', (t) async {
        await pumpSelector(t, const SizedBox(width: 400, child: SnippetListItem(snippet: _snippet)));
        expect(find.byType(Text), findsNWidgets(2));
      });
    });

    group('User Interactions', () {
      testWidgets('should forward click and hover handlers', (t) async {
        var clicks = 0;
        await pumpSelector(
          t,
          SizedBox(
            width: 400,
            child: SnippetListItem(snippet: _snippet, onPressed: () => clicks++),
          ),
        );
        await tapText(t, 'Customer Review');
        expect(clicks, 1);
      });
    });
  });

  group('SnippetDetailCard', () {
    group('Rendering', () {
      testWidgets('should render snippet summary information', (t) async {
        await pumpSelector(t, const SnippetDetailCard(snippet: _snippet));
        expect(find.text('Customer Review'), findsOneWidget);
        expect(find.text('Snippet description'), findsOneWidget);
        expect(find.text('Evan'), findsOneWidget);
      });

      testWidgets('should render the unknown user label when the author name is unavailable', (t) async {
        await pumpSelector(
          t,
          const SnippetDetailCard(
            snippet: SnippetItem(id: 's', name: 'Snippet'),
          ),
        );
        expect(find.text('snippet.unknownUser'), findsOneWidget);
      });

      testWidgets('should render unique block icons from published workflow graph', (t) async {
        await pumpSelector(
          t,
          const SnippetDetailCard(
            snippet: SnippetItem(id: 's', name: 'Snippet', blockTypes: ['llm', 'code', 'llm']),
          ),
        );
        expect(find.byType(SelectorBlockIcon), findsNWidgets(2));
      });
    });
  });
}
