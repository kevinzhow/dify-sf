const wall = () => Number(process.hrtime.bigint()) / 1e6
import fs from 'node:fs'
import path from 'node:path'
import { aggregate, runOne, wilson } from './runner'
import { SSERIES } from './scenarios/sseries'

const args = process.argv.slice(2)
const cmd = args[0]
const opt = (k: string, d?: string) => { const i = args.indexOf('--' + k); return i >= 0 ? args[i + 1] : d }

if (cmd === 'sseries') {
  const want = (opt('scenarios') ?? 'all').split(',')
  const K = Number(opt('runs', '20'))
  const uiSd = Number(opt('uisd', '50'))
  const calib = args.includes('--calib')
  fs.mkdirSync('out', { recursive: true })
  const all: any[] = []
  for (const sc of SSERIES) {
    if (want[0] !== 'all' && !want.includes(sc.id)) continue
    const rs = []
    const t0 = wall()
    for (let s = 1; s <= K; s++) rs.push((await runOne(sc, s, { uiSd, calib })).res)
    const a = aggregate(sc.id, rs)
    const fmt = (k: string) => { const [lo, hi] = wilson(a.M[k]!, K); return `${a.M[k]}/${K}[${(lo * 100).toFixed(0)}-${(hi * 100).toFixed(0)}%]` }
    console.log(sc.id.padEnd(6), ['M1', 'M2', 'M3', 'M4', 'M5'].map((k) => `${k} ${fmt(k)}`).join('  '), `err=${a.errors}`, `real=${sc.real ?? '-'}`, `${Math.round(wall() - t0)}ms`)
    all.push({ id: sc.id, doc: sc.doc, K, uiSd, M: a.M, counts: a.counts, errors: a.errors, tags: sc.tags })
  }
  fs.writeFileSync(opt('out') ?? 'out/sseries.json', JSON.stringify(all, null, 1))
}

if (cmd === 'catalog') {
  const { generateCases } = await import('./catalog/cases')
  const { runCase, runCaseSerial } = await import('./catalog/runcase')
  const cases = generateCases()
  const K = Number(opt('runs', '20'))
  const filter = opt('filter')
  const calib = args.includes('--calib')
  const rows: any[] = []
  for (const c of cases) {
    if (filter && !c.id.includes(filter)) continue
    const rs = []
    for (let s = 1; s <= K; s++) rs.push((await runCase(c, s, { calib })).res)
    const base = await runCaseSerial(c, 1)
    const a = aggregate(c.id, rs)
    const m4c = rs.filter((x) => x.metrics.M4 > base.metrics.M4).length
    rows.push({ id: c.id, title: c.title, tags: c.tags, M: a.M, K, counts: a.counts, errors: a.errors, serialBaseline: base.metrics, M4_collab: m4c, expectFinal: c.expect.final })
    console.log(c.id.padEnd(48), ['M1', 'M2', 'M3', 'M4', 'M5'].map((k) => `${k}:${a.M[k]}`).join(' '), `M4collab:${m4c}`, `base(M1..M5)=${Object.values(base.metrics).join('')}`, `err=${a.errors}`)
  }
  fs.mkdirSync('out', { recursive: true })
  fs.writeFileSync(opt('out') ?? (calib ? 'out/catalog-A-calib.json' : 'out/catalog-A.json'), JSON.stringify(rows, null, 1))
}

if (cmd === 'storm') {
  const { runStorm } = await import('./storm')
  const { FAST_OFF, FAST_NOLAZY, FAST_NODELTA, FAST_ON } = await import('./sim/fastpath')
  const mode = opt('fast', 'on')
  const cfg = {
    users: Number(opt('users', '10')), nodes: Number(opt('nodes', '500')), durationS: Number(opt('duration', '30')), mix: opt('mix', 'contended') as any,
    seed: Number(opt('seed', '1')), settleS: Number(opt('settle', '45')),
    fast: mode === 'off' ? FAST_OFF : mode === 'nolazy' ? FAST_NOLAZY : mode === 'nodelta' ? FAST_NODELTA : { ...FAST_ON, paranoid: mode === 'paranoid' },
    dragSteps: Number(opt('dragsteps', '6')), focus: opt('focus') ? Number(opt('focus')) : undefined, rafDist: opt('rafdist') ? (JSON.parse(fs.readFileSync(opt('rafdist')!, 'utf8')) as number[]).sort((a, b) => a - b) : undefined, panelLagMs: opt('panellag') ? Number(opt('panellag')) : undefined, lambda: opt('lambda') ? Number(opt('lambda')) : undefined, hotShare: opt('hotshare') ? Number(opt('hotshare')) : undefined, hotNodes: opt('hotnodes') ? Number(opt('hotnodes')) : undefined, linkMs: opt('lat') ? [Number(opt('lat')), Number(opt('lat'))] as [number, number] : undefined, observers: Number(opt('observers', '3')), joinStaggerMs: Number(opt('stagger', '150')),
  }
  const { out, fingerprint } = await runStorm(cfg)
  const file = opt('out')
  if (file) fs.writeFileSync(file, JSON.stringify({ out, fingerprint }, null, 1))
  if (opt('json')) console.log(JSON.stringify({ out, fingerprint }))
  else console.log(JSON.stringify(out, null, 1).slice(0, 6000))
}

if (cmd === 'digests') {
  // one JSON line per run: used to compare optimisation modes (SIM_FAST=off|nolazy|on) on scenarios + catalog cases
  const { generateCases } = await import('./catalog/cases')
  const { runCase } = await import('./catalog/runcase')
  const K = Number(opt('runs', '20'))
  const lines: string[] = []
  for (const sc of SSERIES) for (let s = 1; s <= K; s++) { const { res } = await runOne(sc, s); lines.push(JSON.stringify([sc.id, s, res.metrics, res.detail.draftDigest, res.detail.saves.map((x: any) => x.t + x.by + x.ok).join(','), res.detail.divergence])) }
  for (const c of generateCases()) for (let s = 1; s <= K; s++) { const { res } = await runCase(c, s); lines.push(JSON.stringify([c.id, s, res.metrics, res.detail.draftDigest, res.detail.saves.map((x: any) => x.t + x.by + x.ok).join(','), res.detail.divergence])) }
  fs.writeFileSync(opt('out')!, lines.join('\n') + '\n')
}

if (cmd === 'calib-replay') {
  const { replayFile } = await import('./calib/replay')
  const rafDist = opt('rafdist') ? (JSON.parse(fs.readFileSync(opt('rafdist')!, 'utf8')) as number[]).sort((a, b) => a - b) : undefined
  const rows = await replayFile(opt('in')!, Number(opt('k', '100')), opt('scenario'), rafDist, opt('panellag') ? Number(opt('panellag')) : undefined)
  for (const r of rows) console.log(JSON.stringify(r))
  const n = rows.length
  const realLoss = rows.filter((r) => !['TD', 'oa+ob'].includes(r.real)).length
  console.log('SUMMARY', JSON.stringify({ n, meanPredictedLoss: rows.reduce((a, r) => a + (1 - (r.dist['TD'] ?? r.dist['oa+ob'] ?? 0) / Number(opt('k', '100'))), 0) / n, realLossRate: realLoss / n, meanPReal: rows.reduce((a, r) => a + r.pReal, 0) / n, byteEq: rows.filter((r) => r.byteEq).length, byteChecked: rows.filter((r) => r.byteEq !== null).length }))
}

if (cmd === 'catalog-yaml') {
  const { generateCases } = await import('./catalog/cases')
  const YAML = await import('yaml')
  fs.mkdirSync('catalog', { recursive: true })
  for (const c of generateCases()) {
    const doc = { id: c.id, title: c.title, graph: c.graph, users: c.users, steps: c.steps.map((s) => Object.fromEntries(Object.entries(s).filter(([, v]) => v !== undefined))), faults: c.faults, settle: c.settle, expect: c.expect, repeat: c.repeat, tags: c.tags, jitter_ms: c.jitter_ms }
    fs.writeFileSync(`catalog/${c.id}.yml`, YAML.stringify(doc))
  }
  const { FIXTURES } = await import('./catalog/fixtures')
  fs.mkdirSync('catalog/fixtures', { recursive: true })
  fs.writeFileSync('catalog/fixtures/code-node-basic.yml', YAML.stringify(FIXTURES['code-node-basic']!()))
  console.log('wrote', generateCases().length, 'cases to catalog/')
}
