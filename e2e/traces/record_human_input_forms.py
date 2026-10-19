"""Record form semantics from Dify 1.17.1 / graphon 0.7.0, not from the Swift implementation.

Run in langgenius/dify-api:1.17.1 with /app/api/.venv/bin/python and PYTHONPATH=/app/api.
The stdout JSON is server/Tests/CollabTests/Fixtures/human-input/forms.json.
Uses the pinned image's Dify-owned form entities, submission service and HITL callback.
No HTTP calls or database writes; the form repository is unused.
"""
import json
from core.workflow.nodes.human_input.entities import HumanInputNodeData
from core.workflow.nodes.human_input.callback import DifyHITLCallback, render_form_content_before_submission, resolve_default_values
from services.human_input_service import HumanInputService
from graphon.runtime.variable_pool import VariablePool
from graphon.variables.factory import build_segment

base = dict(type='human-input', title='Approval', form_content='Hello {{#start.name#}}: {{#$output.reply#}}',
            inputs=[dict(type='paragraph', output_variable_name='reply', default=dict(type='variable', selector=['start','name']))],
            user_actions=[dict(id='approve',title='Approve it')])
cases = [dict(id='text', data=base, values=dict(reply='Yes'), action='approve'),
         dict(id='paragraph-json',data=base,values=dict(reply={'b':True,'a':None}, ignored='unknown'),action='approve'),
         dict(id='paragraph-null',data=base,values=dict(reply=None),action='approve'),
         dict(id='invalid-action',data=base,values={},action='invalid'),
         dict(id='missing',data=base,values={},action='approve'),
         dict(id='select',data={**base, 'inputs':[dict(type='select',output_variable_name='reply', option_source=dict(type='constant',value=['A','B']))]},values=dict(reply='B'),action='approve'),
         dict(id='invalid-select',data={**base, 'inputs':[dict(type='select',output_variable_name='reply',option_source=dict(type='constant',value=['A']))]},values=dict(reply='X'),action='invalid'),
         dict(id='select-variable-short',data={**base, 'inputs':[dict(type='select',output_variable_name='reply',option_source=dict(type='variable',selector=[]))]},values=dict(reply='anything'),action='approve')]
pool=VariablePool()
pool.add(['start','name'],build_segment('World'))
for c in cases:
    try:
        data=HumanInputNodeData(**c['data'])
        c['mapping']=data.extract_variable_selector_to_variable_mapping('hi')
        c['defaults']=dict(resolve_default_values(data,variable_pool=pool))
        c['rendered']=render_form_content_before_submission(data,variable_pool=pool)
        normalized=HumanInputService.validate_and_normalize_submission(tenant_id='test',form_definition=data,selected_action_id=c['action'],form_data=c['values'])
        cb=DifyHITLCallback(form_repository=None,node_data=data)
        restored=cb._restore_submitted_data(submitted_data=normalized)
        c['expected_inputs']={k:v.to_object() for k,v in restored.items()}
        c['expected_outputs']={**c['expected_inputs'], '__action_id':c['action'],'__action_value':data.must_resolve_action_value(c['action']),
            '__rendered_content':cb.render_form_content_with_outputs(c['rendered'],restored,data.outputs_field_names(),data.inputs)}
    except Exception as e:
        c['error']=str(e)
print(json.dumps(cases,ensure_ascii=False,indent=2))
