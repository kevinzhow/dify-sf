// Python-compatible json.dumps(value, sort_keys=True) (default separators ', ' / ': ', ensure_ascii=True),
// needed to reproduce Workflow.unique_hash (api/models/workflow.py:555) = sha256(json.dumps({"graph": graph_dict}, sort_keys=True) + "None").
import { createHash } from 'node:crypto'

function esc(s: string): string {
  let out = '"'
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    const ch = s[i]!
    if (ch === '"') out += '\\"'
    else if (ch === '\\') out += '\\\\'
    else if (ch === '\n') out += '\\n'
    else if (ch === '\r') out += '\\r'
    else if (ch === '\t') out += '\\t'
    else if (ch === '\b') out += '\\b'
    else if (ch === '\f') out += '\\f'
    else if (c < 0x20 || c > 0x7e) out += '\\u' + c.toString(16).padStart(4, '0')
    else out += ch
  }
  return out + '"'
}

function num(n: number): string {
  if (Number.isInteger(n) && Math.abs(n) < 1e16) return String(n)
  // Python float repr: shortest round-trip; exponent form differs from JS for |x|<1e-4 or >=1e16
  let s = String(n)
  if (s.includes('e')) {
    const [m, e] = s.split('e')
    const ev = parseInt(e!, 10)
    s = `${m}e${ev < 0 ? '-' : '+'}${String(Math.abs(ev)).padStart(2, '0')}`
  }
  return s
}

export function pyDumps(v: any): string {
  if (v === null || v === undefined) return 'null'
  switch (typeof v) {
    case 'boolean':
      return v ? 'true' : 'false'
    case 'number':
      return num(v)
    case 'string':
      return esc(v)
    case 'object': {
      if (Array.isArray(v)) return '[' + v.map(pyDumps).join(', ') + ']'
      const keys = Object.keys(v).filter((k) => v[k] !== undefined).sort()
      return '{' + keys.map((k) => esc(k) + ': ' + pyDumps(v[k])).join(', ') + '}'
    }
  }
  return 'null'
}

export function uniqueHash(graph: unknown): string {
  return createHash('sha256').update(pyDumps({ graph }) + 'None').digest('hex')
}
