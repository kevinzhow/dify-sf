#!/usr/bin/env python3
"""Build an isolated web SDK with the optional Dify missing-glyph provider.
Never writes the installed Flutter SDK. Compiles both Wasm and JS platforms.
"""
import argparse,hashlib,json,shutil,subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser();parser.add_argument('--flutter',type=Path,required=True);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
cache=args.flutter.resolve()/'bin/cache';build=args.output.resolve();sdk=build/'flutter_web_sdk'
version=json.loads((cache/'flutter.version.json').read_text())
assert version['engineRevision']=='692136cb6582dbfc5af3fb33c2515a069f2f66d0', 'Review the engine extension before upgrading Flutter'
if build.exists():raise SystemExit('Output must be a new isolated directory')
build.mkdir(parents=True)
shutil.copytree(cache/'flutter_web_sdk',sdk)
(build/'dart-sdk').symlink_to(cache/'dart-sdk',target_is_directory=True)
# Flutter's supported local-web-SDK resolver also needs its read-only prebuilt Dart path.
prebuilt=build.parents[1]/'flutter/prebuilts/linux-x64'
prebuilt.mkdir(parents=True,exist_ok=True)
if not (prebuilt/'dart-sdk').exists():(prebuilt/'dart-sdk').symlink_to(cache/'dart-sdk',target_is_directory=True)
service=sdk/'lib/_engine/engine/font_fallback_service.dart'
s=service.read_text();original_sha=hashlib.sha256(service.read_bytes()).hexdigest()
assert original_sha=='dbff663a0ece2bb52f134f2d2d489a8257a3c74c86f31cecffe9fdc56aff1d2c', 'Review the font hook against this Flutter engine before upgrading'
# This patch is intentionally narrow and guarded against SDK source drift.
assert 'class FallbackFontService {' in s and 'void addMissingCodePoints(List<int> codePoints) {' in s
s=s.replace('class FallbackFontService {','class FallbackFontService with DifyFontFallback {')
s=s.replace('void addMissingCodePoints(List<int> codePoints) {','''void addMissingCodePoints(List<int> codePoints) {
    if (_queueDifyFonts(codePoints)) return;
    _addStandardMissingCodePoints(codePoints);
  }

  void _addStandardMissingCodePoints(List<int> codePoints) {''')
s=s.replace('if (_unprocessedCodePoints.isEmpty && _pendingFonts.isEmpty) {','if (_unprocessedCodePoints.isEmpty && _pendingFonts.isEmpty && !_difyBusy && _difyPending.isEmpty) {')
s=s.replace('void _checkIdle() {', 'void _checkIdle() {\n    _reportDifyFontFailure();')
service.write_text(s)
engine=sdk/'lib/_engine/engine.dart';s=engine.read_text();needle="part 'engine/font_fallback_service.dart';";assert s.count(needle)==1;engine.write_text(s.replace(needle,needle+"\npart 'engine/dify_font_fallback.dart';"))
shutil.copy2(ROOT/'tool/web_engine/dify_font_fallback.dart',sdk/'lib/_engine/engine/dify_font_fallback.dart')
packages=build/'packages.json';packages.write_text(json.dumps({'configVersion':2,'packages':[]}))
for target,stub,out in [('dart2wasm','_skwasm_impl','dart2wasm_platform.dill'),('dart2js','_skwasm_stub','dart2js_platform.dill')]:
    cmd=[str(cache/'dart-sdk/bin/dartaotruntime'),str(cache/'dart-sdk/bin/snapshots/kernel_worker_aot.dart.snapshot'),'--target',target,'--no-summary-only','--no-summary','--null-environment','--libraries-file',(sdk/'libraries.json').as_uri(),'--packages-file',packages.as_uri(),'--output',str(sdk/'kernel'/out)]
    for library in ['core','ui','ui_web','_engine',stub,'_web_locale_keymap','_web_test_fonts']:cmd+=['--source',f'dart:{library}']
    subprocess.run(cmd,check=True)
proof={'flutter_revision':version['frameworkRevision'],'engine_revision':version['engineRevision'],'dart_version':version['dartSdkVersion'],'upstream_service_sha256':original_sha,'hook_sha256':hashlib.sha256((ROOT/'tool/web_engine/dify_font_fallback.dart').read_bytes()).hexdigest(),'outputs':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (sdk/'kernel').glob('*platform.dill')}}
(build/'dify-font-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
print(json.dumps(proof))
