"""Import Dify 1.17.1's pinned @emoji-mart/data catalog and license without changing its data.

python3 tool/icons/update_emoji_catalog.py [local data-1.2.1.tgz]
"""
import io
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
URL = 'https://registry.npmjs.org/@emoji-mart/data/-/data-1.2.1.tgz'
raw = Path(sys.argv[1]).read_bytes() if len(sys.argv) > 1 else urllib.request.urlopen(URL).read()
with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
    for source, target in [
        ('package/sets/15/native.json', 'app/assets/emoji/native.json'),
        ('package/LICENSE', 'third_party/emoji-mart-data/LICENSE'),
    ]:
        (ROOT / target).parent.mkdir(parents=True, exist_ok=True)
        (ROOT / target).write_bytes(archive.extractfile(source).read())
(ROOT / 'third_party/emoji-mart-data/NOTICE').write_text(
    '@emoji-mart/data 1.2.1 (MIT). Unicode 15 native catalog, unmodified.\n'
    'Source: https://github.com/missive/emoji-mart/tree/main/packages/emoji-mart-data\n'
    'Archive: ' + URL + '\n'
    'Version pinned to Dify 1.17.1 pnpm-workspace.yaml.\n'
    'Regenerate with python3 tool/icons/update_emoji_catalog.py\n')
