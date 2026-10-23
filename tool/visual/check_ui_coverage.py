#!/usr/bin/env python3
"""Fail when a shared export, page source or registered node body is absent from the visual case inventory.

This validates the declared source/case matrix. It NEVER turns a missing/failed image into a visual pass.
"""
import json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
BASE=ROOT/'app/lib/src'

def sources(root=ROOT):
    base=root/'app/lib/src';widget=base/'design/widgets/widgets.dart'
    exports={str((widget.parent/name).resolve().relative_to(root.resolve())) for name in re.findall(r"export '([^']+)';",widget.read_text())}
    pages={str(p.relative_to(root)) for p in base.rglob('*page.dart')}
    bodies=set()
    for path in (base/'workflow_editor/node_panel/bodies').rglob('*_bodies.dart'):
        match=re.search(r'const Map<String, NodePanelBodyBuilder> \w+PanelBodies = \{(.*?)\n\};',path.read_text(),re.S)
        if match:bodies.update(re.findall(r"'([^']+)'\s*:",match[1]))
    return {'exports':exports,'pages':pages,'nodeBodies':bodies}

def validate(inventory,catalogs,actual):
    errors=[];ids={case['id'] for cases in catalogs for case in cases}
    for category,found in actual.items():
        declared={item['source']:item for item in inventory[category]}
        for source in sorted(found-declared.keys()):errors.append(f'New {category} source needs a coverage decision: {source}')
        for source in sorted(declared.keys()-found):errors.append(f'Stale {category} source: {source}')
        for source,item in declared.items():
            if item.get('visual',True) and not item.get('cases'):errors.append(f'Visual source has no cases: {source}')
            if not item.get('visual',True) and not item.get('reason'):errors.append(f'Nonvisual classification needs a reason: {source}')
            for case in item.get('cases',[]):
                if case not in ids:errors.append(f'Unknown case {case} for {source}')
    return errors

def validate_public_classes(inventory,root=ROOT):
    errors=[]
    for item in [r for kind in ['exports','pages'] for r in inventory.get(kind,[])]:
        path=root/item['source']
        if not path.is_file():continue
        actual=set(re.findall(r'^(?:(?:abstract|sealed|final|base|interface) )*class ([A-Z]\w*)',path.read_text(),re.M))
        declared=set(item.get('publicClasses',[]))
        if actual!=declared:errors.append(f"Public class inventory changed in {item['source']}: new={sorted(actual-declared)}, stale={sorted(declared-actual)}")
    return errors

def validate_design_ownership(inventory,root=ROOT):
    # A shared control has one implementation in design/. A page-local copy
    # would bypass its typography, focus and source-parity regression coverage.
    names={name for item in inventory.get('exports',[]) for name in item.get('publicClasses',[])}
    errors=[]
    base=root/'app/lib/src'
    for path in base.rglob('*.dart'):
        if 'design' in path.relative_to(base).parts:continue
        classes=set(re.findall(r'^(?:(?:abstract|sealed|final|base|interface) )*class ([A-Z]\w*)',path.read_text(),re.M))
        for name in sorted(classes & names):
            errors.append(f'Shared control {name} must be implemented in design/, not {path.relative_to(root)}')
    return errors

def main():
    folder=Path(__file__).parent;inventory=json.loads((folder/'ui_coverage.json').read_text());catalogs=[json.loads((folder/name).read_text()) for name in inventory['catalogs']]
    errors=validate(inventory,catalogs,sources())+validate_public_classes(inventory)+validate_design_ownership(inventory)
    if errors:raise SystemExit('\n'.join(errors))
    print('Declared source coverage complete: '+', '.join(f'{len(inventory[k])} {k}' for k in ['exports','pages','nodeBodies'])+'. Capture success must be checked separately.')
if __name__=='__main__':main()
