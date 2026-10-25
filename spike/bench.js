// Time Rpc.request over the routes worker (spike/routes-main): each round
// builds one request per binding of every method of tests/Routes (16 calls),
// with a fresh path value per round. The work happens inside `init`, so
// the time around it is the time to build the requests.
//
//   node spike/bench.js OLD.js NEW.js [ROUNDS] [REPEATS]
//
// Runs the two compiled programs alternately, REPEATS times each, and
// prints the median per program and the last round's requests' equality.
import { readFileSync } from 'node:fs';

function load(path) {
  const scope = {};
  new Function(readFileSync(path, 'utf8')).call(scope);
  return scope.Elm.Main;
}

function run(main, rounds) {
  let out = null;
  const t0 = performance.now();
  const app = main.init({ flags: rounds });
  const t1 = performance.now();
  app.ports.done.subscribe((lines) => { out = lines; });
  return { ms: t1 - t0, app, get out() { return out; } };
}

const [oldPath, newPath, roundsArg, repeatsArg] = process.argv.slice(2);
const rounds = Number(roundsArg ?? 625); // 625 rounds x 16 requests = 10,000
const repeats = Number(repeatsArg ?? 15);
const programs = { old: load(oldPath), new: load(newPath) };
// Warm up the JIT on both.
for (const name of Object.keys(programs)) run(programs[name], 200);
const times = { old: [], new: [] };
for (let i = 0; i < repeats; i++) {
  for (const name of ['old', 'new']) times[name].push(run(programs[name], rounds).ms);
}
const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
for (const name of ['old', 'new']) {
  const m = median(times[name]);
  console.log(`${name}: median ${m.toFixed(1)} ms for ${rounds * 16} requests (${(1000 * m / (rounds * 16)).toFixed(2)} us/request), min ${Math.min(...times[name]).toFixed(1)}`);
}
// The last round's requests, compared once the ports have delivered.
const a = run(programs.old, 1), b = run(programs.new, 1);
setTimeout(() => {
  const same = JSON.stringify(a.out) === JSON.stringify(b.out);
  console.log(`same requests: ${same}`);
  if (!same) { console.log('old', a.out); console.log('new', b.out); }
}, 0);
