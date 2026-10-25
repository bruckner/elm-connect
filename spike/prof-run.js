// Run one Bench task many times for a CPU profile:
//   node --cpu-prof --cpu-prof-dir=DIR spike/prof-run.js BUILD.js TASK N REPEATS
import { readFileSync } from 'node:fs';
const [path, task, n, repeats] = process.argv.slice(2);
const scope = {};
new Function(readFileSync(path, 'utf8')).call(scope);
for (let i = 0; i < Number(repeats); i++) scope.Elm.Bench.init({ flags: { task, n: Number(n) } });
