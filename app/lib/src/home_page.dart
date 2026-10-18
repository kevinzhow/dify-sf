import 'package:collab_client/collab_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'cards/card_kit.dart' show cardFontFamily;

import 'demo/demo_backend.dart';
import 'design/dify_theme.dart';
import 'design/widgets/toast.dart';
import 'editor/editor_controller.dart';
import 'editor/editor_page.dart';
import 'launch_options.dart';
import 'session_factory.dart';
import 'settings.dart';

/// Start screen: server, name, mode, and the document to open or create.
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
  late final _url = TextEditingController(text: widget.settings.serverUrl);
  late final _doc = TextEditingController(text: widget.settings.lastDoc);
  late final _name = TextEditingController(text: widget.settings.userName);
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
    _url.dispose();
    _doc.dispose();
    _name.dispose();
    super.dispose();
  }

  Backend _backend() {
    final uri = Uri.parse(_url.text.trim());
    return widget.backendFor?.call(uri) ?? HttpBackend(uri);
  }

  Future<void> _remember() async {
    widget.settings
      ..serverUrl = _url.text.trim()
      ..journaled = _journaled
      ..lastDoc = _doc.text.trim()
      ..userName = _name.text.trim();
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
    await _launch(demo, 'demo', create: true, extra: demo.actions);
    await demo.dispose();
  }

  Future<void> _launch(
    Backend backend,
    String id, {
    required bool create,
    List<Widget> Function(BuildContext, EditorController, VoidCallback)? extra,
  }) async {
    setState(() => _error = null);
    await _remember();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EditorPage(
          backend: backend,
          docId: id,
          displayName: normalizeDisplayName(_name.text),
          journaled: _journaled,
          create: create,
          extraActions: extra,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Text('dify-sf', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              const Text('Collaborative workflow editor', style: TextStyle(color: Colors.black54)),
              const SizedBox(height: 24),
              TextField(
                key: const Key('server-field'),
                controller: _url,
                decoration: const InputDecoration(labelText: 'Server', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('doc-field'),
                controller: _doc,
                decoration: const InputDecoration(labelText: 'Document id', border: OutlineInputBorder()),
                onSubmitted: (_) => _open(create: true),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('name-field'),
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Your name (optional)',
                  helperText: 'Shown to others when your change and theirs collide.',
                  border: OutlineInputBorder(),
                ),
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

/// Used by tests to build the same widget tree as `main`.
Widget buildApp(AppSettings settings, {Backend Function(Uri)? backendFor, LaunchOptions? launch}) => MaterialApp(
  title: 'dify-sf',
  debugShowCheckedModeBanner: false,
  // Dify's font stack: the system UI font, which is Noto Sans on Linux (bundled, also for the web build).
  theme: difyTheme(
    fontFamily: cardFontFamily ??= kIsWeb || defaultTargetPlatform == TargetPlatform.linux ? 'Noto Sans' : null,
  ),
  home: HomePage(settings: settings, backendFor: backendFor, launch: launch),
  // Dify's root layout: one ToastHost (timeout 5 s, at most 3) over every page and dialog.
  builder: (context, child) => Stack(
    fit: StackFit.expand,
    children: [
      child!,
      DefaultTextStyle(
        style: TextStyle(fontFamily: cardFontFamily, fontSize: 14, height: 20 / 14, letterSpacing: 0),
        child: const DifyToastHost(timeout: Duration(seconds: 5), limit: 3),
      ),
    ],
  ),
);

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
