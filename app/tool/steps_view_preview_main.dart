// dify-sf Steps view preview: the workflow editor's Steps view (lib/src/workflow_editor/steps) on a bundled sample
// workflow in an in-memory session, without a server, for screenshots on a device. A dev tool: the app never
// imports it.
//
//   flutter run -t tool/steps_view_preview_main.dart            (an Android device or emulator)
//   flutter run -t tool/steps_view_preview_main.dart -d linux   (desktop: the same page in a window)
//
// The app bar's buttons switch the sample (mockup 2's "Self-host check", or one with every kind of branch), show a
// simulated run (mockup 7's markers), show checklist problems, and switch the theme. Edits (the "+", the long-press
// sheet) go to the in-memory document; there is no node panel, so a tap only selects the step.
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/run_view.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/dify_theme_mode.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/platform_input.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/session_factory.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart' show nodeFromDify;
import 'package:dify_sf_app/src/workflow_editor/steps/workflow_steps_view.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Starts like lib/main.dart: platform input, the UI strings, the system theme, Dify's font stack.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDifyPlatformInput();
  const lang = String.fromEnvironment('STEPS_LANG', defaultValue: 'en-US');
  await Future.wait([if (kIsWeb) DifyFonts.loadFor(lang), DifyI18n.load(lang)]);
  DifyColors.useDark(WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark);
  cardFontFamily ??= kIsWeb || defaultTargetPlatform == TargetPlatform.linux ? 'Noto Sans' : null;
  runApp(const StepsPreviewApp(sample: String.fromEnvironment('STEPS_SAMPLE', defaultValue: 'mockup')));
}

typedef _Json = Map<String, Object?>;

_Json _node(String id, String type, String title, {int y = 0, String? parent, _Json data = const {}}) => {
  'id': id,
  'type': type == 'iteration-start' ? 'custom-iteration-start' : 'custom',
  'position': {'x': 0, 'y': y},
  'parentId': ?parent,
  'data': {'type': type, 'title': title, 'desc': '', ...data},
};

_Json _edge(String source, String target, [String handle = 'source']) => {
  'id': '$source-$handle-$target',
  'source': source,
  'sourceHandle': handle,
  'target': target,
  'targetHandle': 'target',
};

_Json _model(String name) => {'provider': 'langgenius/openai/openai', 'name': name, 'mode': 'chat'};

/// Mockup 2's workflow: Start, a code step, an IF/ELSE whose lanes meet at End.
final mockupSample = (
  name: 'Self-host check',
  nodes: [
    _node(
      'start',
      'start',
      'Start',
      data: {
        'variables': [
          {'variable': 'text', 'label': 'text', 'type': 'text-input', 'required': true},
        ],
      },
    ),
    _node(
      'count',
      'code',
      'Count Android',
      y: 100,
      data: {
        'code_language': 'python3',
        'code': 'def main(text: str) -> dict:\n    return {"words": len(text.split()), "python": "android" in text}',
        'outputs': {
          'words': {'type': 'number'},
          'python': {'type': 'string'},
        },
      },
    ),
    _node(
      'check',
      'if-else',
      'Has words?',
      y: 200,
      data: {
        'cases': [
          {
            'case_id': 'true',
            'logical_operator': 'and',
            'conditions': [
              {
                'id': 'c1',
                'variable_selector': ['count', 'words'],
                'comparison_operator': '>',
                'value': '0',
              },
            ],
          },
        ],
      },
    ),
    _node('summarize', 'llm', 'Summarize', y: 300, data: {'model': _model('stand-in-chat')}),
    _node('empty', 'answer', 'Say empty', y: 400, data: {'answer': 'Nothing to count'}),
    _node(
      'end',
      'end',
      'End',
      y: 500,
      data: {
        'outputs': [
          {
            'variable': 'words',
            'value_selector': ['count', 'words'],
          },
          {
            'variable': 'python',
            'value_selector': ['count', 'python'],
          },
          {
            'variable': 'summary',
            'value_selector': ['summarize', 'text'],
          },
        ],
      },
    ),
  ],
  edges: [
    _edge('start', 'count'),
    _edge('count', 'check'),
    _edge('check', 'summarize', 'true'),
    _edge('check', 'empty', 'false'),
    _edge('summarize', 'end'),
    _edge('empty', 'end'),
  ],
);

/// Every kind of branch: classes, a fail branch, an iteration, parallel steps, a link and an unconnected step.
final branchesSample = (
  name: 'Support triage',
  nodes: [
    _node(
      'start',
      'start',
      'Start',
      data: {
        'variables': [
          {'variable': 'query', 'label': 'query', 'type': 'paragraph', 'required': true},
        ],
      },
    ),
    _node(
      'route',
      'question-classifier',
      'Route request',
      y: 100,
      data: {
        'model': _model('gpt-4o-mini'),
        'classes': [
          {'id': 'billing', 'name': 'Billing question'},
          {'id': 'tech', 'name': 'Technical problem'},
          {'id': 'other', 'name': 'Anything else'},
        ],
      },
    ),
    _node(
      'invoice',
      'http-request',
      'Fetch invoice',
      y: 200,
      data: {
        'method': 'get',
        'url': 'https://billing.example.com/invoices',
        'error_strategy': 'fail-branch',
      },
    ),
    _node('notify', 'answer', 'Billing is down', y: 250, data: {'answer': 'Billing is unavailable right now.'}),
    _node(
      'each',
      'iteration',
      'Each document',
      y: 300,
      data: {
        'iterator_selector': ['start', 'query'],
      },
    ),
    _node('each-start', 'iteration-start', '', parent: 'each'),
    _node(
      'search',
      'knowledge-retrieval',
      'Search help center',
      y: 50,
      parent: 'each',
      data: {
        'query_variable_selector': ['start', 'query'],
      },
    ),
    _node('extract', 'llm', 'Pick answer', y: 100, parent: 'each', data: {'model': _model('gpt-4o')}),
    _node(
      'merge',
      'variable-aggregator',
      'Merge answers',
      y: 400,
      data: {
        'variables': [
          ['invoice', 'body'],
          ['each', 'output'],
        ],
      },
    ),
    _node('draft', 'llm', 'Draft reply', y: 500, data: {'model': _model('gpt-4o')}),
    _node('tone', 'llm', 'Check tone', y: 600, data: {'model': _model('gpt-4o-mini')}),
    _node(
      'end',
      'end',
      'End',
      y: 700,
      data: {
        'outputs': [
          {
            'variable': 'reply',
            'value_selector': ['draft', 'text'],
          },
        ],
      },
    ),
    _node('scratch', 'code', 'Scratch step', y: 900, data: {'code_language': 'javascript'}),
  ],
  edges: [
    _edge('start', 'route'),
    _edge('route', 'invoice', 'billing'),
    _edge('route', 'each', 'tech'),
    _edge('route', 'merge', 'other'),
    _edge('invoice', 'merge'),
    _edge('invoice', 'notify', 'fail-branch'),
    _edge('each', 'merge'),
    _edge('each-start', 'search'),
    _edge('search', 'extract'),
    _edge('merge', 'draft'),
    _edge('merge', 'tone'),
    _edge('draft', 'end'),
    _edge('tone', 'end'),
  ],
);

final previewSamples = {'mockup': mockupSample, 'branches': branchesSample};

/// The sample [name] as the collaborative document's nodes and edges (Dify's JSON through the importer's mapping).
Document previewDocument(String name) {
  final sample = previewSamples[name] ?? mockupSample;
  var doc = Document();
  final nodes = <Node>[];
  for (final n in sample.nodes) {
    nodes.add(nodeFromDify(n, doc, id: n['id']! as String));
    doc = Document(nodes: nodes);
  }
  return Document(
    nodes: nodes,
    edges: [
      for (final e in sample.edges)
        Edge(
          id: e['id']! as String,
          source: e['source']! as String,
          sourceHandle: e['sourceHandle']! as String,
          target: e['target']! as String,
          targetHandle: e['targetHandle']! as String,
        ),
    ],
  );
}

/// The preview app (public for its smoke test, test/workflow_editor/steps/steps_view_test.dart).
class StepsPreviewApp extends StatefulWidget {
  const StepsPreviewApp({super.key, this.sample = 'mockup'});
  final String sample;

  @override
  State<StepsPreviewApp> createState() => _StepsPreviewAppState();
}

class _StepsPreviewAppState extends State<StepsPreviewApp> {
  late String _sample = widget.sample;
  DemoBackend? _demo;
  OpenedSession? _opened;
  EditorController? _controller;
  final _canvas = CanvasController();
  final _store = WorkflowStore();
  final _toasts = DifyToastManager();
  bool _run = false, _issues = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final old = (_controller, _opened, _demo);
    final demo = DemoBackend(server: FakeServer(initial: previewDocument(_sample)), withBo: false);
    final opened = await demo.openSession('demo', clientId: 'preview', journaled: false);
    await opened.session.start();
    final controller = EditorController(session: opened.session, docId: 'demo', journaled: false);
    while (!controller.ready) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted) return;
    setState(() {
      _demo = demo;
      _opened = opened;
      _controller = controller;
    });
    _showRun();
    _showIssues();
    old.$1?.dispose();
    await old.$2?.close();
    await old.$3?.dispose();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _opened?.close();
    _demo?.dispose();
    _canvas.dispose();
    _store.dispose();
    super.dispose();
  }

  /// Mockup 7's run: the first steps succeeded, the next one runs, the rest wait.
  void _showRun() {
    final doc = _controller?.doc;
    if (!_run || doc == null) {
      _canvas.nodeRun.value = const {};
      return;
    }
    final ids = doc.nodes.values.toList()..sort((a, b) => a.y.compareTo(b.y));
    _canvas.nodeRun.value = {
      for (final (i, n) in ids.indexed)
        n.id: i < 3
            ? const NodeRunView(runningStatus: 'succeeded')
            : i == 3
            ? const NodeRunView(runningStatus: 'running')
            : const NodeRunView(waiting: true),
    };
  }

  void _showIssues() {
    final doc = _controller?.doc;
    final target = doc?.nodes.values.where((n) => n.type == 'llm').firstOrNull;
    _store.checklistItems.value = !_issues || target == null
        ? const []
        : [
            {
              'id': target.id,
              'type': target.type,
              'title': target.title,
              'errorMessages': ['Model is not configured'],
              'canNavigate': true,
            },
          ];
  }

  Future<void> _toggleTheme() async {
    await DifyTheme.apply(!DifyColors.isDark);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => DifyApplication(
    title: 'dify-sf Steps preview',
    edgeToEdge: true,
    theme: difyTheme(
      fontFamily: cardFontFamily,
      fontFamilyFallback: DifyFonts.fallbackFamilies,
      brightness: DifyColors.isDark ? Brightness.dark : Brightness.light,
    ),
    builder: (context, child) => Stack(
      fit: StackFit.expand,
      children: [
        child!,
        DifyToastHost(manager: _toasts),
      ],
    ),
    home: DifyPage(
      edgeToEdge: true,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DifyTopAppBar(
            title: (previewSamples[_sample] ?? mockupSample).name,
            subtitle: 'Steps preview · in-memory',
            automaticallyImplyLeading: false,
            actions: [
              DifyTouchIconButton(
                label: 'Next sample',
                icon: const RemixIcon('git-branch-line', size: 22),
                onPressed: () {
                  final names = previewSamples.keys.toList();
                  setState(() => _sample = names[(names.indexOf(_sample) + 1) % names.length]);
                  _open();
                },
              ),
              DifyTouchIconButton(
                label: 'Simulated run',
                icon: const RemixIcon('play-line', size: 22),
                onPressed: () => setState(() {
                  _run = !_run;
                  _showRun();
                }),
              ),
              DifyTouchIconButton(
                label: 'Checklist problems',
                icon: const RemixIcon('error-warning-line', size: 22),
                onPressed: () => setState(() {
                  _issues = !_issues;
                  _showIssues();
                }),
              ),
              DifyTouchIconButton(
                label: 'Theme',
                icon: RemixIcon(DifyColors.isDark ? 'sun-line' : 'moon-line', size: 22),
                onPressed: _toggleTheme,
              ),
            ],
          ),
          Expanded(
            child: switch (_controller) {
              null => const Center(child: DifySpinner(size: 24)),
              final controller => WorkflowStoreScope(
                store: _store,
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (context, child) => BlockSelectorScope(
                    data: BlockSelectorData(
                      nodes: [for (final n in controller.doc.nodes.values) (id: n.id, type: n.type)],
                    ),
                    child: child!,
                  ),
                  child: WorkflowStepsView(
                    key: ValueKey(controller),
                    controller: controller,
                    canvas: _canvas,
                  ),
                ),
              ),
            },
          ),
        ],
      ),
    ),
  );
}
