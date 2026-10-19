import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:collab_client/collab_client.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as image;

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_graph.dart';
import '../../canvas/canvas_selection.dart';
import '../../canvas/canvas_view_state.dart';
import '../../canvas/widget_renderer.dart';
import '../../cards/dify_cards.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../canvas_plus/iteration_add_block.dart';
import 'actions.dart';

class CanvasImageExport {
  const CanvasImageExport({
    required this.name,
    required this.mimeType,
    required this.bytes,
    required this.png,
    required this.size,
  });
  final String name, mimeType;
  final Uint8List bytes, png;
  final Size size;
}

typedef SaveCanvasImage = Future<void> Function(CanvasImageExport image);

/// The menu owner's export sequence, kept injectable for file saving and preview tests.
Future<void> performCanvasImageExport({
  required String appName,
  required bool readOnly,
  required bool wholeWorkflow,
  required Future<CanvasImageExport> Function() capture,
  required SaveCanvasImage save,
  required Future<void> Function(CanvasImageExport) preview,
  required void Function(Object) onError,
}) async {
  if (appName.isEmpty || readOnly) return;
  try {
    final image = await capture();
    await save(image);
    if (wholeWorkflow) await preview(image);
  } on Object catch (error) {
    onError(error);
  }
}

Future<void> saveCanvasImage(CanvasImageExport image) async {
  final file = XFile.fromData(image.bytes, name: image.name, mimeType: image.mimeType);
  if (kIsWeb) {
    await file.saveTo(image.name);
    return;
  }
  final location = await getSaveLocation(suggestedName: image.name);
  if (location != null) await file.saveTo(location.path);
}

/// Full workflow uses Dify's 50-unit border and 2x raster density. Current view keeps the viewport transform.
({Size size, Offset center, double scale, double ratio}) canvasExportGeometry(
  CanvasGraph graph,
  CanvasViewState view, {
  required bool wholeWorkflow,
  double pixelRatio = 1,
}) {
  final bounds = graph.bounds;
  final geometry = wholeWorkflow
      ? (size: Size(bounds.width + 100, bounds.height + 100), center: bounds.center, scale: 1.0, ratio: 2.0)
      : (size: view.viewport, center: view.center, scale: view.scale, ratio: pixelRatio);
  final width = (geometry.size.width * geometry.ratio).ceil(), height = (geometry.size.height * geometry.ratio).ceil();
  if (width <= 0 || height <= 0) throw const FormatException('The canvas has no visible area to export.');
  if (width > 16384 || height > 16384 || width * height > 32 * 1024 * 1024) {
    throw const FormatException('This image is too large. Export the current view at a lower zoom.');
  }
  return geometry;
}

/// PNG is the SDK's encoder, JPEG reuses package:image. SVG deliberately embeds this same raster (documented
/// deviation from Dify's DOM foreignObject SVG), rather than claiming editable vector output.
CanvasImageExport encodeCanvasImage(
  Uint8List png,
  Size size,
  String appName,
  ExportImageFormat format, {
  required bool wholeWorkflow,
}) {
  final name = appName.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_');
  final filename = '$name${wholeWorkflow ? '-whole-workflow' : ''}.${format.name}';
  switch (format) {
    case ExportImageFormat.png:
      return CanvasImageExport(name: filename, mimeType: 'image/png', bytes: png, png: png, size: size);
    case ExportImageFormat.jpeg:
      final decoded = image.decodePng(png);
      if (decoded == null) throw const FormatException('Could not encode the exported image.');
      // JPEG has no alpha: composite transparent current-view pixels over white before encoding.
      final opaque = image.Image(width: decoded.width, height: decoded.height)..clear(image.ColorRgb8(255, 255, 255));
      image.compositeImage(opaque, decoded);
      return CanvasImageExport(
        name: filename,
        mimeType: 'image/jpeg',
        bytes: image.encodeJpg(opaque, quality: 95),
        png: png,
        size: size,
      );
    case ExportImageFormat.svg:
      final svg =
          '<svg xmlns="http://www.w3.org/2000/svg" width="${size.width}" height="${size.height}" viewBox="0 0 ${size.width} ${size.height}"><image width="100%" height="100%" href="data:image/png;base64,${base64Encode(png)}"/></svg>';
      return CanvasImageExport(
        name: filename,
        mimeType: 'image/svg+xml',
        bytes: Uint8List.fromList(utf8.encode(svg)),
        png: png,
        size: size,
      );
  }
}

/// Exports full-quality card widgets even when the user's canvas is Scene or is zoomed out to its skeleton tier.
/// The detached render graph never attaches an editor/session listener, changes selection or moves the viewport.
Future<CanvasImageExport> captureCanvasImage(
  BuildContext context,
  Document doc,
  CanvasController canvas,
  String name,
  ExportImageFormat format, {
  required bool wholeWorkflow,
}) async {
  const cards = _ExportCards();
  final graph = CanvasGraph(layoutOf: cards.layoutOf);
  final change = graph.sync(doc);
  final selection = CanvasSelection();
  for (final node in graph.nodes) {
    final source = canvas.graph?[node.id];
    if (source == null) continue;
    node.run.value = source.run.value;
    node.cardRun.value = source.cardRun.value;
    node.selected.value = source.selected.value;
    if (source.selected.value) selection.nodes.add(node.slot);
    graph.relayout(node, doc);
  }
  final geometry = canvasExportGeometry(
    graph,
    canvas.view,
    wholeWorkflow: wholeWorkflow,
    pixelRatio: MediaQuery.devicePixelRatioOf(context),
  );
  final view = CanvasViewState(center: geometry.center, scale: geometry.scale)..viewport = geometry.size;
  graph.restingOrigin.value = view.toScreen(Offset.zero);
  selection.edge = canvas.selection.edge;
  final original = canvas.graph;
  if (original != null) {
    graph.edgeRun = Map.of(original.edgeRun);
    graph.dimming = original.dimming;
    final hovered = original.hoveredNode;
    graph.hoveredNode = hovered == null ? null : graph[original.slots[hovered]?.id ?? '']?.slot;
    graph.temporaryEdges = [
      for (final e in original.temporaryEdges)
        if (original.slots[e.source] case final source? when original.slots[e.target] != null)
          if (graph[source.id] != null && graph[original.slots[e.target]!.id] != null)
            CanvasEdge(
              e.id,
              graph[source.id]!.slot,
              graph[original.slots[e.target]!.id]!.slot,
              sourceHandle: e.sourceHandle,
              targetHandle: e.targetHandle,
            ),
    ];
  }
  final renderer = WidgetRenderer(graph: graph, view: view, selection: selection, cards: cards, overlaidControls: false)
    ..apply(change);
  try {
    final png = await _capture(
      context,
      geometry.size,
      geometry.ratio,
      ColoredBox(
        color: wholeWorkflow ? DifyImageExportColors.workflowBackground : Colors.transparent,
        child: DefaultTextStyle(
          style: difyTextStyle(DifyTw.trackingNormal, DifyTailwind.black).copyWith(fontFamily: cardFontFamily),
          child: renderer.build(context),
        ),
      ),
    );
    return encodeCanvasImage(png, geometry.size, name, format, wholeWorkflow: wholeWorkflow);
  } finally {
    renderer.dispose();
    view.dispose();
    selection.dispose();
    for (final n in graph.nodes) {
      n.node.dispose();
      n.run.dispose();
      n.cardRun.dispose();
      n.selected.dispose();
      n.hovered.dispose();
    }
    graph.restingOrigin.dispose();
  }
}

/// SDK render pipeline, with explicit tree/focus/layer cleanup. screenshot 3.0.0 was evaluated: its detached
/// capture leaves the widget tree mounted, so repeated graph exports would retain card listeners and focus state.
Future<Uint8List> _capture(BuildContext context, Size size, double ratio, Widget child) async {
  final boundary = RenderRepaintBoundary();
  final focus = FocusManager();
  var dirty = true;
  final owner = BuildOwner(focusManager: focus, onBuildScheduled: () => dirty = true);
  final pipeline = PipelineOwner();
  final renderView = RenderView(
    view: View.of(context),
    configuration: ViewConfiguration(
      logicalConstraints: BoxConstraints.tight(size),
      physicalConstraints: BoxConstraints.tight(size * ratio),
      devicePixelRatio: ratio,
    ),
    child: boundary,
  );
  pipeline.rootNode = renderView;
  renderView.prepareInitialFrame();
  final entry = OverlayEntry(builder: (_) => child);
  final root = RenderObjectToWidgetAdapter<RenderBox>(
    container: boundary,
    child: InheritedTheme.captureAll(
      context,
      MediaQuery(
        data: MediaQuery.of(context).copyWith(size: size),
        child: Directionality(
          textDirection: Directionality.of(context),
          child: Material(
            type: MaterialType.transparency,
            child: TickerMode(enabled: false, child: Overlay(initialEntries: [entry])),
          ),
        ),
      ),
    ),
  ).attachToRenderTree(owner);
  ui.Image? captured;
  try {
    // Give asynchronous icons/images time to paint; build only when the detached tree requested it.
    for (var i = 0; i < 4; i++) {
      dirty = false;
      owner.buildScope(root);
      owner.finalizeTree();
      pipeline.flushLayout();
      pipeline.flushCompositingBits();
      pipeline.flushPaint();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!dirty) break;
    }
    captured = await boundary.toImage(pixelRatio: ratio);
    final bytes = await captured.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw const FormatException('Could not capture the canvas.');
    return bytes.buffer.asUint8List();
  } finally {
    captured?.dispose();
    entry.remove();
    RenderObjectToWidgetAdapter<RenderBox>(container: boundary).attachToRenderTree(owner, root);
    owner.buildScope(root);
    owner.finalizeTree();
    entry.dispose();
    pipeline.rootNode = null;
    renderView.child = null;
    boundary.dispose();
    renderView.dispose();
    pipeline.dispose();
    focus.dispose();
  }
}

Future<void> showCanvasImagePreview(BuildContext context, CanvasImageExport image) => showDifyDialog<void>(
  context,
  builder: (context) => DifyDialogSurface(
    label: image.name,
    width: 960,
    height: MediaQuery.sizeOf(context).height * 0.85,
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(image.name)),
            DifyIconButton(
              label: DifyI18n.tr('common', 'operation.close'),
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: InteractiveViewer(minScale: 0.1, maxScale: 4, child: Image.memory(image.png, fit: BoxFit.contain)),
        ),
      ],
    ),
  ),
);

class _ExportCards extends DifyCards {
  const _ExportCards();
  @override
  Widget build(
    BuildContext context,
    CanvasNode node,
    CanvasGraph graph, {
    required bool live,
    VoidCallback? onPainted,
  }) {
    final card = super.build(context, node, graph, live: live, onPainted: onPainted);
    if (node.type != 'iteration') return card;
    final controls = super.controls(context, node, graph);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: card),
        for (final control in controls)
          Positioned.fromRect(rect: control.rect.shift(-node.visual.topLeft), child: const IterationAddBlockVisual()),
      ],
    );
  }
}
