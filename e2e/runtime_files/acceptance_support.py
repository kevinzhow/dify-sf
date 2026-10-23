"""Small workflow builders shared by real file IO/browser acceptance (no runtime or network stand-ins)."""
def node(id, kind, **data):
    return {'id': id, 'position': {'x':80,'y':120}, 'data': {'type':kind,'title':id,**data}}

def workflow(nodes, edges=None, name='Runtime files acceptance'):
    for i,n in enumerate(nodes): n['position']={'x':80+i*280,'y':160}
    edges=edges or [(s['id'],'source',t['id']) for s,t in zip(nodes,nodes[1:])]
    return {'kind':'app','version':'0.3.1','app':{'mode':'workflow','name':name},'workflow':{
        'environment_variables':[],'conversation_variables':[],'features':{},
        'graph':{'nodes':nodes,'edges':[{'id':str(i),'source':s,'sourceHandle':h,'target':t,'targetHandle':'target'} for i,(s,h,t) in enumerate(edges)]}}}
