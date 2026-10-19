// dify-spec: web/app/components/app/create-from-dsl-modal/__tests__/uploader.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/studio/create_from_dsl_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

typedef _Dropped = ({String name, Future<int> Function() length, Future<String> Function() read});

_Dropped _dropped(String name, [String content = 'name: demo']) =>
    (name: name, length: () async => content.length, read: () async => content);

/// Dify's `ControlledUploader` (or, with [controlled] false, a fixed [file] with a recording `updateFile`).
class _Host extends StatefulWidget {
  const _Host({this.initial, this.controlled = true, this.pick, this.displayName = 'YAML', this.outside = false});
  final DslFileData? initial;
  final bool controlled;
  final Future<DslFileData?> Function()? pick;
  final String displayName;
  final bool outside;

  @override
  State<_Host> createState() => _HostState();
}

final _updates = <DslFileData?>[];

class _HostState extends State<_Host> {
  late DslFileData? file = widget.initial;

  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: 600,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.outside) TextButton(onPressed: () {}, child: const Text('Outside')),
          DslUploader(
            file: file,
            displayName: widget.displayName,
            pickFile: widget.pick ?? () async => null,
            onChange: (f) {
              _updates.add(f);
              if (widget.controlled) setState(() => file = f);
            },
          ),
        ],
      ),
    ),
  );
}

DslUploaderState _uploader(WidgetTester t) => t.state<DslUploaderState>(find.byType(DslUploader));

bool _hasFocus(WidgetTester t, Finder f) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final targets = f.evaluate().toSet();
  var inside = targets.contains(focused);
  focused.visitAncestorElements((e) {
    if (targets.contains(e)) inside = true;
    return !inside;
  });
  return inside;
}

void main() {
  setUp(_updates.clear);

  group('Uploader', () {
    testWidgets('should upload a single dropped file', (t) async {
      await renderMembers(t, const _Host(controlled: false));
      await _uploader(t).drop([_dropped('demo.yml')]);
      await settle(t);
      expect(_updates.single?.name, 'demo.yml');
      expect(await _updates.single!.read(), 'name: demo');
    });

    testWidgets('should reject dropping multiple files', (t) async {
      await renderMembers(t, const _Host(controlled: false));
      await _uploader(t).drop([_dropped('a.yml', 'a'), _dropped('b.yml', 'b')]);
      await settle(t);
      expect(find.text('dataset-creation.stepOne.uploader.validation.count'), findsOneWidget);
      expect(_updates, isEmpty);
    });

    testWidgets('should render the selected file and allow removing it', (t) async {
      await renderMembers(
        t,
        _Host(controlled: false, initial: dslFileOf('demo.yml', 'name: demo'), displayName: 'DSL'),
      );
      expect(find.text('demo.yml'), findsOneWidget);
      expect(find.textContaining('DSL', findRichText: true), findsOneWidget);
      await tapButton(t, 'common.operation.delete');
      expect(_updates, hasLength(1));
    });

    testWidgets('should ignore drops without dataTransfer', (t) async {
      await renderMembers(t, const _Host(controlled: false));
      await _uploader(t).drop(null);
      await settle(t);
      expect(_updates, isEmpty);
    });

    testWidgets('should update the file from the hidden uploader input', (t) async {
      await renderMembers(t, _Host(controlled: false, pick: () async => dslFileOf('next.yml', 'next')));
      await tapButton(t, 'app.dslUploader.browse');
      expect(_updates.single?.name, 'next.yml');
    });

    testWidgets('should move keyboard focus to the selected file row before the remove action', (t) async {
      await renderMembers(t, _Host(pick: () async => dslFileOf('next.yml', 'next')));
      // Focus Browse with the keyboard, then press Enter.
      while (!_hasFocus(t, find.byKey(const ValueKey('dsl-browse')))) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
      }
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(t);
      expect(_hasFocus(t, find.byKey(const ValueKey('dsl-file'))), isTrue, reason: 'the file row');
      expect(_hasFocus(t, find.byKey(const ValueKey('dsl-file-remove'))), isFalse);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(_hasFocus(t, find.byKey(const ValueKey('dsl-file-remove'))), isTrue);
    });

    testWidgets('should preserve focus ownership after selecting a file with a pointer', (t) async {
      await renderMembers(t, _Host(pick: () async => dslFileOf('next.yml', 'next')));
      await t.tap(find.byKey(const ValueKey('dsl-browse')));
      await settle(t);
      expect(find.text('next.yml'), findsOneWidget);
      expect(_hasFocus(t, find.byKey(const ValueKey('dsl-file'))), isTrue);
    });

    testWidgets('should not move focus when a file is dropped', (t) async {
      await renderMembers(t, const _Host(outside: true));
      await t.tap(find.text('Outside'));
      await t.pump();
      final before = FocusManager.instance.primaryFocus;
      await _uploader(t).drop([_dropped('next.yml', 'next')]);
      await settle(t);
      expect(find.text('next.yml'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus, before);
    });

    testWidgets('should restore keyboard focus to Browse after removing the file', (t) async {
      await renderMembers(t, _Host(initial: dslFileOf('demo.yml', 'name: demo')));
      while (!_hasFocus(t, find.byKey(const ValueKey('dsl-file-remove')))) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
      }
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(t);
      expect(_hasFocus(t, find.byKey(const ValueKey('dsl-browse'))), isTrue);
    });

    testWidgets('should toggle drag styles and clear them when leaving the overlay', (t) async {
      await renderMembers(t, const _Host(controlled: false));
      DashedBorderBox zone() => t.widget<DashedBorderBox>(find.byKey(const ValueKey('dsl-dropzone')));
      expect(zone().fill, DifyColors.componentsDropzoneBg);
      expect(zone().color, DifyColors.componentsDropzoneBorder);
      expect(zone().dashed, isTrue, reason: 'border-dashed');
      expect(zone().radius, 10);
      _uploader(t).dragEnter();
      await t.pump();
      expect(zone().fill, DifyColors.componentsDropzoneBgAccent);
      expect(zone().color, DifyColors.componentsDropzoneBorderAccent);
      _uploader(t).dragExit();
      await t.pump();
      expect(zone().fill, DifyColors.componentsDropzoneBg);
    });

    testWidgets('should reopen the hidden input and restore the previous file when the picker is cancelled', (t) async {
      var picks = 0;
      await renderMembers(
        t,
        _Host(
          controlled: false,
          pick: () async {
            picks++;
            return null;
          },
        ),
      );
      await tapButton(t, 'app.dslUploader.browse');
      expect(picks, 1);
      expect(_updates, [null]);
    });

    testWidgets('should clear the hidden input and remove the selected file', (t) async {
      await renderMembers(t, _Host(controlled: false, initial: dslFileOf('demo.yml', 'name: demo')));
      await tapButton(t, 'common.operation.delete');
      expect(_updates, [null]);
    });
  });
}
