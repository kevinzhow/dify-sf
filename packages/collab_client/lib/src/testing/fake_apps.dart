import 'dart:convert';
import 'dart:math';

import '../access_api.dart';
import '../annotations_api.dart';
import '../apps_api.dart';
import '../auth/account.dart';
import '../client/replace.dart';
import '../client/transport.dart';
import '../model/app_registers.dart';
import '../model/document.dart';
import '../model/value.dart';
import '../versions_api.dart';
import '../wire/messages.dart';
import 'fake_dsl.dart';
import 'fake_accounts.dart';
import 'fake_server.dart';

part 'fake_app_detail.dart';

/// An in-memory [AppsApi] with the server's rules (protocol 1.10), for tests and demo mode. Each app has its own
/// [FakeServer] ([server]) for the editor; a commit on it bumps the app's `updated_at` (the server's deviation from
/// Dify, see `AppsApi`).
///
/// Rules as the server: every member reads and stars (stars per account); writes need `owner`, `admin` or `editor`
/// (`403 forbidden`), `includeSecret` `owner` or `admin`; `permission_keys` by the caller's role; list validation (page
/// 1-99999, limit 1-100, known `mode` and `sort_by`, else `400 bad_request`), filters (mode, name: case-insensitive
/// substring of the first 30 characters, creator ids, created by me; tag ids ignored), sorts with ties by id; create
/// (name 1+ characters after trimming, description at most 400 characters, `unsupported_app_mode` for modes other than
/// workflow / chatflow, Dify's default icon `🤖` on `#FFEAD5`, the server's seeds); import with Dify's version check
/// (`pending` until [AppsApi.confirmImport] by the same account within 10 minutes) and the server's mode and node checks;
/// copy (document, variables, features and secrets); soft delete (`404 app_deleted` afterwards, also from [server], and
/// every `FakeTransport` on the app's document answers `404 app_deleted` and ends its streams).
///
/// Accounts: [accountId], [accountName] and [role] are the caller; [asAccount] gives another member's view of the same
/// workspace. [clock] drives every time (epoch seconds in answers). [secretsKeyMissing] makes copying or importing an
/// app with secrets fail like a server without a secrets key (`503 secrets_key_missing`). [requests] counts calls.
class FakeAppsApi implements AppsApi {
  FakeAppsApi({
    this.accountId = 'account-owner',
    this.accountName = 'Owner',
    this.role = AccountRole.owner,
    DateTime Function()? clock,
    this.secretsKeyMissing = false,
    String origin = 'http://localhost:8080',
  }) : _s = _State(clock ?? DateTime.now) {
    _s.names[accountId] = accountName;
    _s.origin = origin;
  }

  FakeAppsApi._shared(this._s, this.accountId, this.accountName, this.role, this.secretsKeyMissing);

  /// Another member's view of the same workspace (shares apps, stars and documents with this one).
  FakeAppsApi asAccount(String id, {String? name, String role = AccountRole.editor}) {
    final n = name ?? _s.names[id] ?? id;
    _s.names[id] = n;
    return FakeAppsApi._shared(_s, id, n, role, secretsKeyMissing);
  }

  final String accountId;
  final String accountName;
  String role;
  bool secretsKeyMissing;
  final _State _s;

  /// The server's origin (protocol 1.11): the Web App base URL (`site.app_base_url`) and, with `/v1`, the Service API
  /// base URL (`api_base_url`). Shared by every view.
  String get origin => _s.origin;
  set origin(String o) => _s.origin = o;

  /// Calls so far (of every account's view), by method name (`list`, `create`, ...).
  Map<String, int> get requests => _s.requests;

  /// The time source (shared by every view).
  DateTime Function() get clock => _s.clock;
  set clock(DateTime Function() c) => _s.clock = c;

  // ----- test helpers -----

  /// Adds an app directly (no role check, no request counted): for tests that need a populated list. [createdAt] and
  /// [updatedAt] default to now; [document] to the server's seed of [mode].
  AppInfo seed({
    String? id,
    required String name,
    String mode = AppModes.workflow,
    String description = '',
    String? iconType = AppIconTypes.emoji,
    String? icon = _defaultIcon,
    String? iconBackground = _defaultBackground,
    bool useIconAsAnswerIcon = false,
    String? createdBy,
    String? creatorName,
    DateTime? createdAt,
    DateTime? updatedAt,
    Document? document,
    bool starred = false,
  }) {
    final by = createdBy ?? accountId;
    if (creatorName != null) _s.names[by] = creatorName;
    final now = _s.clock();
    final a = _App(
      id: id ?? _s.newId(),
      name: name,
      description: description,
      mode: mode,
      iconType: iconType,
      icon: icon,
      iconBackground: iconBackground,
      useIconAsAnswerIcon: useIconAsAnswerIcon,
      createdBy: by,
      createdAt: createdAt ?? now,
      updatedBy: by,
      updatedAt: updatedAt ?? createdAt ?? now,
      server: FakeServer(initial: document ?? seedDocument(mode)),
    );
    _add(a);
    if (starred) _s.stars.putIfAbsent(accountId, () => <String>{}).add(a.id);
    return _info(a);
  }

  /// The document of app [id] (for a `FakeTransport` / the editor). Throws `404 app_deleted` once deleted.
  FakeServer server(String id) => _live(id).server;

  /// Whether app [id] was deleted.
  bool isDeleted(String id) => _s.apps[id]?.deleted ?? false;

  /// Every app id, deleted ones included, in creation order.
  List<String> get appIds => _s.apps.keys.toList();

  /// Records a committed edit of app [id] at [at] (default now): what a commit on [server] does by itself.
  void touch(String id, {DateTime? at}) => _live(id).updatedAt = at ?? _s.clock();

  /// The server's seed of a blank app: a workflow gets one start node ("User Input" at 80, 282); a chatflow Dify's
  /// chatflow template (start -> LLM -> answer, `retriever_resource` on).
  static Document seedDocument(String mode) =>
      FakeDifyDsl.importValue(seedDsl(mode), newSecretRef: () => 'unused', newId: () => 'unused').document;

  /// The seed as a Dify DSL map (the server's `AppSeeds`).
  static Map<String, Object?> seedDsl(String mode) {
    Map<String, Object?> node(String id, String type, String title, int x, Map<String, Object?> data, {int? height}) =>
        {
          'id': id,
          'type': 'custom',
          'position': {'x': x, 'y': 282},
          'positionAbsolute': {'x': x, 'y': 282},
          'width': 240,
          'height': height ?? (type == 'start' ? 54 : 98),
          'sourcePosition': 'right',
          'targetPosition': 'left',
          'data': {'type': type, 'title': title, 'desc': '', ...data},
        };
    Map<String, Object?> edge(String s, String t, String st, String tt) => {
      'id': '$s-source-$t-target',
      'type': 'custom',
      'source': s,
      'sourceHandle': 'source',
      'target': t,
      'targetHandle': 'target',
      'data': {'sourceType': st, 'targetType': tt, 'isInIteration': false, 'isInLoop': false},
      'zIndex': 0,
    };
    final chat = mode == AppModes.advancedChat;
    return {
      'version': FakeDifyDsl.currentDslVersion,
      'kind': 'app',
      'app': {'mode': mode, 'name': '', 'icon': _defaultIcon, 'icon_background': _defaultBackground},
      'workflow': {
        'environment_variables': <Object?>[],
        'conversation_variables': <Object?>[],
        'features': chat
            ? {
                'retriever_resource': {'enabled': true},
              }
            : <String, Object?>{},
        'graph': {
          'nodes': [
            node('start', 'start', 'User Input', 80, {'variables': <Object?>[]}),
            if (chat) ...[
              node('llm', 'llm', 'LLM', 380, {
                'model': {
                  'provider': '',
                  'name': '',
                  'mode': 'chat',
                  'completion_params': {'temperature': 0.7},
                },
                'prompt_template': [
                  {'role': 'system', 'text': ''},
                ],
                'context': {'enabled': false, 'variable_selector': <Object?>[]},
                'vision': {'enabled': false},
                'memory': {
                  'window': {'enabled': false, 'size': 10},
                  'query_prompt_template': '{{#sys.query#}}\n\n{{#sys.files#}}',
                },
              }),
              node('answer', 'answer', 'Answer', 680, {
                'variables': <Object?>[],
                'answer': '{{#llm.text#}}',
              }, height: 104),
            ],
          ],
          'edges': [
            if (chat) ...[edge('start', 'llm', 'start', 'llm'), edge('llm', 'answer', 'llm', 'answer')],
          ],
          'viewport': {'x': 0, 'y': 0, 'zoom': 1},
        },
      },
    };
  }

  // ----- AppsApi -----

  @override
  Future<AppPage> list([AppListQuery query = const AppListQuery()]) async {
    _count('list');
    return _page(query, starredOnly: false);
  }

  @override
  Future<AppPage> starred([AppListQuery query = const AppListQuery(limit: 100)]) async {
    _count('starred');
    return _page(query, starredOnly: true);
  }

  @override
  Future<AppInfo> get(String id) async {
    _count('get');
    return _info(_live(id));
  }

  @override
  Future<void> star(String id) async {
    _count('star');
    _live(id);
    _s.stars.putIfAbsent(accountId, () => <String>{}).add(id);
  }

  @override
  Future<void> unstar(String id) async {
    _count('unstar');
    _live(id);
    _s.stars[accountId]?.remove(id);
  }

  @override
  Future<AppInfo> create({
    required String name,
    required String mode,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) async {
    _count('create');
    _edit();
    final n = _name(name);
    final d = _description(description) ?? '';
    final t = _iconType(iconType) ?? AppIconTypes.emoji;
    if (!const ['chat', 'agent-chat', 'advanced-chat', 'workflow', 'completion'].contains(mode)) {
      _fail(400, 'bad_request', 'mode must be one of chat, agent-chat, advanced-chat, workflow, completion');
    }
    if (!AppModes.creatable.contains(mode)) {
      _fail(400, 'unsupported_app_mode', 'dify-sf only has workflow and chatflow (advanced-chat) apps, not $mode');
    }
    final now = _s.clock();
    final a = _App(
      id: _s.newId(),
      name: n,
      description: d,
      mode: mode,
      iconType: t,
      icon: icon ?? _defaultIcon,
      iconBackground: iconBackground ?? _defaultBackground,
      useIconAsAnswerIcon: false,
      createdBy: accountId,
      createdAt: now,
      updatedBy: accountId,
      updatedAt: now,
      server: FakeServer(initial: seedDocument(mode)),
    );
    _add(a);
    return _info(a);
  }

  @override
  Future<AppImport> importDsl(
    String yamlContent, {
    String? name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) async {
    _count('importDsl');
    _edit();
    final overrides = (
      name: name == null ? null : _name(name),
      description: _description(description),
      iconType: _iconType(iconType),
      icon: icon,
      iconBackground: iconBackground,
    );
    return _import(yamlContent, overrides, confirmed: false);
  }

  @override
  Future<AppImport> importDslUrl(String url) async =>
      throw const TransportException('URL imports require an HTTP server');

  @override
  Future<AppImport> confirmImport(String importId) async {
    _count('confirmImport');
    _edit();
    // Only its own account takes (and so uses up) a pending import; an expired one is gone.
    final p = _s.pending[importId];
    if (p == null || p.account != accountId) _fail(404, 'not_found', 'Import information expired or does not exist');
    _s.pending.remove(importId);
    if (_s.clock().difference(p.at) > const Duration(minutes: 10)) {
      _fail(404, 'not_found', 'Import information expired or does not exist');
    }
    return _import(p.yaml, p.overrides, confirmed: true, importId: importId);
  }

  @override
  Future<AppInfo> update(
    String id, {
    required String name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
    bool? useIconAsAnswerIcon,
    int? maxActiveRequests,
  }) async {
    _count('update');
    _edit();
    final a = _live(id);
    final n = _name(name);
    final d = _description(description);
    final t = _iconType(iconType);
    if (maxActiveRequests != null && maxActiveRequests < 0) {
      _fail(400, 'bad_request', 'max_active_requests must not be negative');
    }
    a
      ..name = n
      ..description = d ?? a.description
      ..iconType = t ?? a.iconType
      ..icon = icon ?? a.icon
      ..iconBackground = iconBackground ?? a.iconBackground
      ..useIconAsAnswerIcon = useIconAsAnswerIcon ?? a.useIconAsAnswerIcon
      ..maxActiveRequests = maxActiveRequests ?? a.maxActiveRequests
      ..updatedAt = _s.clock()
      ..updatedBy = accountId;
    a.server.announceApp();
    return _info(a);
  }

  @override
  Future<AppInfo> copy(
    String id, {
    String? name,
    String? description,
    String? iconType,
    String? icon,
    String? iconBackground,
  }) async {
    _count('copy');
    _edit();
    final src = _live(id);
    final n = name == null ? src.name : _name(name);
    final d = _description(description) ?? src.description;
    final t = _iconType(iconType) ?? src.iconType;
    if (secretsKeyMissing && src.server.secrets.isNotEmpty) _secretsKeyMissing();
    // A fresh document with the original's content at head (no stamps or tombstones: the copy starts at seq 0).
    final head = src.server.doc;
    final server = FakeServer(
      initial: Document(nodes: head.nodes.values, edges: head.edges.values, app: head.app),
    )..difyApp = src.server.difyApp == null ? null : Map.of(src.server.difyApp!);
    // Re-seal: fresh references for the copy (the server encrypts them again for the new document id).
    final renamed = <String, String>{};
    for (final e in src.server.secrets.entries) {
      final ref = _s.newSecretRef();
      server.secrets[ref] = e.value;
      renamed[e.key] = ref;
    }
    if (renamed.isNotEmpty) server.doc = _renameSecretRefs(server.doc, renamed);
    final now = _s.clock();
    final a = _App(
      id: _s.newId(),
      name: n,
      description: d,
      mode: src.mode,
      iconType: t,
      icon: icon ?? src.icon,
      iconBackground: iconBackground ?? src.iconBackground,
      useIconAsAnswerIcon: src.useIconAsAnswerIcon,
      maxActiveRequests: src.maxActiveRequests,
      createdBy: accountId,
      createdAt: now,
      updatedBy: accountId,
      updatedAt: now,
      server: server,
    );
    _add(a);
    return _info(a);
  }

  @override
  Future<void> delete(String id) async {
    _count('delete');
    _edit();
    final a = _live(id)..deleted = true;
    a.server.markDeleted();
  }

  @override
  Future<String> exportDsl(String id, {bool includeSecret = false}) async {
    _count('exportDsl');
    _edit();
    if (includeSecret && !AccountRole.isPrivileged(role)) {
      _fail(403, 'forbidden', 'only the workspace owner or an admin may export secrets');
    }
    final a = _live(id);
    return const JsonEncoder.withIndent('  ').convert(_exportValue(a, includeSecret: includeSecret));
  }

  // ----- internals -----

  static const _defaultIcon = '🤖';
  static const _defaultBackground = '#FFEAD5';

  void _count(String name) => requests[name] = (requests[name] ?? 0) + 1;

  Never _fail(int status, String code, String message) =>
      throw TransportException(message, statusCode: status, code: code);

  Never _secretsKeyMissing() => _fail(
    503,
    'secrets_key_missing',
    'the server has no secrets key (COLLAB_SECRETS_KEY), so it cannot store secrets',
  );

  void _edit() {
    if (!AccountRole.canEdit(role)) _fail(403, 'forbidden', 'the $role role cannot edit');
  }

  void _privileged() {
    if (!AccountRole.isPrivileged(role)) _fail(403, 'forbidden', 'only the workspace owner or an admin may do this');
  }

  AppSite _siteOf(_App a) => AppSite.fromJson({
    'app_id': a.id,
    'access_token': a.site.code,
    'code': a.site.code,
    ...a.site.json,
    'app_base_url': origin,
  });

  VersionAccount? _accountOf(String? id) =>
      id == null ? null : VersionAccount(id: id, name: _s.names[id] ?? id, email: _s.emails[id] ?? '$id@example.com');

  WorkflowVersion _workflowOf(_App a, Map<String, Object?> dsl, Map<String, Object?> fields) {
    final w = dsl['workflow'] is Map<String, Object?> ? dsl['workflow']! as Map<String, Object?> : const {};
    List<Object?> masked(Object? vars) => [
      if (vars is List<Object?>)
        for (final v in vars)
          if (v is Map<String, Object?> && v['value_type'] == 'secret') {...v, 'value': ''} else v,
    ];
    return WorkflowVersion.fromJson({
      ...fields,
      'graph': w['graph'],
      'features': w['features'],
      'hash': _hash(dsl),
      'tool_published': false,
      'environment_variables': masked(w['environment_variables']),
      'conversation_variables': w['conversation_variables'] ?? const <Object?>[],
      'rag_pipeline_variables': const <Object?>[],
    });
  }

  WorkflowVersion _versionOf(_App a, _Version v) => _workflowOf(a, v.dsl, {
    'id': v.id,
    'version': _versionString(v.createdAt),
    'version_number': v.number,
    'marked_name': v.markedName,
    'marked_comment': v.markedComment,
    'created_by': _accountOf(v.createdBy)?.toJson(),
    'created_at': _seconds(v.createdAt),
    'updated_by': _accountOf(v.updatedBy)?.toJson(),
    'updated_at': _seconds(v.updatedAt),
  });

  WorkflowVersion _draftOf(_App a) => _workflowOf(a, _exportValue(a), {
    'id': a.id,
    'version': 'draft',
    'version_number': null,
    'marked_name': '',
    'marked_comment': '',
    'created_by': _accountOf(a.createdBy)?.toJson(),
    'created_at': _seconds(a.createdAt),
    'updated_by': _accountOf(a.updatedBy)?.toJson(),
    'updated_at': _seconds(a.updatedAt),
  });

  /// Dify's `str(datetime)` of a UTC time: `YYYY-MM-DD HH:MM:SS[.ffffff]`.
  static String _versionString(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final base =
        '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)} ${two(u.hour)}:${two(u.minute)}:${two(u.second)}';
    final micros = u.millisecond * 1000 + u.microsecond;
    return micros == 0 ? base : '$base.${micros.toString().padLeft(6, '0')}';
  }

  _App _live(String id) {
    final a = _s.apps[id];
    if (a == null) _fail(404, 'not_found', 'no app $id');
    if (a.deleted) _fail(404, 'app_deleted', 'app $id was deleted');
    return a;
  }

  String _name(String name) {
    final n = name.trim();
    if (n.isEmpty) _fail(400, 'bad_request', 'name must not be empty');
    return n;
  }

  String? _description(String? d) {
    if (d != null && d.length > 400) _fail(400, 'bad_request', 'description must be at most 400 characters');
    return d;
  }

  String? _iconType(String? t) {
    if (t != null && !AppIconTypes.all.contains(t)) _fail(400, 'bad_request', 'icon_type must be emoji, image or link');
    return t;
  }

  void _add(_App a) {
    // Dify's `create_site_record_when_app_created`: title and icon from the app, the creator's language, a new code.
    a.site = _Site(
      code: _s.newSiteCode(),
      json: {
        'title': a.name,
        'icon_type': a.iconType,
        'icon': a.icon,
        'icon_background': a.iconBackground,
        'description': null,
        'default_language': 'en-US',
        'chat_color_theme': null,
        'chat_color_theme_inverted': false,
        'customize_domain': null,
        'copyright': null,
        'privacy_policy': null,
        'input_placeholder': null,
        'custom_disclaimer': '',
        'customize_token_strategy': CustomizeTokenStrategy.notAllow,
        'prompt_public': false,
        'show_workflow_steps': true,
        'use_icon_as_answer_icon': false,
      },
      updatedBy: a.createdBy,
    );
    _s.apps[a.id] = a;
    // A commit bumps "last modified" (not `updated_by`, which is the last app-row change), as the server's.
    a.server.addListener((LogEntry _) {
      if (!a.deleted) a.updatedAt = _s.clock();
    });
  }

  AppPage _page(AppListQuery q, {required bool starredOnly}) {
    if (q.page < 1 || q.page > 99999) _fail(400, 'bad_request', 'page must be 1-99999');
    if (q.limit < 1 || q.limit > 100) _fail(400, 'bad_request', 'limit must be 1-100');
    if (!AppModes.filters.contains(q.mode)) _fail(400, 'bad_request', 'unknown mode ${q.mode}');
    if (!AppSortBy.all.contains(q.sortBy)) _fail(400, 'bad_request', 'unknown sort_by ${q.sortBy}');
    final stars = _s.stars[accountId] ?? const <String>{};
    final name = q.name == null || q.name!.isEmpty
        ? null
        : (q.name!.length > 30 ? q.name!.substring(0, 30) : q.name!).toLowerCase();
    final creators = q.creatorIds.map((c) => c.trim()).where((c) => c.isNotEmpty).toSet();
    final all = [
      for (final a in _s.apps.values)
        if (!a.deleted &&
            (!starredOnly || stars.contains(a.id)) &&
            (q.mode == AppModes.all || a.mode == q.mode) &&
            (q.isCreatedByMe != true || a.createdBy == accountId) &&
            (creators.isEmpty || creators.contains(a.createdBy)) &&
            (name == null || a.name.toLowerCase().contains(name)))
          a,
    ];
    int byId(_App x, _App y) => x.id.compareTo(y.id);
    all.sort(switch (q.sortBy) {
      AppSortBy.recentlyCreated => (x, y) {
        final c = y.createdAt.compareTo(x.createdAt);
        return c != 0 ? c : byId(x, y);
      },
      AppSortBy.earliestCreated => (x, y) {
        final c = x.createdAt.compareTo(y.createdAt);
        return c != 0 ? c : byId(x, y);
      },
      _ => (x, y) {
        final c = y.updatedAt.compareTo(x.updatedAt);
        return c != 0 ? c : byId(x, y);
      },
    });
    final start = (q.page - 1) * q.limit;
    final data = start >= all.length ? const <_App>[] : all.sublist(start, (start + q.limit).clamp(0, all.length));
    return AppPage(
      page: q.page,
      limit: q.limit,
      total: all.length,
      hasMore: start + q.limit < all.length,
      data: [for (final a in data) _info(a)],
    );
  }

  static int _seconds(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

  AppInfo _info(_App a) {
    final author = _s.names[a.createdBy] ?? a.createdBy;
    final json = <String, Object?>{
      'id': a.id,
      'name': a.name,
      'description': a.description,
      'mode': a.mode,
      'icon_type': a.iconType,
      'icon': a.icon,
      'icon_background': a.iconBackground,
      'icon_url': null,
      'use_icon_as_answer_icon': a.useIconAsAnswerIcon,
      'max_active_requests': a.maxActiveRequests,
      'model_config': null,
      'workflow': {
        'id': a.id,
        'created_by': a.createdBy,
        'created_at': _seconds(a.createdAt),
        'updated_by': a.updatedBy,
        'updated_at': _seconds(a.updatedAt),
      },
      'created_by': a.createdBy,
      'created_at': _seconds(a.createdAt),
      'updated_by': a.updatedBy,
      'updated_at': _seconds(a.updatedAt),
      'tags': const <Object?>[],
      'access_mode': null,
      'create_user_name': author,
      'author_name': author,
      'has_draft_trigger': false,
      'permission_keys': AppPermissionKeys.forRole(role),
      'is_starred': _s.stars[accountId]?.contains(a.id) ?? false,
      'maintainer': null,
      'bound_agent_id': null,
      'enable_site': a.enableSite,
      'enable_api': a.enableApi,
      'site': _siteOf(a).toJson(),
      'api_base_url': '$origin/v1',
      'deleted_tools': const <Object?>[],
    };
    return AppInfo.fromJson(json);
  }

  AppImport _import(
    String yaml,
    _Overrides o, {
    required bool confirmed,
    String? importId,
  }) {
    final id = importId ?? _s.newImportId();
    AppImport failed(String error, {String imported = ''}) => AppImport(
      id: id,
      status: AppImportStatus.failed,
      currentDslVersion: FakeDifyDsl.currentDslVersion,
      importedDslVersion: imported,
      error: error,
    );
    final Object? root;
    try {
      root = FakeDifyDsl.parseYaml(yaml);
    } on Object catch (e) {
      return failed('Invalid YAML format: $e');
    }
    final mode = root is Map<String, Object?> && root['app'] is Map<String, Object?>
        ? (root['app']! as Map<String, Object?>)['mode']
        : null;
    final ({String version, String status}) checked;
    try {
      checked = FakeDifyDsl.checkReplacement(
        root,
        appMode: mode is String ? mode : AppModes.workflow,
        confirm: confirmed,
      );
    } on FakeReplaceRefusal catch (e) {
      if (e.pendingVersion != null) {
        _s.pending[id] = (account: accountId, yaml: yaml, overrides: o, at: _s.clock());
        return AppImport(
          id: id,
          status: AppImportStatus.pending,
          currentDslVersion: FakeDifyDsl.currentDslVersion,
          importedDslVersion: e.pendingVersion!,
        );
      }
      final v = root is Map<String, Object?> && root['version'] is String ? root['version']! as String : '';
      // The server's wording for a new app (the refusal is the overwrite check's).
      final message = e.message.startsWith('Only workflow or advanced chat apps can be overwritten')
          ? 'dify-sf only has workflow and chatflow (advanced-chat) apps, the file is a $mode app'
          : e.message;
      return failed(message, imported: v);
    }
    final ({Document document, Map<String, String> secrets, Map<String, Object?> app}) imported;
    final server = FakeServer();
    try {
      imported = FakeDifyDsl.importValue(root, newSecretRef: server.newSecretRef, newId: _s.newVariableId);
    } on FormatException catch (e) {
      return failed(e.message, imported: checked.version);
    }
    if (imported.secrets.isNotEmpty && secretsKeyMissing) _secretsKeyMissing();
    server
      ..doc = imported.document
      ..difyApp = imported.app
      ..secrets.addAll(imported.secrets);
    final app = imported.app;
    String? str(String k) => app[k] is String && (app[k]! as String).isNotEmpty ? app[k]! as String : null;
    final now = _s.clock();
    final a = _App(
      id: _s.newId(),
      name: o.name ?? str('name') ?? '',
      description: o.description ?? str('description') ?? '',
      mode: mode! as String,
      iconType: o.iconType ?? str('icon_type') ?? AppIconTypes.emoji,
      icon: o.icon ?? str('icon') ?? _defaultIcon,
      iconBackground: o.iconBackground ?? str('icon_background') ?? _defaultBackground,
      useIconAsAnswerIcon: app['use_icon_as_answer_icon'] == true,
      createdBy: accountId,
      createdAt: now,
      updatedBy: accountId,
      updatedAt: now,
      server: server,
    );
    _add(a);
    return AppImport(
      id: id,
      // A confirmed pending import is completed (Dify's `confirm_import`).
      status: checked.status == AppImportStatus.pending ? AppImportStatus.completed : checked.status,
      appId: a.id,
      appMode: a.mode,
      currentDslVersion: FakeDifyDsl.currentDslVersion,
      importedDslVersion: checked.version,
    );
  }

  /// A Dify DSL of app [a] at head (plain data, JSON is valid YAML): the app row's `app` section and the graph. Not
  /// byte-equal to the server's export (which keeps every Dify-only member); enough to import again.
  Map<String, Object?> _exportValue(_App a, {bool includeSecret = false}) {
    final doc = a.server.doc;
    final ids = doc.nodes.keys.toList()..sort();
    Map<String, Object?> plainMap(Map<String, Value> m) => {for (final e in m.entries) e.key: _plain(e.value)};
    final app = <String, Object?>{
      'description': a.description,
      'icon': a.icon,
      'icon_background': a.iconBackground,
      'icon_type': a.iconType,
      'mode': a.mode,
      'name': a.name,
      'use_icon_as_answer_icon': a.useIconAsAnswerIcon,
    };
    List<Object?> variables(String key) => [
      for (final v in AppRegisters.variables(doc, key))
        if (key == AppRegisters.environmentVariables && v['value_type'] == 'secret')
          {
            ...Map.of(v)..remove(AppRegisters.secretRef),
            'value': includeSecret ? (a.server.secrets[v[AppRegisters.secretRef]] ?? '') : '',
          }
        else
          v,
    ];
    return {
      'app': app,
      'kind': 'app',
      'version': FakeDifyDsl.currentDslVersion,
      'workflow': {
        'conversation_variables': variables(AppRegisters.conversationVariables),
        'environment_variables': variables(AppRegisters.environmentVariables),
        'features': AppRegisters.featuresOf(doc),
        'graph': {
          'edges': [
            for (final e in doc.edges.values)
              {
                'id': e.id,
                'source': e.source,
                'sourceHandle': e.sourceHandle,
                'target': e.target,
                'targetHandle': e.targetHandle,
                'type': 'custom',
              },
          ],
          'nodes': [
            for (final id in ids)
              () {
                final n = doc.nodes[id]!;
                final config = Map.of(n.config);
                final extra = config.remove('_dify_node');
                final data = plainMap(config);
                if (n.type == 'code' && config['outputs'] is VItems) {
                  data['outputs'] = {
                    for (final i in (config['outputs']! as VItems).items)
                      i.id: {...(_plain(i.value)! as Map<String, Object?>)}..remove('name'),
                  };
                }
                return {
                  if (extra is VMap) ...plainMap(extra.entries),
                  'id': n.id,
                  'position': {'x': n.x, 'y': n.y},
                  'type': 'custom',
                  'data': {...data, 'type': n.type, 'title': n.title},
                };
              }(),
          ],
        },
      },
    };
  }

  static Object? _plain(Value v) => switch (v) {
    VNull() => null,
    VBool(:final value) => value,
    VInt(:final value) => value,
    VDouble(:final value) => value,
    VString(:final value) => value,
    VRef(:final ref) || VBroken(:final ref) => [ref.node, ref.output],
    VList(:final items) => [for (final x in items) _plain(x)],
    VItems(:final items) => [for (final i in items) _plain(i.value)],
    VMap(:final entries) => {for (final e in entries.entries) e.key: _plain(e.value)},
  };

  static Document _renameSecretRefs(Document doc, Map<String, String> renamed) {
    final json = doc.toJson();
    Object? walk(Object? v) => switch (v) {
      final Map<String, Object?> m => {
        for (final e in m.entries)
          e.key: e.key == AppRegisters.secretRef && e.value is String && renamed.containsKey(e.value)
              ? renamed[e.value]
              : walk(e.value),
      },
      final List<Object?> xs => [for (final x in xs) walk(x)],
      _ => v,
    };
    return Document.fromJson(walk(json));
  }
}

typedef _Overrides = ({String? name, String? description, String? iconType, String? icon, String? iconBackground});

class _App {
  _App({
    required this.id,
    required this.name,
    required this.description,
    required this.mode,
    required this.iconType,
    required this.icon,
    required this.iconBackground,
    required this.useIconAsAnswerIcon,
    this.maxActiveRequests,
    required this.createdBy,
    required this.createdAt,
    required this.updatedBy,
    required this.updatedAt,
    required this.server,
  });

  final String id;
  String name;
  String description;
  final String mode;
  String? iconType;
  String? icon;
  String? iconBackground;
  bool useIconAsAnswerIcon;
  int? maxActiveRequests;
  final String createdBy;
  final DateTime createdAt;
  String updatedBy;
  DateTime updatedAt;
  final FakeServer server;
  bool deleted = false;

  // Protocol 1.11 (FakeAccessApi, FakeAnnotationsApi, FakeVersionsApi).
  bool enableSite = true;
  bool enableApi = true;
  late _Site site;
  final List<_Key> keys = [];
  final List<_Annotation> annotations = [];
  AnnotationSetting? annotationSetting;
  final List<_Version> versions = [];
  int lastVersionNumber = 0;
}

class _State {
  _State(this.clock);

  DateTime Function() clock;
  String origin = 'http://localhost:8080';
  final Map<String, _App> apps = {};
  final Map<String, Set<String>> stars = {};
  final Map<String, String> names = {};
  final Map<String, String> emails = {};
  final Map<String, ({String account, String yaml, _Overrides overrides, DateTime at})> pending = {};
  final Map<String, int> requests = {};
  int _apps = 0, _imports = 0, _variables = 0;

  String newId() => 'app-${(++_apps).toString().padLeft(4, '0')}';

  // Protocol 1.11.
  final Random _random = Random(1711);
  final Map<String, String> jobs = {};
  int _keys = 0, _annotations = 0, _jobs = 0, _settings = 0, _versions = 0;
  static const _letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  /// Dify's `generate_string(n)`: letters and digits (seeded: the fake is deterministic).
  String randomString(int n) =>
      String.fromCharCodes([for (var i = 0; i < n; i++) _letters.codeUnitAt(_random.nextInt(62))]);
  String newSiteCode() {
    while (true) {
      final c = randomString(16);
      if (!apps.values.any((a) => a.site.code == c)) return c;
    }
  }

  String newKeyId() => 'key-${++_keys}';
  String newAnnotationId() => 'ann-${(++_annotations).toString().padLeft(5, '0')}';
  String newJobId() => 'job-${++_jobs}';
  String newSettingId() => 'setting-${++_settings}';
  String newVersionId() => 'version-${(++_versions).toString().padLeft(4, '0')}';
  String newImportId() => 'import-${++_imports}';
  String newVariableId() => 'var-${++_variables}';

  /// Secret references of copies, unique across the workspace's documents (the server's are random).
  String newSecretRef() => 'sec-${(0xc0de0000 + ++_secretRefs).toRadixString(16).padLeft(32, '0')}';
  int _secretRefs = 0;
}
