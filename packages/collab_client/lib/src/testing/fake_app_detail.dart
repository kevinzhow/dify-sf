part of 'fake_apps.dart';

/// An in-memory [AccessApi] on the apps of a [FakeAppsApi] (protocol 1.11), with the server's rules: Dify's community
/// edition roles (site settings, the site switch and key list / create: owner, admin, editor; token reset, the API
/// switch and key delete: owner, admin), the site validation (languages, `#RGB` / `#RRGGBB` colours, `http(s)` privacy
/// URL, disclaimer at most 512 and placeholder at most 64 characters, token strategies), keys `app-` + 24 characters,
/// at most 10 per app. Every app of [apps] has a site from its creation (title, icon from the app; language `en-US`;
/// a 16-character code). The caller is [apps]' account and role (use `apps.asAccount(...)` for another member).
/// [secretsKeyMissing] of [apps] makes key creation fail like a server without a secrets key.
class FakeAccessApi implements AccessApi {
  FakeAccessApi(this.apps);

  final FakeAppsApi apps;

  @override
  Future<AppSite> updateSite(String appId, AppSiteUpdate update) async {
    apps._count('updateSite');
    apps._edit();
    final a = apps._live(appId);
    final u = update;
    if (u.defaultLanguage != null && !AppSiteLanguages.all.contains(u.defaultLanguage)) {
      apps._fail(400, 'bad_request', '${u.defaultLanguage} is not a valid language.');
    }
    if (u.chatColorTheme != null && u.chatColorTheme!.isNotEmpty && !_hexColor.hasMatch(u.chatColorTheme!)) {
      apps._fail(400, 'bad_request', 'chat_color_theme must be a colour like #1C64F2');
    }
    if (u.privacyPolicy != null &&
        u.privacyPolicy!.isNotEmpty &&
        !(u.privacyPolicy!.startsWith('http://') || u.privacyPolicy!.startsWith('https://'))) {
      apps._fail(400, 'bad_request', 'privacy_policy must be an http(s) URL');
    }
    if (u.customDisclaimer != null && u.customDisclaimer!.length > AppSiteLimits.disclaimerMaxLength) {
      apps._fail(400, 'bad_request', 'Custom disclaimer cannot exceed 512 characters.');
    }
    if (u.inputPlaceholder != null && u.inputPlaceholder!.length > AppSiteLimits.placeholderMaxLength) {
      apps._fail(400, 'bad_request', 'input_placeholder must be at most 64 characters');
    }
    if (u.customizeTokenStrategy != null && !CustomizeTokenStrategy.all.contains(u.customizeTokenStrategy)) {
      apps._fail(400, 'bad_request', 'customize_token_strategy must be one of must, allow, not_allow');
    }
    if (u.iconType != null && !AppIconTypes.all.contains(u.iconType)) {
      apps._fail(400, 'bad_request', 'icon_type must be emoji, image or link');
    }
    final s = a.site;
    s.json = {
      ...s.json,
      for (final e in u.toJson().entries) e.key: e.value,
    };
    s.updatedBy = apps.accountId;
    return apps._siteOf(a);
  }

  @override
  Future<AppSite> resetAccessToken(String appId) async {
    apps._count('resetAccessToken');
    apps._privileged();
    final a = apps._live(appId);
    a.site.code = apps._s.newSiteCode();
    a.site.updatedBy = apps.accountId;
    return apps._siteOf(a);
  }

  @override
  Future<AppInfo> setSiteEnabled(String appId, bool enable) async {
    apps._count('setSiteEnabled');
    apps._edit();
    final a = apps._live(appId);
    if (a.enableSite != enable) {
      a
        ..enableSite = enable
        ..updatedBy = apps.accountId
        ..updatedAt = apps._s.clock();
    }
    return apps._info(a);
  }

  @override
  Future<AppInfo> setApiEnabled(String appId, bool enable) async {
    apps._count('setApiEnabled');
    apps._privileged();
    final a = apps._live(appId);
    if (a.enableApi != enable) {
      a
        ..enableApi = enable
        ..updatedBy = apps.accountId
        ..updatedAt = apps._s.clock();
    }
    return apps._info(a);
  }

  @override
  Future<List<AppApiKey>> listApiKeys(String appId) async {
    apps._count('listApiKeys');
    apps._edit();
    return [for (final k in apps._live(appId).keys) k.toKey()];
  }

  @override
  Future<AppApiKey> createApiKey(String appId) async {
    apps._count('createApiKey');
    apps._edit();
    final a = apps._live(appId);
    if (a.keys.length >= 10) {
      apps._fail(400, 'max_keys_exceeded', 'Cannot create more than 10 API keys for this resource type.');
    }
    if (apps.secretsKeyMissing) apps._secretsKeyMissing();
    final k = _Key(id: apps._s.newKeyId(), token: 'app-${apps._s.randomString(24)}', createdAt: apps._s.clock());
    a.keys.add(k);
    return k.toKey();
  }

  @override
  Future<void> deleteApiKey(String appId, String keyId) async {
    apps._count('deleteApiKey');
    apps._privileged();
    final a = apps._live(appId);
    final before = a.keys.length;
    a.keys.removeWhere((k) => k.id == keyId);
    if (a.keys.length == before) apps._fail(404, 'not_found', 'API key not found');
  }

  static final _hexColor = RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$');
}

/// An in-memory [AnnotationsApi] on the apps of a [FakeAppsApi] (protocol 1.11), with the server's rules: chatflows only
/// (`404 app_not_found` for workflow apps), owner / admin / editor (the count: any member), Dify's list (keyword on
/// question or answer, newest first, `has_more = data.length == limit`), Dify's CSV import rules and messages (header
/// row, two columns, 1-10000 rows, question <= 2000 and answer <= 10000 characters, 2 MB), jobs that complete at once
/// (`waiting` in the answer, `completed` when polled), the reply setting stored (enable creates or updates it, disable
/// removes it). [hitHistories] is always empty.
class FakeAnnotationsApi implements AnnotationsApi {
  FakeAnnotationsApi(this.apps);

  final FakeAppsApi apps;

  _App _chat(String appId, {bool edit = true}) {
    if (edit) apps._edit();
    final a = apps._live(appId);
    if (a.mode != AppModes.advancedChat) {
      apps._fail(404, 'app_not_found', "App mode is not in the supported list: {'advanced-chat'}");
    }
    return a;
  }

  _Annotation _find(_App a, String id) {
    for (final x in a.annotations) {
      if (x.id == id) return x;
    }
    apps._fail(404, 'not_found', 'Annotation not found');
  }

  List<_Annotation> _sorted(_App a) => [...a.annotations]
    ..sort((x, y) {
      final c = y.createdAt.compareTo(x.createdAt);
      return c != 0 ? c : y.id.compareTo(x.id);
    });

  @override
  Future<AnnotationPage> list(String appId, {int page = 1, int limit = 20, String keyword = ''}) async {
    apps._count('annotations.list');
    final a = _chat(appId);
    if (page < 1) apps._fail(400, 'bad_request', 'page must be >= 1');
    if (limit < 1) apps._fail(400, 'bad_request', 'limit must be >= 1');
    final k = keyword.toLowerCase();
    final all = [
      for (final x in _sorted(a))
        if (k.isEmpty || x.question.toLowerCase().contains(k) || x.answer.toLowerCase().contains(k)) x,
    ];
    final per = limit > 100 ? 100 : limit;
    final start = (page - 1) * per;
    final data = start >= all.length ? const <_Annotation>[] : all.sublist(start, (start + per).clamp(0, all.length));
    return AnnotationPage(
      data: [for (final x in data) x.toAnnotation()],
      hasMore: data.length == limit,
      limit: limit,
      total: all.length,
      page: page,
    );
  }

  @override
  Future<int> count(String appId) async {
    apps._count('annotations.count');
    return _chat(appId, edit: false).annotations.length;
  }

  @override
  Future<List<Annotation>> export(String appId) async {
    apps._count('annotations.export');
    return [for (final x in _sorted(_chat(appId))) x.toAnnotation()];
  }

  @override
  Future<Annotation> create(String appId, {required String question, required String answer}) async {
    apps._count('annotations.create');
    final a = _chat(appId);
    if (answer.isEmpty) apps._fail(400, 'bad_request', "Either 'answer' or 'content' must be provided");
    if (question.isEmpty) apps._fail(400, 'bad_request', "'question' is required when 'message_id' is not provided");
    final x = _Annotation(
      id: apps._s.newAnnotationId(),
      question: question,
      answer: answer,
      accountId: apps.accountId,
      createdAt: apps._s.clock(),
    );
    a.annotations.add(x);
    return x.toAnnotation();
  }

  @override
  Future<Annotation> update(
    String appId,
    String annotationId, {
    required String question,
    required String answer,
  }) async {
    apps._count('annotations.update');
    final a = _chat(appId);
    final x = _find(a, annotationId);
    if (question.isEmpty) apps._fail(400, 'bad_request', "'question' is required");
    if (answer.isEmpty) apps._fail(400, 'bad_request', "'answer' is required");
    x
      ..question = question
      ..answer = answer;
    return x.toAnnotation();
  }

  @override
  Future<void> delete(String appId, String annotationId) async {
    apps._count('annotations.delete');
    final a = _chat(appId);
    a.annotations.remove(_find(a, annotationId));
  }

  @override
  Future<void> deleteMany(String appId, List<String> annotationIds) async {
    apps._count('annotations.deleteMany');
    if (annotationIds.isEmpty) return;
    final a = _chat(appId);
    if (annotationIds.any((i) => i.trim().isEmpty)) {
      apps._fail(400, 'bad_request', 'annotation_ids are required if the parameter is provided.');
    }
    final ids = annotationIds.toSet();
    a.annotations.removeWhere((x) => ids.contains(x.id));
  }

  @override
  Future<void> clearAll(String appId) async {
    apps._count('annotations.clearAll');
    _chat(appId).annotations.clear();
  }

  @override
  Future<AnnotationJob> batchImport(String appId, List<int> csvBytes, {String filename = 'annotations.csv'}) async {
    apps._count('annotations.batchImport');
    final a = _chat(appId);
    if (!filename.toLowerCase().endsWith('.csv')) {
      apps._fail(400, 'bad_request', 'Invalid file type. Only CSV files are allowed');
    }
    if (csvBytes.length > AnnotationImportRules.maxBytes) {
      apps._fail(
        413,
        'payload_too_large',
        'File size exceeds maximum limit of 2MB. Please reduce the file size and try again.',
      );
    }
    if (csvBytes.isEmpty) apps._fail(400, 'bad_request', 'The uploaded file is empty');
    final parsed = AnnotationImportRules.parse(csvBytes);
    if (parsed.error != null) return AnnotationJob(errorMsg: parsed.error!);
    final now = apps._s.clock();
    for (final r in parsed.rows) {
      a.annotations.add(
        _Annotation(
          id: apps._s.newAnnotationId(),
          question: r.question,
          answer: r.answer,
          accountId: apps.accountId,
          createdAt: now,
        ),
      );
    }
    final job = apps._s.newJobId();
    apps._s.jobs['import:$job'] = AnnotationJobStatus.completed;
    return AnnotationJob(jobId: job, jobStatus: AnnotationJobStatus.waiting, recordCount: parsed.rows.length);
  }

  @override
  Future<AnnotationJob> batchImportStatus(String appId, String jobId) async {
    apps._count('annotations.batchImportStatus');
    _chat(appId);
    final s = apps._s.jobs['import:$jobId'];
    if (s == null) apps._fail(400, 'bad_request', 'The job does not exist.');
    return AnnotationJob(jobId: jobId, jobStatus: s);
  }

  @override
  Future<AnnotationSetting> setting(String appId) async {
    apps._count('annotations.setting');
    return _chat(appId).annotationSetting ?? AnnotationSetting.disabled;
  }

  @override
  Future<AnnotationJob> enableReply(
    String appId, {
    required double scoreThreshold,
    required String embeddingProviderName,
    required String embeddingModelName,
  }) async {
    apps._count('annotations.enableReply');
    final a = _chat(appId);
    a.annotationSetting = AnnotationSetting(
      enabled: true,
      id: a.annotationSetting?.id ?? apps._s.newSettingId(),
      scoreThreshold: scoreThreshold,
      embeddingProviderName: embeddingProviderName,
      embeddingModelName: embeddingModelName,
    );
    final job = apps._s.newJobId();
    apps._s.jobs['enable:$job'] = AnnotationJobStatus.completed;
    return AnnotationJob(jobId: job, jobStatus: AnnotationJobStatus.waiting);
  }

  @override
  Future<AnnotationJob> disableReply(String appId) async {
    apps._count('annotations.disableReply');
    final a = _chat(appId)..annotationSetting = null;
    final job = apps._s.newJobId();
    apps._s.jobs['disable:$job'] = AnnotationJobStatus.completed;
    a.annotationSetting = null;
    return AnnotationJob(jobId: job, jobStatus: AnnotationJobStatus.waiting);
  }

  @override
  Future<AnnotationJob> replyStatus(String appId, String action, String jobId) async {
    apps._count('annotations.replyStatus');
    _chat(appId);
    final s = apps._s.jobs['$action:$jobId'];
    if (s == null) apps._fail(400, 'bad_request', 'The job does not exist.');
    return AnnotationJob(jobId: jobId, jobStatus: s);
  }

  @override
  Future<AnnotationSetting> updateSetting(String appId, String settingId, {required double scoreThreshold}) async {
    apps._count('annotations.updateSetting');
    final a = _chat(appId);
    final s = a.annotationSetting;
    if (s == null || s.id != settingId) apps._fail(404, 'not_found', 'App annotation not found');
    return a.annotationSetting = AnnotationSetting(
      enabled: true,
      id: s.id,
      scoreThreshold: scoreThreshold,
      embeddingProviderName: s.embeddingProviderName,
      embeddingModelName: s.embeddingModelName,
    );
  }

  @override
  Future<AnnotationHitHistoryPage> hitHistories(
    String appId,
    String annotationId, {
    int page = 1,
    int limit = 20,
  }) async {
    apps._count('annotations.hitHistories');
    _find(_chat(appId), annotationId);
    return AnnotationHitHistoryPage(data: const [], hasMore: limit == 0, limit: limit, total: 0, page: page);
  }
}

/// Dify's annotation CSV import rules (`AppAnnotationService.batch_import_app_annotations`), shared by the fake and the
/// tests: the first row is the header, the first two columns are question and answer (stripped; rows with an empty or
/// `nan` value are skipped), 1-10000 usable rows, question at most 2000 and answer at most 10000 characters. A refusal
/// is Dify's message in [parse]'s `error`.
abstract final class AnnotationImportRules {
  static const maxBytes = 2 * 1024 * 1024;
  static const maxRecords = 10000;
  static const minRecords = 1;

  static ({List<({String question, String answer})> rows, String? error}) parse(List<int> bytes) {
    if (!bytes.take(8192).contains(10)) {
      return (rows: const [], error: 'The CSV file appears to be empty or invalid.');
    }
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('﻿')) text = text.substring(1);
    final records = _records(text);
    if (records.isEmpty || records.first.length < 2) {
      return (
        rows: const [],
        error: 'Invalid CSV format. The file must contain at least 2 columns (question and answer).',
      );
    }
    final width = records.first.length;
    final out = <({String question, String answer})>[];
    for (var i = 1; i < records.length; i++) {
      final r = records[i];
      if (r.length > width) continue; // pandas' on_bad_lines="skip"
      if (out.length >= maxRecords) {
        return (
          rows: const [],
          error:
              'The CSV file contains too many records. Maximum $maxRecords records allowed per import. '
              'Please split your file into smaller batches.',
        );
      }
      final q = r.isNotEmpty ? r[0].trim() : '';
      final ans = r.length > 1 ? r[1].trim() : '';
      if (q.isEmpty || ans.isEmpty || q.toLowerCase() == 'nan' || ans.toLowerCase() == 'nan') continue;
      final row = i + 1;
      if (q.length > 2000) {
        return (rows: const [], error: 'Question at row $row is too long. Maximum 2000 characters allowed.');
      }
      if (ans.length > 10000) {
        return (rows: const [], error: 'Answer at row $row is too long. Maximum 10000 characters allowed.');
      }
      out.add((question: q, answer: ans));
    }
    if (out.length < minRecords) {
      return (
        rows: const [],
        error:
            'The CSV file must contain at least $minRecords valid annotation record(s). Found ${out.length} valid record(s).',
      );
    }
    return (rows: out, error: null);
  }

  /// RFC 4180 records (quoted fields with doubled quotes and line breaks; `\n` or `\r\n`); blank lines are skipped.
  static List<List<String>> _records(String text) {
    final out = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var quoted = false, any = false;
    void endField() {
      row.add(field.toString());
      field.clear();
    }

    void endRow() {
      endField();
      if (!(row.length == 1 && row.first.isEmpty && !any)) out.add(row);
      row = <String>[];
      any = false;
    }

    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"') {
        quoted = true;
        any = true;
      } else if (c == ',') {
        endField();
        any = true;
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        endRow();
      } else {
        field.write(c);
        any = true;
      }
    }
    if (field.isNotEmpty || row.isNotEmpty || any) endRow();
    return out;
  }
}

/// An in-memory [VersionsApi] on the apps of a [FakeAppsApi] (protocol 1.11), with the server's rules: owner / admin /
/// editor; a version is the app's export (with its secrets, kept in the fake) at publish time; the newest is the
/// published one (not deletable); version numbers per app, never reused; the list as Dify's (the draft first, then
/// newest first; nothing before the first publish; `user_id` must be the caller's own; `named_only`); names at most 20
/// and comments at most 100 characters; [restore] replaces the app's document through [FakeServer.replace].
class FakeVersionsApi implements VersionsApi {
  FakeVersionsApi(this.apps);

  final FakeAppsApi apps;

  _App _app(String appId) {
    apps._edit();
    final a = apps._live(appId);
    if (!AppModes.creatable.contains(a.mode)) {
      apps._fail(404, 'app_not_found', "App mode is not in the supported list: {'advanced-chat', 'workflow'}");
    }
    return a;
  }

  _Version _find(_App a, String id) {
    for (final v in a.versions) {
      if (v.id == id) return v;
    }
    apps._fail(404, 'not_found', 'Workflow not found');
  }

  @override
  Future<WorkflowVersion?> published(String appId) async {
    apps._count('versions.published');
    final a = _app(appId);
    return a.versions.isEmpty ? null : apps._versionOf(a, a.versions.last);
  }

  @override
  Future<PublishResult> publish(String appId, {String? markedName, String? markedComment}) async {
    apps._count('versions.publish');
    final a = _app(appId);
    _limits(markedName, markedComment);
    final now = apps._s.clock();
    final v = _Version(
      id: apps._s.newVersionId(),
      number: ++a.lastVersionNumber,
      dsl: apps._exportValue(a, includeSecret: true),
      markedName: markedName ?? '',
      markedComment: markedComment ?? '',
      createdBy: apps.accountId,
      createdAt: now,
      updatedBy: apps.accountId,
      updatedAt: now,
    );
    a.versions.add(v);
    a
      ..updatedBy = apps.accountId
      ..updatedAt = now;
    return PublishResult(result: 'success', createdAt: FakeAppsApi._seconds(now));
  }

  @override
  Future<WorkflowVersionPage> list(
    String appId, {
    int page = 1,
    int limit = 10,
    String? userId,
    bool namedOnly = false,
  }) async {
    apps._count('versions.list');
    final a = _app(appId);
    if (page < 1 || page > 99999) apps._fail(400, 'bad_request', 'page must be 1-99999');
    if (limit < 1 || limit > 100) apps._fail(400, 'bad_request', 'limit must be 1-100');
    if (userId != null && userId.isNotEmpty && userId != apps.accountId) {
      apps._fail(403, 'forbidden', 'user_id must be your own account id');
    }
    if (a.versions.isEmpty) return WorkflowVersionPage(items: const [], page: page, limit: limit, hasMore: false);
    final draft = apps._draftOf(a);
    final all = <WorkflowVersion>[
      if ((userId == null || userId.isEmpty || a.createdBy == userId) && !namedOnly) draft,
      for (final v in a.versions.reversed)
        if ((userId == null || userId.isEmpty || v.createdBy == userId) && (!namedOnly || v.markedName.isNotEmpty))
          apps._versionOf(a, v),
    ];
    final start = (page - 1) * limit;
    final items = start >= all.length
        ? const <WorkflowVersion>[]
        : all.sublist(start, (start + limit).clamp(0, all.length));
    return WorkflowVersionPage(items: items, page: page, limit: limit, hasMore: all.length > start + limit);
  }

  @override
  Future<WorkflowVersion> get(String appId, String versionId) async {
    apps._count('versions.get');
    final a = _app(appId);
    if (versionId == a.id) {
      final d = apps._draftOf(a);
      return WorkflowVersion.fromJson({...d.json, 'doc': a.server.doc.toJson()});
    }
    final v = _find(a, versionId);
    final doc = FakeDifyDsl.importValue(v.dsl, newSecretRef: () => 'unused', newId: () => 'unused').document;
    return WorkflowVersion.fromJson({...apps._versionOf(a, v).json, 'doc': doc.toJson()});
  }

  @override
  Future<String> exportDsl(String appId, String versionId, {bool includeSecret = false}) async {
    apps._count('versions.exportDsl');
    final a = _app(appId);
    if (includeSecret && !AccountRole.isPrivileged(apps.role)) {
      apps._fail(403, 'forbidden', 'only the workspace owner or an admin may export secrets');
    }
    if (versionId == a.id) return apps.exportDsl(appId, includeSecret: includeSecret);
    final v = _find(a, versionId);
    Object? strip(Object? x) => switch (x) {
      final Map<String, Object?> m => {for (final e in m.entries) e.key: strip(e.value)},
      final List<Object?> l => [for (final y in l) strip(y)],
      _ => x,
    };
    final dsl = strip(v.dsl)! as Map<String, Object?>;
    final w = dsl['workflow']! as Map<String, Object?>;
    if (!includeSecret) {
      w['environment_variables'] = [
        for (final e in (w['environment_variables'] as List<Object?>? ?? const []))
          if (e is Map<String, Object?> && e['value_type'] == 'secret') {...e, 'value': ''} else e,
      ];
    }
    dsl['app'] = {
      ...(dsl['app'] as Map<String, Object?>? ?? const {}),
      'name': a.name,
      'description': a.description,
      'icon': a.icon,
      'icon_type': a.iconType,
      'icon_background': a.iconBackground,
      'use_icon_as_answer_icon': a.useIconAsAnswerIcon,
    };
    return const JsonEncoder.withIndent('  ').convert(dsl);
  }

  @override
  Future<WorkflowVersion> update(String appId, String versionId, {String? markedName, String? markedComment}) async {
    apps._count('versions.update');
    final a = _app(appId);
    _limits(markedName, markedComment);
    if (markedName == null && markedComment == null) apps._fail(400, 'bad_request', 'No valid fields to update');
    final v = _find(a, versionId);
    v
      ..markedName = markedName ?? v.markedName
      ..markedComment = markedComment ?? v.markedComment
      ..updatedBy = apps.accountId
      ..updatedAt = apps._s.clock();
    return apps._versionOf(a, v);
  }

  @override
  Future<void> delete(String appId, String versionId) async {
    apps._count('versions.delete');
    final a = _app(appId);
    if (versionId == a.id) apps._fail(400, 'bad_request', 'Cannot delete draft workflow versions');
    final v = _find(a, versionId);
    if (identical(v, a.versions.last)) {
      apps._fail(400, 'bad_request', "Cannot delete workflow that is currently in use by app '${a.id}'");
    }
    a.versions.remove(v);
  }

  @override
  Future<ReplaceResult> restore(String appId, String versionId, String clientId, {required int cseq}) async {
    apps._count('versions.restore');
    final a = _app(appId);
    if (versionId == a.id) apps._fail(400, 'bad_request', 'source workflow must be published');
    final v = _find(a, versionId);
    try {
      a.server.requireOwnClient(clientId, apps.accountId);
      final r = a.server.replace(client: clientId, cseq: cseq, root: v.dsl);
      final now = apps._s.clock();
      return ReplaceResult.fromJson({
        ...r,
        'result': 'success',
        'hash': _hash(v.dsl),
        'updated_at': FakeAppsApi._seconds(now),
      });
    } on FakeReplaceError catch (e) {
      apps._fail(e.status, e.code, e.message);
    } on FakeAuthError catch (e) {
      apps._fail(e.status, e.code, e.message);
    }
  }

  void _limits(String? name, String? comment) {
    if (name != null && name.length > VersionLimits.nameMaxLength) {
      apps._fail(400, 'bad_request', 'marked_name must be at most 20 characters');
    }
    if (comment != null && comment.length > VersionLimits.commentMaxLength) {
      apps._fail(400, 'bad_request', 'marked_comment must be at most 100 characters');
    }
  }
}

/// A stand-in for the server's SHA-256 graph hash (stable for equal content).
String _hash(Map<String, Object?> dsl) {
  final w = dsl['workflow'];
  final text = jsonEncode(w is Map<String, Object?> ? {'graph': w['graph'], 'features': w['features']} : dsl);
  // 32-bit FNV-1a in two 16-bit halves: exact on the web too (64-bit literals do not compile to JavaScript).
  var h = 0x811c9dc5;
  for (final b in utf8.encode(text)) {
    h ^= b;
    h = ((h & 0xffff) * 0x0193 + ((((h >> 16) * 0x0193 + (h & 0xffff) * 0x0100) & 0xffff) << 16)) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(16, '0');
}

class _Site {
  _Site({required this.code, required this.json, required this.updatedBy});

  String code;

  /// The settings, by Dify's member names (without `code`, `access_token`, `app_base_url`, `app_id`).
  Map<String, Object?> json;
  String updatedBy;
}

class _Key {
  _Key({required this.id, required this.token, required this.createdAt});

  final String id;
  final String token;
  final DateTime createdAt;

  AppApiKey toKey() => AppApiKey.fromJson({
    'id': id,
    'type': 'app',
    'token': token,
    'last_used_at': null,
    'created_at': FakeAppsApi._seconds(createdAt),
  });
}

class _Annotation {
  _Annotation({
    required this.id,
    required this.question,
    required this.answer,
    required this.accountId,
    required this.createdAt,
  });

  final String id;
  String question;
  String answer;
  final String accountId;
  final DateTime createdAt;

  Annotation toAnnotation() => Annotation.fromJson({
    'id': id,
    'question': question,
    'answer': answer,
    'hit_count': 0,
    'created_at': FakeAppsApi._seconds(createdAt),
  });
}

class _Version {
  _Version({
    required this.id,
    required this.number,
    required this.dsl,
    required this.markedName,
    required this.markedComment,
    required this.createdBy,
    required this.createdAt,
    required this.updatedBy,
    required this.updatedAt,
  });

  final String id;
  final int number;

  /// The export at publish time, secrets included (the fake keeps them as the server keeps its secret rows).
  final Map<String, Object?> dsl;
  String markedName;
  String markedComment;
  final String createdBy;
  final DateTime createdAt;
  String updatedBy;
  DateTime updatedAt;
}
