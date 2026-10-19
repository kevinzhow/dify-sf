"""Compare the pure search index against the original-library fixture on Dart VM and compiled JavaScript.

Run inside the project's bounded job wrapper. Requires Dart and bun (or node), with no browser or extra packages.
"""
import base64
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def encoded(path):
    return base64.b64encode((ROOT / path).read_bytes()).decode()

source = """import 'dart:convert';
import '%s';
void main() {
  final data = (jsonDecode(utf8.decode(base64Decode('%s'))) as Map).cast<String, Object?>();
  final fixture = jsonDecode(utf8.decode(base64Decode('%s'))) as Map;
  final index = EmojiSearchIndex(data);
  for (final row in fixture['cases'] as List) {
    if (jsonEncode(index.search(row['query'] as String)) != jsonEncode(row['ids'])) {
      throw StateError('Query mismatch: ${row['query']}');
    }
  }
  final ids = (data['emojis'] as Map).keys.cast<String>().toList()..sort(EmojiSearchIndex.compareIds);
  if (jsonEncode(ids) != jsonEncode(fixture['sortedIds'])) throw StateError('Collation mismatch');
  print('50 original-library queries and 1870 collation IDs match.');
}
""" % ((ROOT / 'app/lib/src/design/widgets/emoji_search.dart').as_uri(),
       encoded('app/assets/emoji/native.json'), encoded('app/test/fixtures/emoji_search_v5_6_0.json'))

runtime = shutil.which('bun') or shutil.which('node')
if runtime is None:
    raise SystemExit('Install bun or node to execute the compiled JavaScript check.')
with tempfile.TemporaryDirectory(prefix='emoji-search-check-') as directory:
    driver = Path(directory) / 'check.dart'
    driver.write_text(source)
    subprocess.run(['dart', str(driver)], check=True)
    javascript = driver.with_suffix('.js')
    subprocess.run(['dart', 'compile', 'js', '-O2', str(driver), '-o', str(javascript)], check=True)
    subprocess.run([runtime, str(javascript)], check=True)
