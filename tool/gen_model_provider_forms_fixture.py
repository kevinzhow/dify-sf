#!/usr/bin/env python3
"""Generate all ten provider form fixtures using graphon 0.7.0's CredentialFormSchema response fields."""
import argparse,json
from pathlib import Path
import yaml
root=Path(__file__).resolve().parents[1]

def i18n(value):
 if isinstance(value,str):return {'en_US':value,'zh_Hans':value}
 if not isinstance(value,dict):return None
 en=str(value.get('en_US') or '');return {'en_US':en,'zh_Hans':str(value.get('zh_Hans') or en)}

def scalar(value):
 return str(value).lower() if isinstance(value,bool) else str(value)

def show_on(value):
 return [{'variable':v['variable'],'value':scalar(v['value'])} for v in value or []]

def forms(value):
 return [{'variable':f['variable'],'label':i18n(f.get('label')) or i18n(f['variable']),'type':f['type'],
  'required':bool(f.get('required',False)),'default':None if f.get('default') is None else scalar(f['default']),
  'options':[{'label':i18n(o.get('label')) or i18n(scalar(o['value'])),'value':scalar(o['value']),'show_on':show_on(o.get('show_on'))} for o in f.get('options') or []],
  'placeholder':i18n(f.get('placeholder')),'max_length':int(f.get('max_length') or 0),'show_on':show_on(f.get('show_on'))} for f in value or []]

rows=[]
for directory in sorted((root/'server/Sources/CollabModels/Resources/dify-official-plugins').iterdir()):
 if not (directory/'manifest.yaml').is_file():continue
 manifest=yaml.safe_load((directory/'manifest.yaml').read_text());p=yaml.safe_load((directory/manifest['plugins']['models'][0]).read_text())
 row={key:p[key] for key in ['label','supported_model_types','configurate_methods']}
 row['provider']=f"{manifest['author']}/{manifest['name']}/{p['provider']}"
 for key in ['provider_credential_schema','model_credential_schema']:
  if p.get(key):row[key]={**p[key],'credential_form_schemas':forms(p[key].get('credential_form_schemas'))}
 rows.append(row)
text=json.dumps({'source':'langgenius/dify-official-plugins@f2d7811364193f8d7069f24a299ee465c5519d3c','providers':rows},ensure_ascii=False,indent=2)+'\n'
out=root/'app/test/fixtures/model_provider_forms.json'
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--check',action='store_true');args=parser.parse_args()
if args.check:assert out.read_text()==text,'Regenerate the model provider form fixture'
else:out.write_text(text)
print('All ten provider form fixtures match the pinned definitions')
