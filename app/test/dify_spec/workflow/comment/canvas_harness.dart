import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/canvas_input.dart' show ControlMode;
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/session_factory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real canvas over the demo document, in comment mode.
class CommentModeCanvas {
  CommentModeCanvas._(this.demo, this.opened, this.controller, this.canvas);
  final DemoBackend demo;
  final OpenedSession opened;
  final EditorController controller;
  final CanvasController canvas;

  static Future<CommentModeCanvas> start(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final demo = DemoBackend(withBo: false);
    final opened = await demo.openSession('demo', clientId: 'me-abc123', journaled: false);
    await opened.session.start();
    final controller = EditorController(session: opened.session, docId: 'demo', journaled: false);
    final canvas = CanvasController(mode: ControlMode.comment);
    await t.pumpWidget(
      MaterialApp(
        home: WorkflowCanvas(controller: controller, canvas: canvas),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    return CommentModeCanvas._(demo, opened, controller, canvas);
  }

  Future<void> dispose(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    controller.dispose();
    canvas.dispose();
    await opened.close();
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  }
}
