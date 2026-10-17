// Bundles the real Dify modules + environment shims -> dist/real.mjs. Also writes dist/manifest.json (sha256 of every Dify source file that ended up in the bundle).
import { build } from 'esbuild'
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const WEB = process.env.DIFY_WEB ?? '<dify-checkout>/web'
const SH = (f) => path.join(HERE, 'shims', f)
const WF = 'app/components/workflow'
const COLLAB = `${WF}/collaboration/core`

// web-root-relative path (no extension) -> shim.  Applies to every import (relative or '@/') of a Dify file.
const SHIM_BY_PATH = {
  [`${COLLAB}/websocket-manager`]: SH('websocket-manager.ts'),
  [`${COLLAB}/collaboration-manager`]: SH('collab-singleton.ts'),
  'config': SH('config.ts'),
  'config/index': SH('config.ts'),
  [`${WF}/hooks/use-workflow`]: SH('use-workflow.ts'),
  [`${WF}/store`]: SH('workflow-store.ts'),
  [`${WF}/store/index`]: SH('workflow-store.ts'),
  [`${WF}/hooks-store`]: SH('hooks-store.ts'),
  [`${WF}/hooks-store/index`]: SH('hooks-store.ts'),
  'app/components/base/features/hooks': SH('features-hooks.ts'),
  [`${WF}/nodes/agent-v2/types`]: SH('agent-v2-types.ts'),
  [`${WF}/types`]: SH('workflow-types.ts'),
  'features/system-features/client': SH('system-features.ts'),
  'service/app-deletion': SH('app-deletion.ts'),
  'service/fetch': SH('service-fetch.ts'),
  'service/workflow': SH('service-workflow.ts'),
  'app/components/app/store': SH('app-store.ts'),
  'context/event-emitter': SH('event-emitter.ts'),
  [`${WF}/constants`]: SH('workflow-constants.ts'),
  [`${WF}/utils`]: SH('workflow-utils.ts'),
  [`${WF}/utils/index`]: SH('workflow-utils.ts'),
  'app/components/workflow-app/hooks/use-workflow-draft-graph-for-canvas': SH('draft-graph-for-canvas.ts'),
}
const SHIM_BARE = {
  react: SH('react.ts'),
  reactflow: SH('reactflow.ts'),
  '@tanstack/react-query': SH('react-query.ts'),
  'socket.io-client': SH('socket-io-client.ts'),
  'loro-crdt': SH('loro-crdt.ts'),
}
const REAL = {
  'websocket-manager': `${COLLAB}/websocket-manager.ts`,
  'collaboration-manager': `${COLLAB}/collaboration-manager.ts`,
}

const used = new Set()
const shimmed = []
const exts = ['.ts', '.tsx', '/index.ts', '/index.tsx']
function resolveFile(base) {
  for (const e of exts) if (fs.existsSync(base + e)) return base + e
  if (fs.existsSync(base) && fs.statSync(base).isFile()) return base
  return null
}

const plugin = {
  name: 'dify-sim',
  setup(b) {
    b.onResolve({ filter: /.*/ }, (args) => {
      if (args.kind === 'entry-point') return null
      const p = args.path
      if (p.startsWith('@real/')) return { path: path.join(WEB, REAL[p.slice(6)]) }
      if (p.startsWith('@dify/')) {
        const f = resolveFile(path.join(WEB, p.slice(6)))
        if (!f) return { errors: [{ text: `cannot resolve ${p}` }] }
        return { path: f }
      }
      const fromDify = args.importer.startsWith(WEB)
      const fromShim = args.importer.startsWith(path.join(HERE, 'shims'))
      if (p === 'loro-crdt/nodejs') return { path: p, external: true }
      if (fromDify) {
        if (SHIM_BARE[p]) return { path: SHIM_BARE[p] }
        if (p.startsWith('@/') || p.startsWith('.')) {
          const abs = p.startsWith('@/') ? path.join(WEB, p.slice(2)) : path.resolve(path.dirname(args.importer), p)
          const rel = path.relative(WEB, abs)
          if (SHIM_BY_PATH[rel]) {
            shimmed.push({ importer: path.relative(WEB, args.importer), spec: p, shim: path.relative(HERE, SHIM_BY_PATH[rel]) })
            return { path: SHIM_BY_PATH[rel] }
          }
          const f = resolveFile(abs)
          if (!f) return { errors: [{ text: `UNRESOLVED (needs a shim?): ${p} imported from ${args.importer}` }] }
          return { path: f }
        }
        // bare package import from Dify source: resolve against our node_modules
        return b.resolve(p, { resolveDir: HERE, kind: args.kind, pluginData: 'x' })
      }
      return null
    })
    b.onLoad({ filter: /\.(ts|tsx)$/ }, (args) => {
      if (args.path.startsWith(WEB)) used.add(args.path)
      return null
    })
  },
}

const t0 = Date.now()
await build({
  entryPoints: [path.join(HERE, 'src/real-entry.ts')],
  outfile: path.join(HERE, 'dist/real.mjs'),
  bundle: true,
  format: 'esm',
  platform: 'node',
  target: 'node22',
  sourcemap: 'inline',
  keepNames: true,
  plugins: [plugin],
  logLevel: 'warning',
  banner: { js: "import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);" },
  tsconfigRaw: { compilerOptions: { jsx: 'react-jsx' } },
})
const manifest = [...used].sort().map((f) => ({
  file: path.relative(WEB, f),
  sha256: crypto.createHash('sha256').update(fs.readFileSync(f)).digest('hex'),
  lines: fs.readFileSync(f, 'utf8').split('\n').length - 1,
}))
fs.writeFileSync(path.join(HERE, 'dist/manifest.json'), JSON.stringify({ dify: '1.17.1', web: WEB, files: manifest, shimmed }, null, 2))
console.log(`built dist/real.mjs in ${Date.now() - t0}ms; ${manifest.length} real Dify files; ${shimmed.length} shimmed imports`)
