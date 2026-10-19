// dify-spec: web/app/components/apps/__tests__/list.spec.tsx
import 'dart:async';
import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart' show FakeAppsApi;
import 'package:dify_sf_app/src/studio/app_card.dart' show SrOnlyStatus;
import 'package:dify_sf_app/src/studio/app_list_controller.dart';
import 'package:dify_sf_app/src/studio/create_app_modal.dart';
import 'package:dify_sf_app/src/studio/create_from_dsl_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'controlled_api.dart';
import 'harness.dart';

typedef _Studio = ({StudioFixture f, ControlledAppsApi api, StudioCalls calls});

/// Dify's `defaultAppData`: two apps (`app-1`, `app-2`), unless [apps] says how many.
Future<_Studio> _render(
  WidgetTester t, {
  int apps = 2,
  String as = 'owner@example.com',
  void Function(StudioFixture f, ControlledAppsApi api)? before,
  Duration debounce = Duration.zero,
}) async {
  final f = await StudioFixture.create(as: as, more: [('normal@example.com', 'Norm', AccountRole.normal)]);
  for (var i = 1; i <= apps; i++) {
    f.api.seed(
      id: 'app-$i',
      name: 'Test App $i',
      description: 'Description $i',
      mode: i.isEven ? AppModes.workflow : AppModes.advancedChat,
      createdAt: DateTime.utc(2024, 1, 1).add(Duration(minutes: i)),
    );
  }
  final api = ControlledAppsApi(f.api);
  before?.call(f, api);
  final calls = await renderStudio(t, f, api: api, debounce: debounce);
  return (f: f, api: api, calls: calls);
}

StudioAppList _list(WidgetTester t) => studioState(t).list;

Finder _card(String id) => find.byKey(ValueKey('card-$id'));

Finder _searchField() => find.descendant(
  of: find.bySemanticsLabel('app.gotoAnything.actions.searchApplications'),
  matching: find.byType(EditableText),
);

double _y(Finder f) => t0.getTopLeft(f).dy;
late WidgetTester t0;

/// The sr-only result status (`role="status"`).
String _status(WidgetTester t) => t.widget<SrOnlyStatus>(find.byType(SrOnlyStatus)).text;

ScrollPosition _scrollPosition(WidgetTester t) => t
    .state<ScrollableState>(
      find.descendant(of: find.byKey(const ValueKey('studio-catalog')), matching: find.byType(Scrollable)).first,
    )
    .position;

Future<void> _scrollToEnd(WidgetTester t) async {
  final p = _scrollPosition(t);
  p.jumpTo(p.maxScrollExtent);
  await settle(t);
}

/// A valid Dify DSL file (JSON is YAML).
String _dsl() => jsonEncode(FakeAppsApi.seedDsl(AppModes.workflow));

void main() {
  group('List', () {
    group('Rendering', () {
      // dify-sf has no snippets: the header ends with the Create button.
      testWidgets('should render filters and search before the right aligned actions', (t) async {
        await _render(t);
        // Reading order (the filters wrap like Dify's `flex-wrap`).
        bool before(Finder a, Finder b) {
          final pa = t.getTopLeft(a), pb = t.getTopLeft(b);
          return pa.dy < pb.dy - 1 || ((pa.dy - pb.dy).abs() <= 1 && pa.dx < pb.dx);
        }

        Finder k(String key) => find.byKey(ValueKey(key));
        expect(button('app.studio.sort.sortBy app.studio.sort.lastModified'), findsOneWidget);
        expect(before(k('studio-creators-filter'), k('studio-sort-filter')), isTrue);
        expect(before(k('studio-sort-filter'), _searchField()), isTrue);
        expect(t.getTopLeft(_searchField()).dx, lessThan(t.getTopLeft(k('studio-create')).dx));
      });

      testWidgets('should render app cards when apps exist', (t) async {
        await _render(t);
        expect(_card('app-1'), findsOneWidget);
        expect(_card('app-2'), findsOneWidget);
      });

      testWidgets('should hide starred section when there are no starred apps', (t) async {
        await _render(t);
        expect(find.text('APP.STUDIO.STARRED'), findsNothing);
        expect(find.text('APP.STUDIO.ALLAPPS'), findsNothing);
      });

      testWidgets('should render starred apps before all app cards when starred apps exist', (t) async {
        t0 = t;
        await _render(
          t,
          before: (f, _) => f.api.seed(id: 'starred-app-1', name: 'Starred App', starred: true),
        );
        final starredCard = find.byKey(const ValueKey('starred-starred-app-1'));
        expect(starredCard, findsOneWidget);
        expect(
          find.descendant(of: starredCard, matching: find.byKey(const ValueKey('app-card-star-starred-app-1'))),
          findsOneWidget,
          reason: 'the starred card has its action bar',
        );
        expect(find.byKey(const ValueKey('starred-app-1')), findsNothing, reason: 'only one starred row');
        expect(_y(find.text('APP.STUDIO.STARRED')), lessThan(_y(starredCard)));
        expect(_y(starredCard), lessThan(_y(find.text('APP.STUDIO.ALLAPPS'))));
        expect(_y(find.text('APP.STUDIO.ALLAPPS')), lessThan(_y(_card('app-1'))));
      });

      testWidgets('should not render new app card in the app grid', (t) async {
        await _render(t);
        expect(find.byKey(const ValueKey('new-app-card')), findsNothing);
      });

      testWidgets('should render drop DSL hint when app creation permission is available', (t) async {
        await _render(t);
        expect(find.text('app.newApp.dropDSLToCreateApp'), findsOneWidget);
      });

      // dify-sf has no templates and no Learn Dify: the first empty state offers Create from Blank and Import DSL.
      testWidgets('should render first empty state when there are no apps and no active filters', (t) async {
        await _render(t, apps: 0);
        expect(find.text('app.firstEmpty.title'), findsOneWidget);
        expect(find.text('APP.FIRSTEMPTY.OR'), findsOneWidget);
        expect(button('app.studio.filters.types'), findsOneWidget);
        expect(find.byKey(const ValueKey('studio-empty')), findsNothing);
        expect(button('app.newApp.startFromBlank'), findsOneWidget);
        expect(button('app.importDSL'), findsOneWidget);
      });

      testWidgets('should hide learn dify in first empty state when learn app is disabled', (t) async {
        await _render(t, apps: 0);
        expect(find.text('app.firstEmpty.title'), findsOneWidget);
        expect(find.text('app.firstEmpty.learnDifyTitle'), findsNothing);
      });

      testWidgets('should not render first empty state before the first app list page resolves', (t) async {
        final gate = Completer<void>();
        await _render(t, apps: 0, before: (_, api) => api.holdList = gate);
        expect(find.text('app.firstEmpty.title'), findsNothing);
        expect(button('app.studio.filters.types'), findsOneWidget);
        gate.complete();
      });

      testWidgets('should not render first empty state from placeholder data during a filter transition', (t) async {
        final s = await _render(t, apps: 0);
        _list(t).setCategory(AppModes.workflow);
        await settle(t);
        final gate = Completer<void>();
        s.api.holdList = gate;
        _list(t).setCategory(AppModes.all);
        await settle(t);
        expect(_list(t).isPlaceholderData, isTrue);
        expect(find.byKey(const ValueKey('studio-empty')), findsOneWidget);
        expect(find.text('app.firstEmpty.title'), findsNothing);
        gate.complete();
        await settle(t);
        expect(find.text('app.firstEmpty.title'), findsOneWidget);
      });

      testWidgets('should keep the regular empty state for empty filtered results', (t) async {
        await _render(t, apps: 0);
        _list(t).setKeywords('missing app');
        await settle(t);
        expect(find.byKey(const ValueKey('studio-empty')), findsOneWidget);
        expect(_status(t), 'app.filterEmpty.noApps', reason: 'the sr-only status');
        expect(_list(t).isFetching, isFalse);
        expect(button('app.studio.filters.types'), findsOneWidget);
        expect(find.byKey(const ValueKey('new-app-card')), findsNothing);
        expect(find.text('app.firstEmpty.title'), findsNothing);
      });

      testWidgets('should keep the result status quiet while placeholder results are fetching', (t) async {
        final s = await _render(t, apps: 0);
        _list(t).setKeywords('missing app');
        await settle(t);
        final gate = Completer<void>();
        s.api.holdList = gate;
        _list(t).setKeywords('missing app 2');
        await settle(t);
        expect(_list(t).isFetching, isTrue);
        expect(_status(t), '');
        gate.complete();
      });

      testWidgets('should keep the settled empty status during a background refetch', (t) async {
        final s = await _render(t, apps: 0);
        _list(t).setKeywords('missing app');
        await settle(t);
        final gate = Completer<void>();
        s.api.holdList = gate;
        unawaited(_list(t).refresh());
        await settle(t);
        expect(_list(t).isFetching, isTrue);
        expect(_status(t), 'app.filterEmpty.noApps');
        gate.complete();
      });

      testWidgets('should leave the first empty state as soon as a filter changes', (t) async {
        await _render(t, apps: 0, debounce: appListSearchDebounce);
        expect(find.text('app.firstEmpty.title'), findsOneWidget);
        await t.enterText(_searchField(), 'workflow');
        await t.pump();
        expect(find.text('app.firstEmpty.title'), findsNothing, reason: 'before the debounced query');
        expect(find.byKey(const ValueKey('studio-empty')), findsOneWidget);
        await settle(t, 8);
      });

      // No templates in dify-sf: Create from Blank and Import DSL.
      testWidgets('should open create flows from first empty state actions', (t) async {
        await _render(t, apps: 0);
        await tapButton(t, 'app.newApp.startFromBlank');
        expect(find.byType(CreateAppModal), findsOneWidget);
        await t.tap(find.byKey(const ValueKey('create-app-shell-close')));
        await settle(t);
        expect(find.byType(CreateAppModal), findsNothing);
        await tapButton(t, 'app.importDSL');
        expect(find.byType(CreateFromDSLModal), findsOneWidget);
      });
    });

    group('App Type Select', () {
      testWidgets('should render selected category in the trigger', (t) async {
        await _render(t);
        _list(t).setCategory(AppModes.workflow);
        await settle(t);
        expect(button('app.types.workflow'), findsOneWidget);
      });

      testWidgets('should update category when workflow option is selected', (t) async {
        final s = await _render(t);
        await tapButton(t, 'app.studio.filters.types');
        await t.tap(find.byKey(const ValueKey('studio-type-option-workflow')));
        await settle(t);
        expect(_list(t).category, AppModes.workflow);
        expect(s.api.listQueries.last.mode, AppModes.workflow);
      });

      testWidgets('should update category when all option is selected', (t) async {
        final s = await _render(t);
        _list(t).setCategory(AppModes.workflow);
        await settle(t);
        await tapButton(t, 'app.types.workflow');
        await t.tap(find.byKey(const ValueKey('studio-type-option-all')));
        await settle(t);
        expect(_list(t).category, AppModes.all);
        expect(s.api.listQueries.last.mode, AppModes.all);
      });
    });

    group('Search Functionality', () {
      testWidgets('should clear the keywords URL state', (t) async {
        final s = await _render(t);
        await t.enterText(_searchField(), 'existing search');
        await settle(t);
        expect(s.api.listQueries.last.name, 'existing search');
        await tapButton(t, 'common.operation.clear');
        expect(t.widget<EditableText>(_searchField()).controller.text, '');
        expect(_list(t).keywords, '');
        expect(s.api.listQueries.last.name, '');
      });
    });

    group('App List Query', () {
      testWidgets('resets the catalog scroll position before switching datasets', (t) async {
        await _render(t, apps: 40);
        expect(
          find.descendant(of: find.byKey(const ValueKey('studio-catalog')), matching: _searchField()),
          findsNothing,
          reason: 'the search box is outside the scroll area',
        );
        _scrollPosition(t).jumpTo(400);
        await settle(t);
        expect(_scrollPosition(t).pixels, 400);
        await tapButton(t, 'app.studio.sort.sortBy app.studio.sort.lastModified');
        await t.tap(find.byKey(const ValueKey('studio-sort-option-recently_created')));
        await settle(t);
        expect(_scrollPosition(t).pixels, 0);
      });

      testWidgets('should build paged query input from active filters', (t) async {
        final s = await _render(t);
        final me = s.f.members.auth.account!.id;
        await t.enterText(_searchField(), 'sales');
        _list(t).setCategory(AppModes.workflow);
        await settle(t);
        await tapButton(t, 'app.studio.filters.creators');
        await t.tap(find.byKey(ValueKey('studio-creator-$me')));
        await settle(t);
        final q = _list(t).queryFor(2);
        expect(
          (q.page, q.limit, q.name, q.sortBy, q.mode),
          (2, 30, 'sales', AppSortBy.lastModified, AppModes.workflow),
        );
        expect(q.creatorIds, [me]);
        final last = s.api.listQueries.last;
        expect((last.page, last.name, last.mode), (1, 'sales', AppModes.workflow));
        expect(last.creatorIds, [me]);
      });

      testWidgets('should build starred query input from active filters with the starred limit', (t) async {
        final s = await _render(t);
        final me = s.f.members.auth.account!.id;
        await t.enterText(_searchField(), 'sales');
        _list(t).setCategory(AppModes.workflow);
        await settle(t);
        await tapButton(t, 'app.studio.filters.creators');
        await t.tap(find.byKey(ValueKey('studio-creator-$me')));
        await settle(t);
        final q = s.api.starredQueries.last;
        expect(
          (q.page, q.limit, q.name, q.sortBy, q.mode),
          (1, 100, 'sales', AppSortBy.lastModified, AppModes.workflow),
        );
        expect(q.creatorIds, [me]);
      });

      testWidgets('should keep previous main and starred data visible while filters refetch', (t) async {
        final s = await _render(
          t,
          before: (f, _) => f.api.seed(id: 'starred-app-1', name: 'Starred App', starred: true),
        );
        final gate = Completer<void>();
        s.api
          ..holdList = gate
          ..holdStarred = gate;
        _list(t).setSortBy(AppSortBy.recentlyCreated);
        await settle(t);
        expect(_list(t).isPlaceholderData, isTrue);
        expect(_card('app-1'), findsOneWidget);
        expect(find.byKey(const ValueKey('starred-starred-app-1')), findsOneWidget);
        gate.complete();
        await settle(t);
        expect(s.api.listQueries.last.sortBy, AppSortBy.recentlyCreated);
      });
    });

    group('Creators Filter', () {
      testWidgets('should handle creator selection', (t) async {
        final s = await _render(t);
        await tapButton(t, 'app.studio.filters.creators');
        await t.tap(find.byKey(ValueKey('studio-creator-${s.f.idOf('normal@example.com')}')));
        await settle(t);
        expect(find.text('+1'), findsOneWidget);
      });
    });

    group('Create Menu', () {
      testWidgets('should open blank app modal from create menu', (t) async {
        await _render(t);
        await tapKey(t, 'studio-create');
        await tapKey(t, 'studio-create-blank');
        await settle(t);
        expect(find.byType(CreateAppModal), findsOneWidget);
      });

      testWidgets('should open DSL import modal from create menu', (t) async {
        await _render(t);
        await tapKey(t, 'studio-create');
        await tapKey(t, 'studio-create-dsl');
        await settle(t);
        expect(find.byType(CreateFromDSLModal), findsOneWidget);
      });

      testWidgets('should not render create button without app creation permission', (t) async {
        await _render(t, as: 'normal@example.com');
        expect(find.byKey(const ValueKey('studio-create')), findsNothing);
      });
    });

    group('App Type Select Options', () {
      // dify-sf offers the modes it can run (Workflow, Chatflow); Chatbot, Agent and Text generator are not options.
      testWidgets('should update category for each app type option click', (t) async {
        final s = await _render(t);
        for (final mode in [AppModes.workflow, AppModes.advancedChat]) {
          if (find.byKey(ValueKey('studio-type-option-$mode')).evaluate().isEmpty) {
            await tapButton(t, _list(t).category == AppModes.all ? 'app.studio.filters.types' : 'app.types.workflow');
          }
          await t.tap(find.byKey(ValueKey('studio-type-option-$mode')));
          await settle(t);
          expect(s.api.listQueries.last.mode, mode);
        }
        expect(find.byKey(const ValueKey('studio-type-option-chat')), findsNothing);
      });

      testWidgets('should update app list query when sort option changes', (t) async {
        final s = await _render(t);
        await tapButton(t, 'app.studio.sort.sortBy app.studio.sort.lastModified');
        await t.tap(find.byKey(const ValueKey('studio-sort-option-recently_created')));
        await settle(t);
        expect(s.api.listQueries.last.sortBy, AppSortBy.recentlyCreated);
      });
    });

    group('DSL File Drop', () {
      DroppedFile file(String content) =>
          (name: 'test.yml', length: () async => content.length, read: () async => content);

      testWidgets('should handle DSL file drop and show modal', (t) async {
        await _render(t);
        studioState(t).drop.drop([file('test content')]);
        await settle(t);
        expect(find.byType(CreateFromDSLModal), findsOneWidget);
        expect(find.text('test.yml'), findsOneWidget);
      });

      testWidgets('should close DSL modal when onClose is called', (t) async {
        await _render(t);
        studioState(t).drop.drop([file('test content')]);
        await settle(t);
        await t.tap(find.byKey(const ValueKey('dsl-cancel')));
        await settle(t);
        expect(find.byType(CreateFromDSLModal), findsNothing);
      });

      testWidgets('should close DSL modal when its mutation reports success', (t) async {
        final s = await _render(t);
        studioState(t).drop.drop([file(_dsl())]);
        await settle(t);
        await tapButton(t, 'app.newApp.Create');
        await settle(t);
        expect(find.byType(CreateFromDSLModal), findsNothing);
        expect(s.calls.opened, hasLength(1), reason: 'the imported app opens');
      });
    });

    group('Infinite Scroll', () {
      testWidgets('should call fetchNextPage when intersection observer triggers', (t) async {
        final s = await _render(t, apps: 35);
        expect(s.api.listQueries.where((q) => q.page == 2), isEmpty);
        await _scrollToEnd(t);
        expect(s.api.listQueries.where((q) => q.page == 2), isNotEmpty);
        expect(_list(t).apps, hasLength(35));
      });

      testWidgets('should not call fetchNextPage when not intersecting', (t) async {
        final s = await _render(t, apps: 35);
        expect(_list(t).hasNextPage, isTrue);
        expect(s.api.listQueries.where((q) => q.page == 2), isEmpty);
      });

      testWidgets('should show one catalog skeleton until both app queries have data', (t) async {
        final list = Completer<void>(), starred = Completer<void>();
        await _render(
          t,
          apps: 35,
          before: (_, api) => api
            ..holdList = list
            ..holdStarred = starred,
        );
        expect(_searchField(), findsOneWidget);
        expect(find.bySemanticsLabel('common.loading'), findsOneWidget);
        expect(_card('app-1'), findsNothing);
        list.complete();
        await settle(t);
        expect(find.bySemanticsLabel('common.loading'), findsOneWidget, reason: 'the starred row is still loading');
        expect(_card('app-1'), findsNothing);
        starred.complete();
        await settle(t);
        expect(find.bySemanticsLabel('common.loading'), findsNothing);
        expect(_card('app-1'), findsNothing, reason: 'app-1 is the oldest (last modified first)');
        expect(_card('app-35'), findsOneWidget);
      });
    });

    group('Error State', () {
      testWidgets('should keep the main catalog available when the starred request fails', (t) async {
        await _render(t, before: (_, api) => api.failStarred = const TransportException('Starred request failed'));
        expect(_card('app-1'), findsOneWidget);
        expect(find.text('APP.STUDIO.STARRED'), findsNothing);
        expect(find.bySemanticsLabel('common.loading'), findsNothing);
      });

      testWidgets('should keep resolved data visible and retry a failed next page', (t) async {
        final s = await _render(
          t,
          apps: 35,
          before: (_, api) => api.failList = (q) => q.page == 2 ? const TransportException('Test error') : null,
        );
        await _scrollToEnd(t);
        expect(_list(t).isFetchNextPageError, isTrue);
        expect(_card('app-35'), findsNothing);
        expect(_list(t).apps, hasLength(30), reason: 'the first page stays');
        await _scrollToEnd(t);
        s.api.failList = null;
        await tapButton(t, 'common.operation.retry');
        expect(s.api.listQueries.where((q) => q.page == 2), hasLength(2));
        expect(_list(t).apps, hasLength(35));
      });
    });
  });
}

typedef DroppedFile = ({String name, Future<int> Function() length, Future<String> Function() read});
