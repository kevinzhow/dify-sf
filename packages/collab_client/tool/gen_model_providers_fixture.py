#!/usr/bin/env python3
"""Writes lib/src/testing/model_providers_fixture.dart: a small catalog for FakeModelProvidersApi, cut from the provider
definitions the dify-sf server vendors (server/Sources/CollabModels/Resources/dify-official-plugins), normalised the way
the server serves them (i18n objects {en_US, zh_Hans}, graphon's credential form fields, parameter templates resolved
like the plugin SDK). Usage: tool/gen_model_providers_fixture.py <path to dify-sf>"""
import json, os, sys
import yaml

root = os.path.join(sys.argv[1], 'server/Sources/CollabModels/Resources/dify-official-plugins')
PICK = {  # plugin dir -> predefined models to keep (by type)
    'openai': {'llm': ['gpt-4o', 'gpt-4o-mini', 'gpt-4.1'], 'text-embedding': ['text-embedding-3-small'], 'tts': [], 'speech2text': [], 'moderation': []},
    'anthropic': {'llm': ['claude-sonnet-4-5-20250929', 'claude-haiku-4-5-20251001']},
    'ollama': {},
    'openai_api_compatible': {},
}
TEMPLATES = {
    'temperature': {'label': {'en_US': 'Temperature', 'zh_Hans': '温度'}, 'type': 'float', 'help': {'en_US': 'Controls randomness. Lower temperature results in less random completions. As the temperature approaches zero, the model will become deterministic and repetitive. Higher temperature results in more random completions.', 'zh_Hans': '温度控制随机性。较低的温度会导致较少的随机完成。随着温度接近零，模型将变得确定性和重复性。较高的温度会导致更多的随机完成。'}, 'required': False, 'default': 0.0, 'min': 0.0, 'max': 1.0, 'precision': 2},
    'top_p': {'label': {'en_US': 'Top P', 'zh_Hans': 'Top P'}, 'type': 'float', 'help': {'en_US': 'Controls diversity via nucleus sampling: 0.5 means half of all likelihood-weighted options are considered.', 'zh_Hans': '通过核心采样控制多样性：0.5表示考虑了一半的所有可能性加权选项。'}, 'required': False, 'default': 1.0, 'min': 0.0, 'max': 1.0, 'precision': 2},
    'top_k': {'label': {'en_US': 'Top K', 'zh_Hans': 'Top K'}, 'type': 'int', 'help': {'en_US': 'Limits the number of tokens to consider for each step by keeping only the k most likely tokens.', 'zh_Hans': '通过只保留每一步中最可能的 k 个标记来限制要考虑的标记数量。'}, 'required': False, 'default': 50, 'min': 1, 'max': 100, 'precision': 0},
    'presence_penalty': {'label': {'en_US': 'Presence Penalty', 'zh_Hans': '存在惩罚'}, 'type': 'float', 'help': {'en_US': 'Applies a penalty to the log-probability of tokens already in the text.', 'zh_Hans': '对文本中已有的标记的对数概率施加惩罚。'}, 'required': False, 'default': 0.0, 'min': 0.0, 'max': 1.0, 'precision': 2},
    'frequency_penalty': {'label': {'en_US': 'Frequency Penalty', 'zh_Hans': '频率惩罚'}, 'type': 'float', 'help': {'en_US': 'Applies a penalty to the log-probability of tokens that appear in the text.', 'zh_Hans': '对文本中出现的标记的对数概率施加惩罚。'}, 'required': False, 'default': 0.0, 'min': 0.0, 'max': 1.0, 'precision': 2},
    'max_tokens': {'label': {'en_US': 'Max Tokens', 'zh_Hans': '最大标记'}, 'type': 'int', 'help': {'en_US': 'Specifies the upper limit on the length of generated results. If the generated results are truncated, you can increase this parameter.', 'zh_Hans': '指定生成结果长度的上限。如果生成结果截断，可以调大该参数。'}, 'required': False, 'default': 64, 'min': 1, 'max': 2048, 'precision': 0},
    'response_format': {'label': {'en_US': 'Response Format', 'zh_Hans': '回复格式'}, 'type': 'string', 'help': {'en_US': 'Set a response format, ensure the output from llm is a valid code block as possible, such as JSON, XML, etc.', 'zh_Hans': '设置一个返回格式，确保llm的输出尽可能是有效的代码块，如JSON、XML等'}, 'required': False, 'options': ['JSON', 'XML']},
    'json_schema': {'label': {'en_US': 'JSON Schema'}, 'type': 'text', 'help': {'en_US': 'Set a response json schema will ensure LLM to adhere it.', 'zh_Hans': '设置返回的json schema，llm将按照它返回'}, 'required': False},
}
PROPS = {'mode', 'context_size', 'max_chunks', 'file_upload_limit', 'supported_file_extensions', 'max_characters_per_chunk', 'default_voice', 'voices', 'word_limit', 'audio_type', 'max_workers'}

def i18n(v):
    if isinstance(v, str): return {'en_US': v, 'zh_Hans': v}
    if not isinstance(v, dict): return None
    en = str(v.get('en_US') or ''); zh = str(v.get('zh_Hans') or '')
    return {'en_US': en, 'zh_Hans': zh or en}

def show_on(v): return [{'variable': s['variable'], 'value': str(s['value'])} for s in (v or [])]

def form(fields):
    out = []
    for f in fields or []:
        out.append({'variable': f['variable'], 'label': i18n(f.get('label')) or i18n(f['variable']), 'type': f['type'],
                    'required': bool(f.get('required', False)), 'default': None if f.get('default') is None else (str(f['default']).lower() if isinstance(f['default'], bool) else str(f['default'])),
                    'options': [{'label': i18n(o.get('label')) or i18n(str(o['value'])), 'value': str(o['value']), 'show_on': show_on(o.get('show_on'))} for o in f.get('options') or []],
                    'placeholder': i18n(f.get('placeholder')), 'max_length': int(f.get('max_length') or 0), 'show_on': show_on(f.get('show_on'))})
    return out

def rule(r):
    d = dict(r)
    t = r.get('use_template')
    if t in TEMPLATES: d = {**TEMPLATES[t], **r}
    if not d.get('label'): d['label'] = {'en_US': d['name']}
    fl = lambda v: None if v is None else float(v)
    return {'name': d['name'], 'use_template': t if isinstance(t, str) else None, 'label': i18n(d['label']), 'type': d.get('type'),
            'help': i18n(d.get('help')), 'required': bool(d.get('required', False)), 'default': d.get('default'), 'min': fl(d.get('min')),
            'max': fl(d.get('max')), 'precision': d.get('precision'), 'options': [str(o) for o in d.get('options') or []]}

providers = []
for plugin, picks in PICK.items():
    d = os.path.join(root, plugin)
    manifest = yaml.safe_load(open(os.path.join(d, 'manifest.yaml')))
    p = yaml.safe_load(open(os.path.join(d, manifest['plugins']['models'][0])))
    pid = f"{manifest['author']}/{manifest['name']}/{p['provider']}"
    models = []
    for typ, names in picks.items():
        key = typ.replace('-', '_')
        mdir = os.path.join(d, 'models', key)
        files = sorted(f for f in os.listdir(mdir) if f.endswith('.yaml') and not f.startswith('_')) if os.path.isdir(mdir) else []
        for f in files:
            m = yaml.safe_load(open(os.path.join(mdir, f)))
            if names and m['model'] not in names: continue
            if not names and len([x for x in models if x['model_type'] == typ]) >= 1: continue
            label = i18n(m.get('label')) or {'en_US': '', 'zh_Hans': ''}
            if not label['en_US']: label = {'en_US': m['model'], 'zh_Hans': label['zh_Hans'] or m['model']}
            models.append({'model': m['model'], 'label': label, 'model_type': m['model_type'], 'features': m.get('features'),
                           'fetch_from': m.get('fetch_from', 'predefined-model'),
                           'model_properties': {k: v for k, v in (m.get('model_properties') or {}).items() if k in PROPS},
                           'deprecated': bool(m.get('deprecated', False)), 'parameter_rules': [rule(r) for r in m.get('parameter_rules') or []]})
    icons = {}
    for kind in ('icon_small', 'icon_small_dark'):
        f = (p.get(kind) or {}).get('en_US')
        if f:
            svg = open(os.path.join(d, '_assets', f)).read()
            # keep the fixture small: big icons become a placeholder of the provider's initial
            if len(svg) > 8000:
                svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><rect width="24" height="24" rx="6" fill="#D97757"/><text x="12" y="16" font-size="12" text-anchor="middle" fill="#fff">{p["label"]["en_US"][0]}</text></svg>'
            icons[kind] = svg
    help_ = p.get('help')
    providers.append({
        'provider': pid, 'label': i18n(p['label']), 'description': i18n(p.get('description')), 'background': p.get('background'),
        'help': {'title': i18n(help_['title']), 'url': i18n(help_['url'])} if help_ else None,
        'supported_model_types': p['supported_model_types'], 'configurate_methods': p['configurate_methods'],
        'provider_credential_schema': {'credential_form_schemas': form(p['provider_credential_schema']['credential_form_schemas'])} if p.get('provider_credential_schema') else None,
        'model_credential_schema': {'model': {'label': i18n(p['model_credential_schema']['model']['label']), 'placeholder': i18n(p['model_credential_schema']['model'].get('placeholder'))},
                                    'credential_form_schemas': form(p['model_credential_schema']['credential_form_schemas'])} if p.get('model_credential_schema') else None,
        'models': models,
        'positions': {k: [n for n in yaml.safe_load(open(os.path.join(d, v['position']))) if n in [m['model'] for m in models]]
                      for k, v in (p.get('models') or {}).items() if isinstance(v, dict) and v.get('position')},
        'icons': icons,
    })

src = json.dumps({'providers': providers}, ensure_ascii=False, separators=(',', ':'))
out = os.path.join(os.path.dirname(__file__), '..', 'lib/src/testing/model_providers_fixture.dart')
with open(out, 'w') as f:
    f.write('// GENERATED by tool/gen_model_providers_fixture.py from the provider definitions dify-sf vendors\n')
    f.write('// (langgenius/dify-official-plugins, Apache-2.0; see the server\'s Resources/dify-official-plugins/SOURCE.md). Do not edit.\n')
    f.write('// ignore_for_file: lines_longer_than_80_chars\n\n')
    f.write('/// OpenAI, Anthropic (a few predefined models each), Ollama and OpenAI-API-compatible, as JSON.\n')
    f.write("const modelProvidersFixtureJson = r'''" + src.replace("'''", "' ''") + "''';\n")
print(out, len(src), 'bytes')
