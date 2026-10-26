// Generate expected wrapping from the unmodified Monaco 0.52.2 ESM implementation.
// Usage: node wrapping.mjs /absolute/path/to/monaco-editor/package > ../monaco_wrapping.json
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {pathToFileURL} from 'node:url';
const root=path.resolve(process.argv[2]);
const pkg=JSON.parse(fs.readFileSync(path.join(root,'package.json'),'utf8'));
if(pkg.version!=='0.52.2')throw new Error('Expected pinned Monaco0.52.2');
const file=path.join(root,'esm/vs/editor/common/viewModel/monospaceLineBreaksComputer.js');
const {MonospaceLineBreaksComputerFactory}=await import(pathToFileURL(file));
const options=fs.readFileSync(path.join(root,'esm/vs/editor/common/config/editorOptions.js'),'utf8');
function defaultString(name){const m=options.match(new RegExp(name+"[\\s\\S]*?// allow-any-unicode-next-line\\s*('(?:\\\\.|[^'])*')"));if(!m)throw new Error(name);return Function('return '+m[1])();}
const before=defaultString('wordWrapBreakBeforeCharacters'),after=defaultString('wordWrapBreakAfterCharacters');
const factory=new MonospaceLineBreaksComputerFactory(before,after);
const lines=['','x','    ','    return first + second + third + fourth + fifth','\treturn {"answer": very_long_function(first, second, third)}','        deeply_indented_call(argument_one, argument_two)','([{hello_world})] + x / y, z; next|line','    中文变量 = "中文标点，句号。不能随便断在开括号（后面）"','    value = "😀👩‍💻🚃 abcdefghijklmnop"','    value = "é and العربية and हिन्दी"','\t \tvalue = 123456789012345678901234567890','long_unbroken_name_abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ'];
const cases=[];
function add(text,columns,tabSize,indent,fullWidthColumns=2,keepAll=false){const c=factory.createLineBreaksComputer({typicalFullwidthCharacterWidth:fullWidthColumns,typicalHalfwidthCharacterWidth:1},tabSize,columns,indent,keepAll?'keepAll':'normal');c.addRequest(text,null,null);const data=c.finalize()[0];const breaks=data?.breakOffsets??[text.length];const points=new Set([0,1,text.length-1,text.length]);for(const b of breaks){points.add(b-1);points.add(b);points.add(b+1);}const positions=[...points].filter(p=>p>=0&&p<=text.length).sort((a,b)=>a-b).map(offset=>{const upstream=data?.translateToOutputPosition(offset,0);const downstream=data?.translateToOutputPosition(offset,1);return {offset,upstream:upstream?[upstream.outputLineIndex,upstream.outputOffset]:[0,offset],downstream:downstream?[downstream.outputLineIndex,downstream.outputOffset]:[0,offset]};});cases.push({text,columns,tabSize,indent,fullWidthColumns,keepAll,breakOffsets:breaks,breakVisibleColumns:data?.breakOffsetsVisibleColumn??[],indentColumns:data?.wrappedTextIndentLength??0,positions});}
for(const text of lines)for(const columns of [1,8,19,38,80])for(const indent of [0,1,2,3])add(text,columns,4,indent);
for(const text of lines)for(const tabSize of [2,8])for(const full of [1.75,2])add(text,17,tabSize,1,full);
for(const text of lines)add(text,12,4,1,2,true);
for(const text of lines)add(text,-1,4,1);
process.stdout.write(JSON.stringify({version:pkg.version,source:'monaco-editor/esm/vs/editor/common/viewModel/monospaceLineBreaksComputer.js',sourceSha256:crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex'),breakBefore:before,breakAfter:after,cases},null,2)+'\n');
