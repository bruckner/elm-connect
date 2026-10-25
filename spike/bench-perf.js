// Time the tasks of spike/bench-main (Bench.elm), one compiled build or two.
//
//   node spike/bench-perf.js BUILD.js [OTHER.js] [--only REGEX] [--reps 11]
//
// For each task: pick n so one run takes about 20 ms (at most 200,000), warm
// up, then time `init` with n and with 0 alternately, `reps` times each, and
// report (median(n) - median(0)) / n in microseconds per run of the task.
// With two builds, each task is timed on both, alternating, and the checksums
// the two report must agree.
import { readFileSync } from 'node:fs';

const args = process.argv.slice(2);
const builds = args.filter((a, i) => !a.startsWith('--') && !(args[i - 1] || '').startsWith('--'));
const opt = (name, dflt) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : dflt; };
const only = new RegExp(opt('--only', '.'));
const reps = Number(opt('--reps', 11));

function load(path) {
  const scope = {};
  new Function(readFileSync(path, 'utf8')).call(scope);
  return scope.Elm.Bench;
}

function once(program, task, n) {
  let out = null;
  const t0 = performance.now();
  const app = program.init({ flags: { task, n } });
  const t1 = performance.now();
  app.ports.done.subscribe((s) => { out = s; });
  return { ms: t1 - t0, result: () => out };
}

const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const programs = builds.map(load);
const tick = () => new Promise((r) => setTimeout(r, 0));

async function checksum(program, task, n) {
  const r = once(program, task, n);
  await tick();
  return r.result();
}

const allTasks = [
  'check',
  'request.connect.say', 'request.connect.note', 'request.connect.headers', 'request.connectGet.say',
  'request.transcode.get', 'request.transcode.list', 'request.transcode.create',
  'send.connect.say', 'send.connect.note', 'send.transcode.create', 'encode.say', 'encode.createNote',
  'answer.ok.say', 'answer.ok.note', 'answer.ok.note.transcode', 'answer.connectError',
  'answer.connectErrorDetails', 'answer.statusError', 'answer.grpcError', 'answer.httpError',
  'error.toString', 'headers.splitTrailers',
  'json.note.decode', 'json.note.plain', 'json.note.encode', 'json.scalars.decode',
  'json.scalars.decodeSnake', 'json.scalars.decodeEmpty', 'json.scalars.encode', 'json.team.decode',
  'json.team.encode', 'json.labels1000.decode', 'json.labels1000.plain', 'json.event.decode',
  'json.event.encode', 'json.noteEvent.decode', 'json.noteEvent.encode', 'json.forest.decode',
  'json.forest.encode', 'json.notes1000.decode', 'json.notes1000.plain', 'json.notes1000.encode',
  'json.timestamp.decode', 'json.timestamp.fromString', 'json.int64.decode', 'json.parse.note',
  'json.parse.notes1000',
];

const check = await checksum(programs[0], 'check', 1);
if (check !== '0') { console.log(`fixture check failed: ${check}`); process.exit(1); }

const header = builds.length === 2 ? 'task'.padEnd(30) + '      old us      new us   change   n' : 'task'.padEnd(30) + '     us/run        n';
console.log(header);
for (const task of allTasks.filter((t) => t !== 'check' && only.test(t))) {
  // Calibrate on the first build.
  let n = 1;
  for (;;) {
    const ms = once(programs[0], task, n).ms;
    if (ms > 20 || n >= 200000) break;
    n = Math.min(200000, n * (ms < 2 ? 10 : 2));
  }
  for (const p of programs) for (let i = 0; i < 3; i++) { once(p, task, n); once(p, task, 0); }
  const times = programs.map(() => ({ n: [], zero: [] }));
  for (let i = 0; i < reps; i++) {
    programs.forEach((p, k) => { times[k].n.push(once(p, task, n).ms); times[k].zero.push(once(p, task, 0).ms); });
  }
  const us = times.map((t) => 1000 * (median(t.n) - median(t.zero)) / n);
  if (programs.length === 2) {
    const [a, b] = [await checksum(programs[0], task, 3), await checksum(programs[1], task, 3)];
    const change = (100 * (us[1] - us[0]) / us[0]).toFixed(0) + '%';
    console.log(`${task.padEnd(30)} ${us[0].toFixed(3).padStart(11)} ${us[1].toFixed(3).padStart(11)} ${change.padStart(8)} ${String(n).padStart(6)}${a === b ? '' : `  CHECKSUM DIFFERS ${a} ${b}`}`);
  } else {
    console.log(`${task.padEnd(30)} ${us[0].toFixed(3).padStart(11)} ${String(n).padStart(8)}`);
  }
}
