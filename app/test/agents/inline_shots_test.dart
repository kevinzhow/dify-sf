import 'dart:io';
import 'dart:ui' as ui;

import 'package:dify_sf_app/src/agents/inline_configure.dart';
import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_fonts.dart';
import 'inline_composer_test.dart' show Fixture, composerReply;

void main() {
  final output = Platform.environment['AGENT_CONFIG_SHOTS'];
  if (output == null) return;
  for (final language in ['en-US', 'zh-Hans']) {
    for (final dark in [false, true]) {
      for (final width in [360.0, 560.0]) {
        testWidgets('inline configuration $language dark=$dark width=$width', (t) async {
          await t.runAsync(() async {
            await useAppFonts();

            await DifyFonts.loadFor(language);
            // flutter_tester's native Skia does not decode the production web WOFF2 faces.
            // Optional fixtures are the exact same pinned glyphs losslessly decompressed to OpenType.
            if (Platform.environment['AGENT_SHOT_FONT_DIR'] case final String dir) {
              final loader = FontLoader('Dify CJK SC');
              for (final weight in ['Regular', 'Bold']) {
                loader.addFont(
                  File('$dir/NotoSansCJKSC-$weight.otf').readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
                );
              }
              await loader.load();
            }

            await DifyI18n.load(language);
          });

          await t.binding.setSurfaceSize(Size(width, 900));

          addTearDown(() => t.binding.setSurfaceSize(null));
          DifyColors.useDark(dark);
          addTearDown(() => DifyColors.useDark(false));
          final f = Fixture();
          addTearDown(f.changes.close);
          f.api.response = {
            ...composerReply(),
            'agent_soul': {
              'model': null,
              'prompt': {
                'system_prompt': language == 'zh-Hans'
                    ? '检查输入材料，完成任务后报告结果。'
                    : 'Inspect the supplied materials and report the completed result.',
              },
              'config_files': [
                {'name': 'instructions.txt', 'file_kind': 'upload_file', 'file_id': '', 'is_missing': true},
              ],
              'env': {
                'variables': [
                  {'name': 'PROJECT', 'value': 'fixture'},
                ],
                'secret_refs': [
                  {'name': 'ACCESS_KEY', 'ref': 'fixture-only-reference', 'value': '********'},
                ],
              },
              'human': {
                'contacts': [
                  {'id': 'fixture-operator', 'name': language == 'zh-Hans' ? '操作员' : 'Operator', 'method': 'web_app'},
                ],
              },
            },
            'node_job': {
              'metadata': {
                'file_refs': [
                  {'name': 'reference.txt', 'is_missing': true},
                ],
              },
            },
          };
          final boundary = GlobalKey();
          await t.pumpWidget(
            MaterialApp(
              theme: difyTheme(
                fontFamily: 'Noto Sans',
                fontFamilyFallback: DifyFonts.fallbackFamilies,
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              home: RepaintBoundary(
                key: boundary,
                child: Material(
                  child: InlineAgentConfigure(
                    composer: f.client,
                    args: (
                      nodeId: 'node',
                      agentId: 'private-agent',
                      composerState: null,
                      onClose: () {},
                      onSaved: (_) {},
                      onSaveInlineToRoster: null,
                    ),
                  ),
                ),
              ),
            ),
          );
          for (var i = 0; i < 4; i++) {
            await t.runAsync(() => Future<void>.delayed(Duration.zero));
            await t.pump(const Duration(milliseconds: 100));
          }
          Future<void> capture(String position) => t.runAsync(() async {
            expect(t.takeException(), isNull);
            final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage(
              pixelRatio: 2,
            );
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final dir = Directory(output)..createSync(recursive: true);
            File('${dir.path}/$language-${dark ? 'dark' : 'light'}-${width.toInt()}-$position.png')
                .writeAsBytesSync(data!.buffer.asUint8List());
            image.dispose();
          });
          await capture('top');
          await t.pumpWidget(const SizedBox());
          await t.runAsync(() => Future<void>.delayed(Duration.zero));
        });
      }
    }
  }
}
