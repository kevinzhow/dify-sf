import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_root.dart';
import 'auth/account_dropdown.dart';
import 'auth/auth_api.dart';
import 'auth/auth_controller.dart';
import 'cards/card_kit.dart' show cardFontFamily;

import 'demo/demo_backend.dart';
import 'design/dify_icon.dart';
import 'design/dify_theme.dart';
import 'design/dify_tokens.g.dart';
import 'design/widgets/toast.dart';
import 'editor/editor_controller.dart';
import 'editor/editor_page.dart';
import 'i18n/app_locale.dart';
import 'i18n/dify_i18n.dart';
import 'launch_options.dart';
import 'session_factory.dart';
import 'settings.dart';
import 'settings/workspace_card.dart';
import 'settings/workspace_members.dart';

/// Start screen (signed in): mode and the document to open or create, in Dify's main navigation frame (the logo at
/// the top, the account menu at the bottom of the sidebar). The server is the one signed in to.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.settings, this.backendFor, this.launch});

  final AppSettings settings;

  /// Command line options; with `--doc` / `--demo` the editor opens right away.
  final LaunchOptions? launch;

  /// Test hook: supplies the backend instead of an HTTP one.
  final Backend Function(Uri url)? backendFor;

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
    }
  }

  @override
  void dispose() {
    _doc.dispose();
    super.dispose();
  }

  AuthController? get _auth => AuthScope.read(context);

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
    setState(() => _error = null);
    await _remember();
    if (!mounted) return;
    final signedIn = _auth?.account;
    final account = demo && signedIn != null ? signedIn.copyWith(role: AccountRole.owner) : signedIn;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EditorPage(
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
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = AuthScope.of(context).account;
    return Scaffold(
      backgroundColor: DifyColors.backgroundBody,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (account != null) MainNavFrame(account: account),
          Expanded(child: _form(context)),
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
/// its menu opens the workspace settings) and the account section at the bottom (`py-3 pr-1 pl-3`). Dify's search,
/// navigation links, web apps and help menu are not part of dify-sf.
class MainNavFrame extends StatefulWidget {
  const MainNavFrame({super.key, required this.account});
  final Account account;

  @override
  State<MainNavFrame> createState() => _MainNavFrameState();
}

class _MainNavFrameState extends State<MainNavFrame> {
  WorkspaceMembers? _members;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = AuthScope.of(context);
    if (_members?.auth != auth) {
      _members?.dispose();
      _members = WorkspaceMembers(auth);
    }
  }

  @override
  void dispose() {
    _members?.dispose();
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
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
          child: Row(
            children: [Flexible(child: AccountSection(account: widget.account))],
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
}) {
  final appLocale = locale ?? AppLocale(currentDifyLanguage());
  // The in-memory demo needs no server and no account.
  final session =
      auth ??
      (launch?.demo ?? false
          ? (AuthController.on(server: 'demo', api: const OfflineAuthApi(), store: MemoryTokenStore())
              ..useLocalAccount(const Account(id: 'demo-user', email: '', name: 'You', role: AccountRole.owner)))
          : null);
  final navigatorKey = GlobalKey<NavigatorState>();
  return MaterialApp(
    title: 'dify-sf',
    debugShowCheckedModeBanner: false,
    navigatorKey: navigatorKey,
    // Dify's font stack: the system UI font, which is Noto Sans on Linux (bundled, also for the web build).
    theme: difyTheme(
      fontFamily: cardFontFamily ??= kIsWeb || defaultTargetPlatform == TargetPlatform.linux ? 'Noto Sans' : null,
    ),
    home: AppRoot(
      settings: settings,
      launch: launch,
      navigatorKey: navigatorKey,
      auth: session,
      authApiFor: authApiFor,
      tokenStore: tokenStore,
      home: (_) => HomePage(settings: settings, backendFor: backendFor, launch: launch),
    ),
    // Dify's root layout: one ToastHost (timeout 5 s, at most 3) over every page and dialog. The UI language is above
    // the navigator, so every page follows a change.
    builder: (context, child) => AppLocaleScope(
      locale: appLocale,
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
