import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_detail/app_detail_page.dart';
import 'app_detail/detail_page_slot.dart';
import 'app_detail/detail_pages.dart';
import 'account/account_page.dart';
import 'app_root.dart';
import 'auth/account_dropdown.dart';
import 'auth/account_time.dart';
import 'auth/auth_api.dart';
import 'auth/auth_controller.dart';
import 'cards/card_kit.dart' show cardFontFamily;

import 'demo/demo_backend.dart';
import 'design/dify_icon.dart';
import 'design/dify_theme.dart';
import 'design/dify_theme_mode.dart';
import 'design/dify_tokens.g.dart';
import 'design/widgets/toast.dart';
import 'design/widgets/widgets.dart' show DifyPressable, difyTextStyle;
import 'editor/editor_controller.dart';
import 'editor/editor_page.dart';
import 'i18n/app_locale.dart';
import 'i18n/dify_i18n.dart';
import 'launch_options.dart';
import 'session_factory.dart';
import 'settings.dart';
import 'settings/integrations_page.dart';
import 'settings/workspace_card.dart';
import 'settings/workspace_members.dart';
import 'studio/studio_page.dart';
import 'workflow/workspace_models.dart';
import 'workflow_editor/node_panel/bodies/entry/trigger_schedule/schedule_host.dart';

/// Start screen (signed in), in Dify's main navigation frame (the logo at the top, the account menu at the bottom of
/// the sidebar): the Studio (the workspace's apps, protocol 1.10) when the server has apps, else the developer form
/// (a document id to open or create, the demo). The server is the one signed in to.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.settings,
    this.backendFor,
    this.launch,
    this.modelsApiFor,
    this.appsApiFor,
    this.studioPollInterval = const Duration(seconds: 10),
    this.appDetailServicesFor,
  });

  final AppSettings settings;

  /// The APIs of an opened app's pages (Access Point, Logs, Overview, ...) by type; by default the server's over HTTP
  /// ([httpAppDetailServices]; none with a test [backendFor]).
  final Map<Type, Object> Function(AuthController auth)? appDetailServicesFor;

  /// Command line options; with `--doc` / `--demo` the editor opens right away.
  final LaunchOptions? launch;

  /// Test hook: supplies the backend instead of an HTTP one.
  final Backend Function(Uri url)? backendFor;

  /// The model providers API of a session (protocol 1.9); by default the server's over HTTP (none for the demo, nor
  /// with a test [backendFor]).
  final ModelProvidersApi? Function(AuthController auth)? modelsApiFor;

  /// The apps API of a session (protocol 1.10, the Studio); by default the server's over HTTP (none for the demo, nor
  /// with a test [backendFor]: those get the developer form).
  final AppsApi? Function(AuthController auth)? appsApiFor;

  /// The Studio's refetch interval (Dify's 10 s with collaboration on); null: none.
  final Duration? studioPollInterval;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final _doc = TextEditingController(text: widget.settings.lastDoc);
  late bool _journaled = widget.settings.journaled;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final l = widget.launch;
    if (l != null && l.autoOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => l.demo ? _demo() : _open(create: true));
    } else if (l?.app case final app?) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openLaunchedApp(app, l!.page));
    }
  }

  /// `--app <id> [--page <page>]` (`?app=…&page=…`): opens the app's detail page at Dify's `/app/{id}/{page}` (the
  /// visual tests open Dify and us on the same page); without [page] where the Studio card would open it.
  Future<void> _openLaunchedApp(String id, String? page) async {
    final apps = _apps;
    if (apps == null) return;
    try {
      final app = await apps.get(id);
      if (mounted) await _openApp(app, path: '/app/$id/${page ?? 'workflow'}');
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _doc.dispose();
    _models?.dispose();
    _members?.dispose();
    super.dispose();
  }

  AuthController? get _auth => AuthScope.read(context);

  /// The workspace's model providers and models for the signed-in session (the editors' model selector, the
  /// integrations settings).
  WorkspaceModels? _models;
  AuthController? _modelsAuth;

  /// The workspace's members (the main navigation's workspace card, the Studio's Creators filter).
  WorkspaceMembers? _members;

  /// The session's apps (the Studio); null: the developer form.
  AppsApi? _apps;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = AuthScope.of(context);
    if (_models == null || _modelsAuth != auth) {
      _models?.dispose();
      _members?.dispose();
      _modelsAuth = auth;
      _models = WorkspaceModels((widget.modelsApiFor ?? _defaultModelsApi)(auth));
      _members = WorkspaceMembers(auth);
      _apps = (widget.appsApiFor ?? _defaultAppsApi)(auth);
    }
  }

  AppsApi? _defaultAppsApi(AuthController auth) {
    if (widget.backendFor != null) return null;
    final uri = Uri.tryParse(auth.server);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return null;
    return HttpAppsApi(uri, auth: auth.session);
  }

  ModelProvidersApi? _defaultModelsApi(AuthController auth) {
    if (widget.backendFor != null) return null;
    final uri = Uri.tryParse(auth.server);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return null;
    return HttpModelProvidersApi(uri, auth: auth.session);
  }

  Backend _backend() {
    final auth = _auth;
    final uri = Uri.parse(auth?.server ?? widget.settings.serverUrl);
    return widget.backendFor?.call(uri) ?? HttpBackend(uri, auth: auth);
  }

  Future<void> _remember() async {
    widget.settings
      ..journaled = _journaled
      ..lastDoc = _doc.text.trim();
    await widget.settings.save();
  }

  Future<void> _open({required bool create}) async {
    final id = _doc.text.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) {
      setState(() => _error = 'Document ids use letters, digits, "-" and "_" (1-64 characters).');
      return;
    }
    await _launch(_backend(), id, create: create);
  }

  Future<void> _newDocument() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await _backend().createDocument();
      _doc.text = id;
      await _launch(_backend(), id, create: false);
    } on Object catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Paste a Dify workflow file (YAML); the server converts it into a new document, which is then opened.
  Future<void> _importDifyDsl() async {
    final backend = _backend();
    final yaml = await showDialog<String>(context: context, builder: (_) => const _ImportDslDialog());
    if (yaml == null || yaml.trim().isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await backend.importDifyDsl(yaml);
      _doc.text = id;
      await _launch(backend, id, create: false);
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _demo() async {
    final demo = DemoBackend();
    // The in-memory demo has no server rights: the account's name, full access.
    await _launch(demo, 'demo', create: true, extra: demo.actions, demo: true);
    await demo.dispose();
  }

  Future<void> _launch(
    Backend backend,
    String id, {
    required bool create,
    List<Widget> Function(BuildContext, EditorController, VoidCallback)? extra,
    bool demo = false,
  }) async {
    final apps = demo ? null : _apps;
    setState(() => _error = null);
    await _remember();
    if (!mounted) return;
    final signedIn = _auth?.account;
    final account = demo && signedIn != null ? signedIn.copyWith(role: AccountRole.owner) : signedIn;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        // The schedule trigger reads the account's time zone (Dify's `userProfile.timezone`).
        builder: (_) => Builder(
          builder: (context) => ScheduleHost(
            profileTimezone: accountTimezone(context),
            child: EditorPage(
              backend: backend,
              docId: id,
              account: account,
              // Re-read after the server refuses edits (403: the role was changed); the demo has no server rights.
              refreshAccount: demo ? null : _auth?.session.account,
              displayName: account == null ? null : normalizeDisplayName(account.name),
              journaled: _journaled,
              create: create,
              extraActions: extra,
              // The launch's `node_id` belongs to the launch's document.
              locateNodeId: id == widget.launch?.doc ? widget.launch?.nodeId : null,
              models: demo ? null : _models,
              openModelProviderSettings: demo || _models == null
                  ? null
                  : (context) => showModelProviderSettings(context, models: _models!, role: account?.role),
              // Protocol 1.10: a deleted app's document answers 404 `app_deleted`; the editor goes back to the Studio.
              isAppDeleted: apps == null ? null : () => _appDeleted(apps, id),
            ),
          ),
        ),
      ),
    );
  }

  static Future<bool> _appDeleted(AppsApi apps, String id) async {
    try {
      await apps.get(id);
      return false;
    } on TransportException catch (e) {
      return e.appDeleted || e.statusCode == 404;
    }
  }

  /// Opens a Studio app at [path] (Dify's `getRedirectionPath`: the editor, the Overview or the Access Point by role)
  /// in the app detail page.
  Future<void> _openApp(AppInfo app, {required String path}) async {
    await _remember();
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _appDetail(app, path)));
  }

  Map<Type, Object> _appDetailServices(AuthController auth) {
    if (widget.appDetailServicesFor case final f?) return f(auth);
    if (widget.backendFor != null) return const {};
    final uri = Uri.tryParse(auth.server);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return const {};
    return httpAppDetailServices(uri, auth.session, features: auth.systemFeatures);
  }

  Widget _appDetail(AppInfo app, String path) {
    final apps = _apps!, auth = AuthScope.read(context)!, account = auth.account;
    final backend = _backend();
    return AppDetailPage(
      key: ValueKey('app-detail-${app.id}'),
      appId: app.id,
      apps: apps,
      initialApp: app,
      initialPage: AppDetailPageId.fromPath(path),
      account: account,
      models: _models,
      services: _appDetailServices(auth),
      canCreateApp: AppPermissionKeys.canCreate(account?.role),
      environmentVariables: _environmentVariables,
      openApp: (copy, path) => unawaited(
        Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => _appDetail(copy, path))),
      ),
      editor: (context, host) => ValueListenableBuilder(
        valueListenable: host.app,
        builder: (context, info, _) => ScheduleHost(
          profileTimezone: accountTimezone(context),
          child: EditorPage(
            backend: backend,
            docId: app.id,
            account: account,
            refreshAccount: auth.session.account,
            displayName: account == null ? null : normalizeDisplayName(account.name),
            journaled: _journaled,
            create: false,
            appName: info.name,
            onImportAvailable: host.registerImport,
            onAppChanged: () => unawaited(host.refreshApp()),
            models: _models,
            openModelProviderSettings: _models == null
                ? null
                : (context) => showModelProviderSettings(context, models: _models!, role: account?.role),
            isAppDeleted: () => _appDeleted(apps, app.id),
          ),
        ),
      ),
    );
  }

  Future<List<Map<String, Object?>>> _environmentVariables(String id) async =>
      (await _backend().docMeta(id)).environmentVariables;

  @override
  Widget build(BuildContext context) {
    final account = AuthScope.of(context).account;
    final apps = _apps;
    return Scaffold(
      backgroundColor: DifyColors.backgroundBody,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (account != null) MainNavFrame(account: account, models: _models, members: _members, apps: apps),
          Expanded(
            child: apps == null || account == null
                ? _form(context)
                : StudioPage(
                    key: const ValueKey('studio-page'),
                    api: apps,
                    members: _members,
                    role: account.role,
                    currentUserId: account.id,
                    pollInterval: widget.studioPollInterval,
                    openApp: _openApp,
                    environmentVariables: _environmentVariables,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _form(BuildContext context) {
    final server = AuthScope.of(context).server;
    return Material(
      color: DifyColors.backgroundBody,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Text('dify-sf', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              const Text('Collaborative workflow editor', style: TextStyle(color: Colors.black54)),
              const SizedBox(height: 4),
              Text(
                server,
                key: const Key('server-label'),
                style: const TextStyle(color: Colors.black45),
              ),
              const SizedBox(height: 24),
              TextField(
                key: const Key('doc-field'),
                controller: _doc,
                decoration: const InputDecoration(labelText: 'Document id', border: OutlineInputBorder()),
                onSubmitted: (_) => _open(create: true),
              ),
              SwitchListTile(
                key: const Key('journal-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Keep a local journal'),
                subtitle: Text(
                  _journaled
                      ? 'Unsent edits survive a crash or reload and are resent.'
                      : 'Volatile: unsent edits are lost if the app closes, and you will be told.',
                ),
                value: _journaled,
                onChanged: (v) => setState(() => _journaled = v),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      key: const Key('open-button'),
                      onPressed: _busy ? null : () => _open(create: true),
                      child: const Text('Open / create'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    key: const Key('new-button'),
                    onPressed: _busy ? null : _newDocument,
                    child: const Text('New document'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                key: const Key('import-dsl-button'),
                onPressed: _busy ? null : _importDifyDsl,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('Import a Dify workflow file…'),
              ),
              TextButton(
                key: const Key('demo-button'),
                onPressed: _busy ? null : _demo,
                child: const Text('Try the demo (in-memory server, simulated collaborator Bo)'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dify's main navigation (main-nav/index.tsx) as far as dify-sf has it: the `w-62` sidebar on
/// `bg-background-body` with the Dify logo at the top (`pt-3 pr-2 pb-2 pl-4`), the workspace card under it (`p-2`;
/// its menu opens the workspace settings), the Integrations link (the model providers) and the account section at the
/// bottom (`py-3 pr-1 pl-3`). Dify's search, its other navigation links, web apps and help menu are not part of dify-sf.
class MainNavFrame extends StatefulWidget {
  const MainNavFrame({super.key, required this.account, this.models, this.members, this.apps});
  final Account account;

  /// The session's apps: the Account page lists them ("Account's data").
  final AppsApi? apps;

  /// The workspace's members, when the page shares them (the Studio); else the frame keeps its own.
  final WorkspaceMembers? members;

  /// The workspace's models: the Integrations link opens their settings (no link without them).
  final WorkspaceModels? models;

  @override
  State<MainNavFrame> createState() => _MainNavFrameState();
}

class _MainNavFrameState extends State<MainNavFrame> {
  WorkspaceMembers? _own;

  WorkspaceMembers? get _members => widget.members ?? _own;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = AuthScope.of(context);
    if (widget.members == null && _own?.auth != auth) {
      _own?.dispose();
      _own = WorkspaceMembers(auth);
    }
  }

  @override
  void didUpdateWidget(MainNavFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.members == null && _own == null) _own = WorkspaceMembers(AuthScope.read(context)!);
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    width: 248,
    color: DifyColors.backgroundBody,
    padding: const EdgeInsets.all(4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: SizedBox(
            height: 32,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: DifyLogo(alt: ''),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: WorkspaceCard(members: _members!),
        ),
        if (widget.models case final models?)
          Padding(
            padding: const EdgeInsets.all(8),
            child: MainNavLink(
              key: const ValueKey('main-nav-integrations'),
              label: DifyI18n.tr('common', 'mainNav.integrations'),
              icon: 'vender/main-nav/integrations-v2',
              activeIcon: 'vender/main-nav/integrations-v2-active',
              onTap: () => showModelProviderSettings(context, models: models, role: _members!.myRole),
            ),
          ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          child: Row(
            children: [
              Flexible(
                child: AccountSection(
                  account: widget.account,
                  members: _members,
                  onOpenAccount: () => unawaited(openAccountPage(context, apps: widget.apps)),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Used by tests to build the same widget tree as `main`. [auth] is a ready session (tests sign in through fakes);
/// without it the app connects to the settings' server ([authApiFor], [tokenStore]) and starts at its sign-in state.
Widget buildApp(
  AppSettings settings, {
  Backend Function(Uri)? backendFor,
  LaunchOptions? launch,
  AuthController? auth,
  AuthApi Function(Uri server)? authApiFor,
  TokenStore? tokenStore,
  AppLocale? locale,
  AppTheme? theme,
  AppsApi? Function(AuthController auth)? appsApiFor,
  Duration? studioPollInterval = const Duration(seconds: 10),
  Map<Type, Object> Function(AuthController auth)? appDetailServicesFor,
}) {
  final appLocale = locale ?? AppLocale(currentDifyLanguage());
  // Tests without a theme get one that stays in the current theme and remembers nothing.
  final appTheme = theme ?? AppTheme(DifyColors.isDark ? DifyThemeMode.dark : DifyThemeMode.light, remember: false);
  // The in-memory demo needs no server and no account.
  final session =
      auth ??
      (launch?.demo ?? false
          ? (AuthController.on(server: 'demo', api: const OfflineAuthApi(), store: MemoryTokenStore())
              ..useLocalAccount(const Account(id: 'demo-user', email: '', name: 'You', role: AccountRole.owner)))
          : null);
  final navigatorKey = GlobalKey<NavigatorState>();
  // The session for every page, also those pushed over the home page (AppRoot publishes its controller here).
  final authRelay = ValueNotifier<AuthController?>(session);
  return ListenableBuilder(
    listenable: appTheme,
    builder: (context, _) => MaterialApp(
      title: 'dify-sf',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      // Dify's font stack: the system UI font, which is Noto Sans on Linux (bundled, also for the web build).
      theme: difyTheme(
        fontFamily: cardFontFamily ??= kIsWeb || defaultTargetPlatform == TargetPlatform.linux ? 'Noto Sans' : null,
        brightness: appTheme.isDark ? Brightness.dark : Brightness.light,
      ),
      // next-themes' disableTransitionOnChange: the new theme shows at once.
      themeAnimationDuration: Duration.zero,
      home: AppRoot(
        settings: settings,
        launch: launch,
        navigatorKey: navigatorKey,
        auth: session,
        authApiFor: authApiFor,
        tokenStore: tokenStore,
        authRelay: authRelay,
        home: (_) => HomePage(
          settings: settings,
          backendFor: backendFor,
          launch: launch,
          appsApiFor: appsApiFor,
          studioPollInterval: studioPollInterval,
          appDetailServicesFor: appDetailServicesFor,
        ),
      ),
      // Dify's root layout: one ToastHost (timeout 5 s, at most 3) over every page and dialog. The UI language is above
      // the navigator, so every page follows a change.
      builder: (context, child) => AppThemeScope(
        theme: appTheme,
        child: AppLocaleScope(
          locale: appLocale,
          child: ValueListenableBuilder<AuthController?>(
            valueListenable: authRelay,
            builder: (context, auth, page) => auth == null ? page! : AuthScope(controller: auth, child: page!),
            child: Stack(
              fit: StackFit.expand,
              children: [
                child!,
                DefaultTextStyle(
                  style: TextStyle(fontFamily: cardFontFamily, fontSize: 14, height: 20 / 14, letterSpacing: 0),
                  child: const DifyToastHost(timeout: Duration(seconds: 5), limit: 3),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _ImportDslDialog extends StatefulWidget {
  const _ImportDslDialog();

  @override
  State<_ImportDslDialog> createState() => _ImportDslDialogState();
}

class _ImportDslDialogState extends State<_ImportDslDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import a Dify workflow file'),
      content: SizedBox(
        width: 560,
        child: TextField(
          key: const Key('import-dsl-text'),
          controller: _text,
          maxLines: 16,
          minLines: 8,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
            hintText: 'Paste the YAML exported from Dify (Studio → app → Export DSL)',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('import-dsl-confirm'),
          onPressed: () => Navigator.pop(context, _text.text),
          child: const Text('Import'),
        ),
      ],
    );
  }
}

/// main-nav/components/nav-link.tsx: `h-8 rounded-[10px] px-2 py-1.5 gap-2`, the 20 px icon and the label
/// (`system-md-medium text-components-main-nav-nav-button-text`, hover `bg-components-main-nav-nav-button-bg-hover`).
/// dify-sf's links open settings rather than pages, so none is ever the current page.
class MainNavLink extends StatelessWidget {
  const MainNavLink({
    super.key,
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.onTap,
  });

  final String label, icon, activeIcon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onTap,
    builder: (context, hovered, focused) => Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: hovered ? DifyColors.componentsMainNavNavButtonBgHover : DifyColors.componentsMainNavNavButtonBg,
        borderRadius: BorderRadius.circular(10),
        border: focused ? Border.all(color: DifyColors.stateAccentSolid, width: 2) : null,
      ),
      child: Row(
        spacing: 8,
        children: [
          DifyIcon(icon, size: 20, color: DifyColors.componentsMainNavNavButtonText),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: difyTextStyle(DifyType.systemMdMedium, DifyColors.componentsMainNavNavButtonText),
            ),
          ),
        ],
      ),
    ),
  );
}
