#!/usr/bin/env node
// The live runner: drives the compiled Elm program (src/Live.elm) from Node,
// over its ports, against a running server.
//
// As a module:
//
//   import { createRunner } from "./run.mjs";
//   const runner = await createRunner({ elm: "build/elm.js" });
//   const result = await runner.call({ id, service, method, request, transport, config, binding });
//
// As a command, it runs a case file in order and checks each result against
// the case's expectations, exiting non-zero on a mismatch:
//
//   node run.mjs --server http://127.0.0.1:8080 cases/notes.json
//   node run.mjs --serve path/to/server cases/notes.json   # starts it on a free port
//   node run.mjs --serve path/to/server --prefix /gateway --transport transcode cases/notes.json
//
// --prefix runs the cases against the server's base URL with the prefix
// added (grpc-gateway's, under /gateway), and --transport only the cases
// sent over that transport.
//
// Formats: conformance/README.md, "Live verification".

import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { makeXMLHttpRequest } from "./xhr.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));

// Load the compiled program and start it. Calls are sent one at a time, so
// every HTTP exchange made while a call is in flight belongs to it and is
// reported with its result as `wire`.
export async function createRunner({ elm = path.join(here, "build", "elm.js") } = {}) {
  let exchanges = null;
  globalThis.XMLHttpRequest = makeXMLHttpRequest((exchange) => exchanges?.push(exchange));

  const source = await readFile(elm, "utf8");
  const scope = {};
  // The compiled program assigns `this.Elm`.
  new Function(source).call(scope);
  const app = scope.Elm.Live.init();

  const pending = new Map();
  app.ports.results.subscribe((result) => {
    const resolve = pending.get(result.id);
    if (resolve) {
      pending.delete(result.id);
      resolve(result);
    }
  });

  let queue = Promise.resolve();
  function call(envelope) {
    const run = queue.then(
      () =>
        new Promise((resolve) => {
          exchanges = [];
          pending.set(envelope.id, (result) => {
            const wire = exchanges;
            exchanges = null;
            resolve({ ...result, wire });
          });
          app.ports.requests.send(envelope);
        }),
    );
    queue = run.catch(() => {});
    return run;
  }
  return { call };
}

// Does `actual` match `expected`? Objects match when every key of the
// expectation matches (other keys are ignored), arrays element by element
// with the same length, anything else by equality. Special objects:
// {"$contains": [...]} an array holding a match for each element,
// {"$match": "regex"} a string the regular expression finds,
// {"$json": expected} a string whose JSON parse matches, and
// {"$absent": true} a key that is missing or null.
// Gives the mismatches as [path, expected, actual].
export function mismatches(expected, actual, at = "$") {
  if (expected !== null && typeof expected === "object" && !Array.isArray(expected)) {
    if ("$contains" in expected) {
      if (!Array.isArray(actual)) return [[at, expected, actual]];
      return expected.$contains.flatMap((want, i) =>
        actual.some((have) => mismatches(want, have).length === 0) ? [] : [[`${at} contains[${i}]`, want, actual]],
      );
    }
    if ("$match" in expected) {
      return typeof actual === "string" && new RegExp(expected.$match).test(actual) ? [] : [[at, expected, actual]];
    }
    if ("$json" in expected) {
      let parsed;
      try {
        parsed = JSON.parse(actual);
      } catch {
        return [[at, expected, actual]];
      }
      return mismatches(expected.$json, parsed, `${at} (JSON)`);
    }
    if ("$absent" in expected) {
      return actual === undefined || actual === null ? [] : [[at, expected, actual]];
    }
    if (actual === null || typeof actual !== "object" || Array.isArray(actual)) return [[at, expected, actual]];
    return Object.entries(expected).flatMap(([key, want]) => mismatches(want, actual[key], `${at}.${key}`));
  }
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || actual.length !== expected.length) return [[at, expected, actual]];
    return expected.flatMap((want, i) => mismatches(want, actual[i], `${at}[${i}]`));
  }
  return expected === actual ? [] : [[at, expected, actual]];
}

// Start a server binary on a free port; resolves to its base URL and a stop
// function once it prints "listening on <url>".
export function serve(binary) {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, ["-addr", "127.0.0.1:0"], { stdio: ["ignore", "pipe", "inherit"] });
    child.on("error", reject);
    child.on("exit", (code) => reject(new Error(`${binary} exited with ${code} before listening`)));
    const lines = createInterface({ input: child.stdout });
    lines.on("line", (line) => {
      const found = /^listening on (\S+)/.exec(line);
      if (found) {
        child.removeAllListeners("exit");
        const stop = () =>
          new Promise((done) => {
            child.on("exit", done);
            child.kill("SIGTERM");
          });
        resolve({ url: found[1], stop });
      }
    });
  });
}

// The envelope of a case: its call with the case's name as id, and baseUrl
// as the config's baseUrl unless the case gives one, in which "{server}"
// stands for the server's URL, without baseUrl's prefix: the canned answers
// (/status/, /grpc-status/) are the server's, under no transcoder.
export function envelopeOf(c, baseUrl, server = baseUrl) {
  const config = { ...(c.call.config ?? {}) };
  config.baseUrl = config.baseUrl === undefined ? baseUrl : config.baseUrl.replaceAll("{server}", server);
  return { id: c.name, ...c.call, config };
}

// Run the cases of a file in order against baseUrl, the server's URL with
// a transcoder's prefix if any (envelopeOf). Each case is
// {name, note?, call, expect, skip?}.
export async function runCases(runner, cases, baseUrl, { log = console.log, server = baseUrl } = {}) {
  const failed = [];
  for (const c of cases) {
    if (c.skip) {
      log(`skip  ${c.name}: ${c.skip}`);
      continue;
    }
    const result = await runner.call(envelopeOf(c, baseUrl, server));
    const problems = mismatches(c.expect ?? {}, result);
    if (problems.length === 0) {
      log(`ok    ${c.name}`);
    } else {
      failed.push(c.name);
      log(`FAIL  ${c.name}`);
      for (const [where, want, have] of problems) {
        log(`        at ${where}\n          expected ${JSON.stringify(want)}\n          actual   ${JSON.stringify(have)}`);
      }
      log(`        result ${JSON.stringify(result)}`);
    }
  }
  return failed;
}

async function main(argv) {
  const args = { files: [], prefix: "" };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--server") args.server = argv[++i];
    else if (arg === "--serve") args.serve = argv[++i];
    else if (arg === "--elm") args.elm = argv[++i];
    else if (arg === "--print") args.print = true;
    else if (arg === "--prefix") args.prefix = argv[++i];
    else if (arg === "--transport") args.transport = argv[++i];
    else args.files.push(arg);
  }
  if ((!args.server && !args.serve) || args.files.length === 0) {
    console.error("usage: run.mjs (--server URL | --serve BINARY) [--elm build/elm.js] [--prefix /PATH] [--transport T] [--print] CASES.json ...");
    process.exit(2);
  }
  const server = args.serve ? await serve(args.serve) : { url: args.server, stop: async () => {} };
  let failed = [];
  try {
    const runner = await createRunner({ elm: args.elm });
    for (const file of args.files) {
      const cases = JSON.parse(await readFile(file, "utf8")).filter((c) => !args.transport || c.call.transport === args.transport);
      const baseUrl = server.url + args.prefix;
      if (args.print) {
        for (const c of cases.filter((c) => !c.skip)) {
          const result = await runner.call(envelopeOf(c, baseUrl, server.url));
          console.log(JSON.stringify(result));
        }
      } else {
        failed = failed.concat(await runCases(runner, cases, baseUrl, { server: server.url }));
      }
    }
  } finally {
    await server.stop();
  }
  if (failed.length > 0) {
    console.error(`\n${failed.length} case(s) failed: ${failed.join(", ")}`);
    process.exit(1);
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main(process.argv.slice(2));
}
