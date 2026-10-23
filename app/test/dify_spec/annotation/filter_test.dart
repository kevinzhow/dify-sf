// dify-spec: web/app/components/app/annotation/__tests__/filter.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/app_detail/annotations/header_opts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _childContent = 'child-content';

/// The search box (Dify's `searchbox` named "common.operation.search").
Finder get _search => find.descendant(of: find.byType(AnnotationFilter), matching: find.byType(EditableText));

/// `useAnnotationsCount` answering [count] (null: still loading; an error: no data).
MockAnnotationServices _services({Future<int> Function()? count}) =>
    MockAnnotationServices()..countResult = count ?? () async => 20;

Future<List<String>> _render(WidgetTester t, MockAnnotationServices s, {String keyword = ''}) async {
  final changes = <String>[];
  await renderAnnotation(
    t,
    AnnotationFilter(
      services: s,
      keyword: keyword,
      onKeywordChange: changes.add,
      child: const Text(_childContent),
    ),
  );
  return changes;
}

void main() {
  group('Filter', () {
    group('Rendering', () {
      testWidgets('should render nothing when data is loading', (t) async {
        await _render(t, _services(count: () => Completer<int>().future));
        expect(_search, findsNothing);
        expect(find.text(_childContent), findsNothing);
      });

      testWidgets('should render nothing when data is undefined', (t) async {
        await _render(t, _services(count: () async => throw StateError('no data')));
        expect(_search, findsNothing);
        expect(find.text(_childContent), findsNothing);
      });

      testWidgets('should render filter and children when data is available', (t) async {
        await _render(t, _services());
        expect(find.bySemanticsLabel('common.operation.search'), findsWidgets);
        expect(_search, findsOneWidget);
        expect(find.text(_childContent), findsOneWidget);
      });
    });

    group('Props', () {
      testWidgets('should call useAnnotationsCount with appId', (t) async {
        // The services are the app's (AnnotationsApiServices binds the app id): the count is asked once.
        final s = _services(count: () async => 10);
        await _render(t, s);
        expect(s.count_('count'), 1);
      });

      testWidgets('should display keyword value in input', (t) async {
        await _render(t, _services(count: () async => 10), keyword: 'test-keyword');
        expect(t.widget<EditableText>(_search).controller.text, 'test-keyword');
      });
    });

    group('User Interactions', () {
      testWidgets('should call setQueryParams when typing in search input', (t) async {
        final changes = await _render(t, _services());
        await t.enterText(_search, 'updated');
        expect(changes.last, 'updated');
      });

      testWidgets('should call setQueryParams with empty keyword when clearing input', (t) async {
        final changes = await _render(t, _services(), keyword: 'prefill');
        await tapButton(t, 'common.operation.clear');
        expect(changes.last, '');
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle empty keyword in queryParams', (t) async {
        await _render(t, _services(count: () async => 5));
        expect(t.widget<EditableText>(_search).controller.text, '');
      });

      testWidgets('should handle undefined keyword in queryParams', (t) async {
        // Dart has no undefined keyword: the page's default is the empty keyword.
        await _render(t, _services(count: () async => 5));
        expect(_search, findsOneWidget);
      });

      testWidgets('should handle zero count', (t) async {
        await _render(t, _services(count: () async => 0));
        expect(_search, findsOneWidget);
      });
    });
  });
}
