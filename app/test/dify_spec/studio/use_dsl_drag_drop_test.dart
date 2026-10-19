// dify-spec: web/app/components/apps/hooks/__tests__/use-dsl-drag-drop.spec.ts
import 'package:dify_sf_app/src/studio/dsl_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// The hook is DslDragDrop: the platform's drag events (desktop_drop) call dragEnter / dragLeave / drop; the zone
// widget (DslDropZone) connects them and stops listening when it goes away.

DroppedDslFile _file(String name) => (name: name, length: () async => 7, read: () async => 'content');

/// Sends a desktop_drop platform event (what the engine plugin reports).
Future<void> _platform(WidgetTester t, String method, Object? args) async {
  await t.binding.defaultBinaryMessenger.handlePlatformMessage(
    'desktop_drop',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );
  await t.pump();
}

void main() {
  late List<DroppedDslFile> dropped;
  DslDragDrop hook({bool enabled = true}) => DslDragDrop(onDslFileDropped: dropped.add, enabled: enabled);

  setUp(() => dropped = []);

  group('useDSLDragDrop', () {
    group('Basic functionality', () {
      test('should return dragging state', () {
        expect(hook().dragging, isFalse);
      });

      test('should initialize with dragging as false', () {
        expect(hook().dragging, isFalse);
      });
    });

    group('Drag events', () {
      test('should set dragging to true on dragenter with files', () {
        final h = hook()..dragEnter();
        expect(h.dragging, isTrue);
      });

      test('should not set dragging on dragenter without files', () {
        final h = hook()..dragEnter(hasFiles: false);
        expect(h.dragging, isFalse);
      });

      testWidgets('should handle dragover event', (t) async {
        final h = hook();
        await t.pumpWidget(
          MaterialApp(
            home: DslDropZone(drop: h, child: const SizedBox.expand()),
          ),
        );
        await _platform(t, 'entered', [100.0, 100.0]);
        expect(h.dragging, isTrue);
        // Moving over the zone keeps the drag (and is consumed by the zone).
        await _platform(t, 'updated', [120.0, 140.0]);
        expect(h.dragging, isTrue);
        await _platform(t, 'exited', null);
        expect(h.dragging, isFalse);
      });

      test('should set dragging to false on dragleave when leaving container', () {
        final h = hook()..dragEnter();
        expect(h.dragging, isTrue);
        h.dragLeave();
        expect(h.dragging, isFalse);
      });

      test('should keep dragging while moving from the viewport to its sibling overlay', () {
        final h = hook()..dragEnter();
        h.dragLeave(toInside: true);
        expect(h.dragging, isTrue);
      });
    });

    group('Drop functionality', () {
      test('should call onDSLFileDropped for .yaml file', () {
        hook().drop([_file('test.yaml')]);
        expect(dropped.map((f) => f.name), ['test.yaml']);
      });

      test('should call onDSLFileDropped for .yml file', () {
        hook().drop([_file('test.yml')]);
        expect(dropped.map((f) => f.name), ['test.yml']);
      });

      test('should call onDSLFileDropped for uppercase .YAML file', () {
        hook().drop([_file('test.YAML')]);
        expect(dropped.map((f) => f.name), ['test.YAML']);
      });

      test('should not call onDSLFileDropped for non-yaml file', () {
        hook().drop([_file('test.json')]);
        expect(dropped, isEmpty);
      });

      test('should set dragging to false on drop', () {
        final h = hook()..dragEnter();
        expect(h.dragging, isTrue);
        h.drop([_file('test.yaml')]);
        expect(h.dragging, isFalse);
      });

      test('should handle drop with no dataTransfer', () {
        hook().drop(null);
        expect(dropped, isEmpty);
      });

      test('should handle drop with empty files array', () {
        hook().drop(const []);
        expect(dropped, isEmpty);
      });

      test('should only process the first file when multiple files are dropped', () {
        hook().drop([_file('test1.yaml'), _file('test2.yaml')]);
        expect(dropped.map((f) => f.name), ['test1.yaml']);
      });
    });

    group('Enabled prop', () {
      test('should not add event listeners when enabled is false', () {
        final h = hook(enabled: false)..dragEnter();
        expect(h.dragging, isFalse);
      });

      test('should return dragging as false when enabled is false even if state is true', () {
        final h = hook()..dragEnter();
        expect(h.dragging, isTrue);
        h.enabled = false;
        expect(h.dragging, isFalse);
      });

      test('should default enabled to true', () {
        final h = DslDragDrop(onDslFileDropped: dropped.add)..dragEnter();
        expect(h.dragging, isTrue);
      });
    });

    group('Cleanup', () {
      testWidgets('should remove event listeners on unmount', (t) async {
        final h = hook();
        await t.pumpWidget(
          MaterialApp(
            home: DslDropZone(drop: h, child: const SizedBox.expand()),
          ),
        );
        await t.pumpWidget(const SizedBox());
        await _platform(t, 'entered', [100.0, 100.0]);
        expect(h.dragging, isFalse);
        await _platform(t, 'exited', null);
      });
    });

    group('Edge cases', () {
      testWidgets('should handle null dropZoneRef', (t) async {
        // A hook without a mounted zone receives no events.
        final h = hook();
        await _platform(t, 'entered', [100.0, 100.0]);
        expect(h.dragging, isFalse);
        await _platform(t, 'exited', null);
      });

      testWidgets('should handle dropZoneRef changing to null', (t) async {
        final h = hook();
        await t.pumpWidget(
          MaterialApp(
            home: DslDropZone(drop: h, child: const SizedBox.expand()),
          ),
        );
        await t.pumpWidget(const MaterialApp(home: SizedBox.expand()));
        expect(h.dragging, isFalse);
      });
    });
  });
}
