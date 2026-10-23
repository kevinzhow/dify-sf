#!/usr/bin/env node
// Build actual pinned React controls in an OWNED sibling source/dependency stage.
import fs from 'node:fs'
import path from 'node:path'
import {createRequire} from 'node:module'
import {fileURLToPath,pathToFileURL} from 'node:url'
import {createHash} from 'node:crypto'
const options={}
for(let i=2;i<process.argv.length;i+=2)options[process.argv[i].replace(/^--/,'')]=process.argv[i+1]
for(const key of ['deps-root','reference-root','stage','out'])if(!options[key])throw new Error('Required --'+key)
const root=path.resolve(options['deps-root']),ref=path.resolve(options['reference-root'])
const stage=path.resolve(options.stage),out=path.resolve(options.out)
// Iconify's upstream plugin resolves collections from the process working directory.
process.chdir(root)
if(fs.existsSync(stage)||fs.existsSync(out))throw new Error('Fresh stage and output required; preserve failed attempts')
const req=createRequire(path.join(root,'package.json'))
const {build}=await import(pathToFileURL(req.resolve('vite')).href)
const {default:react}=await import(pathToFileURL(req.resolve('@vitejs/plugin-react')).href)
const {default:tailwindcss}=await import(pathToFileURL(req.resolve('@tailwindcss/vite')).href)
const source=path.join(path.dirname(fileURLToPath(import.meta.url)),'react_ui')
fs.mkdirSync(stage,{recursive:true})
const sha=(file)=>createHash('sha256').update(fs.readFileSync(file)).digest('hex')
const inputs={}
for(const name of ['host.tsx','host.css','index.html']){fs.copyFileSync(path.join(source,name),path.join(stage,name));inputs[name]=sha(path.join(source,name))}
fs.writeFileSync(path.join(stage,'production.css'),`@import '${ref}/web/app/styles/globals.css';\n@source '${source}';\n`)
// The calendar's date utility reads only IS_PROD from the application config.
// Supplying this environment constant avoids importing unrelated server configuration.
fs.writeFileSync(path.join(stage,'config.ts'),'export const IS_PROD = true;')
await build({configFile:false,root:stage,plugins:[react(),tailwindcss()],resolve:{alias:[{find:'@/config',replacement:path.join(stage,'config.ts')},{find:'@',replacement:path.join(ref,'web')}],dedupe:['react','react-dom']},build:{outDir:out,emptyOutDir:false}})
const binding=JSON.parse(fs.readFileSync(path.join(ref,'source-binding.json'),'utf8'))
fs.writeFileSync(path.join(out,'source-binding.json'),JSON.stringify({...binding,fixtureInputs:inputs,environmentShim:'IS_PROD=true; no component or styling logic replaced'},null,2)+'\n')
