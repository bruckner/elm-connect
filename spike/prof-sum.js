// Summarise a V8 .cpuprofile by self time, attributing each sampled function
// to the top-level `var`/`function` definition of the compiled Elm file that
// encloses its line (anonymous F2(function ...) bodies included).
//   node spike/prof-sum.js PROFILE.cpuprofile BUILD.js [TOP]
import { readFileSync } from 'node:fs';
const [profPath, buildPath, topArg] = process.argv.slice(2);
const prof = JSON.parse(readFileSync(profPath, 'utf8'));
const lines = readFileSync(buildPath, 'utf8').split('\n');
const owner = [];
let current = '(frame)';
for (let i = 0; i < lines.length; i++) {
  const m = /^(?:var|function) ([A-Za-z0-9_$]+)/.exec(lines[i]);
  if (m) current = m[1];
  owner.push(current);
}
const self = new Map();
const byId = new Map(prof.nodes.map((n) => [n.id, n]));
const counts = new Map();
for (const s of prof.samples) counts.set(s, (counts.get(s) || 0) + 1);
let total = 0;
for (const [id, c] of counts) {
  const node = byId.get(id);
  const f = node.callFrame;
  let key;
  if (f.url && f.url.length > 0 && !f.url.startsWith('node:') && f.lineNumber >= 0 && f.url.includes('prof-run')) key = '(driver)';
  else if (f.url === '' && f.functionName === '') key = `(${f.functionName || 'vm'})`;
  else if (f.url === '' ) key = f.functionName.startsWith('(') ? f.functionName : `native ${f.functionName}`;
  else key = f.url.includes('prof-run') ? '(driver)' : (f.url.startsWith('node:') ? '(node)' : 'elm');
  if (key === 'elm' || (f.url === '' && f.lineNumber >= 0 && f.functionName === '')) {}
  // Code from `new Function` has an empty url; map its line to the definition.
  if (f.url === '' && f.lineNumber >= 0 && !f.functionName.startsWith('(')) {
    // new Function adds two header lines.
    key = (owner[f.lineNumber - 2] || '?').replace('$author$project$', '').replace('$elm$', '');
  }
  self.set(key, (self.get(key) || 0) + c);
  total += c;
}
const top = Number(topArg || 30);
console.log(`samples ${total}`);
for (const [k, v] of [...self].sort((a, b) => b[1] - a[1]).slice(0, top)) {
  console.log(`  ${(100 * v / total).toFixed(1).padStart(5)}%  ${k}`);
}
