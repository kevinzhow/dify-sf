"""Copy Dify's translations (web/i18n/<language>/<namespace>.json, i18next, flat keys) as app assets.

Usage: python3 tool/gen_dify_i18n.py <dify source root> app/assets/i18n
Copies the namespaces the workflow editor uses, for every language Dify ships. Re-run when the Dify baseline moves.
"""
import json, shutil, sys
from pathlib import Path

NAMESPACES = ['workflow', 'common', 'plugin', 'plugin-trigger', 'tools', 'app', 'app-debug', 'run-log', 'time',
              'agent-v-2', 'dataset', 'dataset-settings', 'dataset-creation', 'dataset-documents', 'plugin-trigger', 'pipeline',
              'share', 'app-overview']
src, out = Path(sys.argv[1]) / 'web/i18n', Path(sys.argv[2])
if out.exists():
    shutil.rmtree(out)
langs = sorted(p.name for p in src.iterdir() if (p / 'common.json').exists())
for lang in langs:
    for ns in NAMESPACES:
        f = src / lang / f'{ns}.json'
        if f.exists():
            (out / lang).mkdir(parents=True, exist_ok=True)
            # Re-serialised compactly; content unchanged.
            (out / lang / f.name).write_text(json.dumps(json.loads(f.read_text()), ensure_ascii=False, separators=(',', ':')))
(out / 'languages.json').write_text(json.dumps(langs))
print(f'{len(langs)} languages, {len(NAMESPACES)} namespaces')
