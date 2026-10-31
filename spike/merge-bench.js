// Measurement 3: binary decode time of two builds of codec-harness's Bench,
// today's generated merges (A) against the table form (B), interleaved: for
// each input set the two programs run in turn, ROUNDS rounds per timing,
// REPEATS timings per program per pass, PASSES passes alternating which
// goes first; it prints the median per input of each and B / A. Before
// timing it checks that both decode every input alike (each decoded input
// encoded again gives the same bytes in both).
//
//   node spike/merge-bench.js A.js B.js [ROUNDS] [REPEATS] [PASSES]
//
// Driver shape (go port, time around the send) from the codec spike's
// codec-bench2.js; vanilla JS, one process.
import { readFileSync } from 'node:fs';

const [aPath, bPath, roundsArg, repeatsArg, passesArg] = process.argv.slice(2);
const rounds = Number(roundsArg ?? 50);
const repeats = Number(repeatsArg ?? 11);
const passes = Number(passesArg ?? 4);

function load(path) {
  const scope = {};
  new Function(readFileSync(path, 'utf8')).call(scope);
  return scope.Elm.Bench;
}
const programs = { A: load(aPath), B: load(bPath) };

async function start(Bench, message, large) {
  const app = Bench.init({ flags: { message, large } });
  await new Promise((resolve) => setTimeout(resolve, 0));
  let out = null;
  let t1 = 0;
  let resolveRun = null;
  const finish = (x) => {
    t1 = performance.now();
    out = x;
    if (resolveRun) resolveRun();
  };
  app.ports.done.subscribe(finish);
  app.ports.texts.subscribe(finish);
  return {
    async run(mode, r) {
      await new Promise((resolve) => setImmediate(resolve));
      out = null;
      const answered = new Promise((resolve) => { resolveRun = resolve; });
      const t0 = performance.now();
      app.ports.go.send({ mode, rounds: r });
      if (out === null) await answered;
      resolveRun = null;
      if (out === -1) throw new Error(`${mode}: unknown mode`);
      return { ms: t1 - t0, out };
    },
  };
}

const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const large = JSON.stringify({
  leaves: Array.from({ length: 1000 }, (_, i) => ({ name: `leaf-${i}`, count: i * 7 })),
});

async function row(label, message, largeInput, r) {
  const apps = {
    A: await start(programs.A, message, largeInput),
    B: await start(programs.B, message, largeInput),
  };
  const ra = (await apps.A.run('roundTrip', 0)).out;
  const rb = (await apps.B.run('roundTrip', 0)).out;
  if (JSON.stringify(ra) !== JSON.stringify(rb) || ra.some((x) => x === 'FAIL')) {
    throw new Error(`${label}: the two builds decode differently`);
  }
  const n = ra.length;
  const times = { A: [], B: [] };
  for (const k of ['A', 'B']) await apps[k].run('decodeBinary', 2); // warm up
  for (let p = 0; p < passes; p++) {
    const order = p % 2 ? ['B', 'A'] : ['A', 'B'];
    for (const k of order) {
      for (let i = 0; i < repeats; i++) {
        const res = await apps[k].run('decodeBinary', r);
        if (res.out !== n * r) throw new Error(`${label}: ${k} decoded ${res.out} of ${n * r}`);
        times[k].push((1000 * res.ms) / (r * n));
      }
    }
  }
  const a = median(times.A);
  const b = median(times.B);
  // spread: the medians of each pass, min–max
  const perPass = (xs) => Array.from({ length: passes }, (_, p) => median(xs.slice(p * repeats, (p + 1) * repeats)));
  const spread = (xs) => { const m = perPass(xs); return `${Math.min(...m).toFixed(2)}–${Math.max(...m).toFixed(2)}`; };
  console.log(`| ${label} | ${n} | ${a.toFixed(2)} (${spread(times.A)}) | ${b.toFixed(2)} (${spread(times.B)}) | ${((100 * (b - a)) / a).toFixed(1)} % |`);
}

console.log(`rounds ${rounds}, repeats ${repeats}, passes ${passes}, node ${process.version}`);
console.log('| inputs | n | A decode µs/input (pass medians) | B decode µs/input (pass medians) | B vs A |');
console.log('|---|---:|---:|---:|---:|');
const messages = ['*', 'codec.v1.Scalars', 'codec.v1.Optionals', 'codec.v1.Repeated', 'codec.v1.Maps', 'codec.v1.Choice', 'codec.v1.Names', 'codec.v1.Outer', 'codec.v1.Tree', 'codec.v1.WellKnown', 'codec.v1.Wrappers', 'codec.v1.Across', 'codec.v1.Leaf', 'codec.v1.Everything'];
for (const m of messages) await row(m === '*' ? 'corpus, all' : m, m, '', rounds);
await row('Repeated, 1,000 leaves', '*', large, Math.max(1, Math.floor(rounds / 10)));
