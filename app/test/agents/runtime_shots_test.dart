// Supplemental states of the actual shared runtime widgets. These captures are
// not original-Dify parity scores and do not change the fixed 450-scene matrix.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dify_sf_app/src/design/dify_fonts.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/human_input_content.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/log_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart' as re;

import '../support/app_fonts.dart';

void main() {
  final output = Platform.environment['AGENT_RUNTIME_SHOTS'];
  if (output == null) return;
  for (final language in ['en-US', 'zh-Hans']) {
    for (final dark in [false, true]) {
      for (final width in [360.0, 560.0]) {
        for (final kind in ['approval', 'long-log']) {
          testWidgets('runtime $kind $language dark=$dark width=$width', (t) async {
            final chinese = language == 'zh-Hans';
            await t.runAsync(() async {
              await useAppFonts();
              final mono = FontLoader('DejaVu Sans Mono')..addFont(rootBundle.load('assets/fonts/DejaVuSansMono.ttf'));
              await mono.load();
              if (Platform.environment['AGENT_SHOT_EMOJI_FONT'] case final String emoji) {
                final loader = FontLoader('Noto Color Emoji')
                  ..addFont(File(emoji).readAsBytes().then(ByteData.sublistView));
                await loader.load();
              }
              await DifyFonts.loadFor(language);
              final dir = Platform.environment['AGENT_SHOT_FONT_DIR'];
              if (dir != null) {
                final loader = FontLoader('Dify CJK SC');
                for (final weight in ['Regular', 'Bold']) {
                  loader.addFont(File('$dir/NotoSansCJKSC-$weight.otf').readAsBytes().then(ByteData.sublistView));
                }
                await loader.load();
              }
              await DifyI18n.load(language);
            });
            await t.binding.setSurfaceSize(Size(width, 900));
            addTearDown(() => t.binding.setSurfaceSize(null));
            DifyColors.useDark(dark);
            addTearDown(() => DifyColors.useDark(false));
            final boundary = GlobalKey();
            final label = chinese ? '执行记录 · 已完成' : 'Execution log · completed';
            final content = kind == 'approval'
                ? HumanInputFormList(
                    inPanel: true,
                    humanInputFormDataList: [
                      {
                        'form_id': 'fixture-form',
                        'node_id': 'fixture-agent',
                        'node_title': chinese ? '需要确认' : 'Approval required',
                        'form_content': chinese
                            ? '请核对输出文件并填写备注。 {{#\$output.note#}}'
                            : 'Review the output file and add a note. {{#\$output.note#}}',
                        'inputs': [
                          {
                            'type': 'paragraph',
                            'output_variable_name': 'note',
                            'default': {
                              'selector': <Object?>[],
                              'type': 'constant',
                              'value': chinese ? '核对中，保留输入。' : 'Review in progress; keep this input.',
                            },
                          },
                        ],
                        'actions': [
                          {'id': 'approve', 'title': chinese ? '继续' : 'Continue', 'button_style': 'primary'},
                        ],
                        'form_token': 'synthetic-local-only',
                        'resolved_default_values': <String, Object?>{},
                        'display_in_ui': true,
                        'expiration_time': 2000000000,
                      },
                    ],
                    onHumanInputFormSubmit: (_, _) async {},
                  )
                : AgentLogItem(
                    item: {
                      'id': 'fixture-log',
                      'label': label,
                      'status': 'success',
                      'metadata': {'elapsed_time': 1.234},
                      'children': [
                        {'label': 'Tool', 'status': 'success'},
                      ],
                      'data': {
                        'head': List.generate(
                          40,
                          (i) => chinese ? '步骤 $i：检查材料，值已脱敏。' : 'Step $i: inspected input; value redacted.',
                        ),
                        'gap': chinese ? '中间内容见完整归档' : 'See the complete archive for the omitted middle',
                        'tail': 'completed · 中文 😀 e\u0301',
                      },
                    },
                    onShowAgentOrToolLog: ([detail]) {},
                  );
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
                    child: SingleChildScrollView(
                      child: Padding(padding: const EdgeInsets.all(16), child: content),
                    ),
                  ),
                ),
              ),
            );
            await t.pumpAndSettle();
            if (kind == 'long-log') {
              await t.tap(find.text(label.toUpperCase()));
              await t.pumpAndSettle();
            }
            expect(t.takeException(), isNull);
            Future<void> capture(String suffix) async {
              await t.runAsync(() async {
                final image = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(
                  pixelRatio: 2,
                );
                final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
                final target = Directory(output)..createSync(recursive: true);
                File('${target.path}/$kind-$language-${dark ? 'dark' : 'light'}-${width.toInt()}$suffix.png')
                    .writeAsBytesSync(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }

            await capture('');
            if (kind == 'long-log') {
              final scroll = t.widget<re.CodeEditor>(find.byType(re.CodeEditor)).scrollController!.verticalScroller;
              expect(scroll.position.maxScrollExtent, greaterThan(0));
              scroll.jumpTo(scroll.position.maxScrollExtent);
              await t.pumpAndSettle();
              expect(scroll.offset, greaterThan(0));
              await capture('-tail');
            }
            await t.pumpWidget(const SizedBox());
            await t.runAsync(() => Future<void>.delayed(Duration.zero));
          });
        }
      }
    }
  }
}
