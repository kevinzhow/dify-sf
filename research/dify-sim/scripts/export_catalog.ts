// Writes the A-tier catalog cases (src/catalog/cases.ts) as JSON for the dify-sf executor, so both sides run the same cases.
import fs from 'node:fs'
import { generateCases } from '../src/catalog/cases'
const out = process.argv[2] ?? 'out/A-cases.json'
fs.writeFileSync(out, JSON.stringify({ source: 'difysim src/catalog/cases.ts (CATALOG.md section 3, tier A)', cases: generateCases() }, null, 1))
console.log(`wrote ${generateCases().length} cases to ${out}`)
