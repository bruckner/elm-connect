// node spike/oracle/run.mjs <baseUrl> <scenario>: runs build/oracle.js.
import { createRequire } from "node:module";
import { createStreams } from "../../runtime/stream.js";

const require = createRequire(import.meta.url);
const { Elm } = require("./build/oracle.js");
const [baseUrl, scenario] = process.argv.slice(2);
const app = Elm.Oracle.init({ flags: { baseUrl, scenario } });
const opened = [];
const streams = createStreams((e) => app.ports.streamIn.send(e));
app.ports.streamOut.subscribe((command) => {
  if (command.open) opened.push({ id: command.id, auth: command.open.headers.find(([k]) => k === "Authorization")?.[1], body: command.open.body });
  streams.run(command);
});
app.ports.report.subscribe((r) => {
  console.log(JSON.stringify({ scenario, ...r, opened }, null, 1));
  setTimeout(() => process.exit(0), 50);
});
setTimeout(() => {
  console.log(JSON.stringify({ scenario, timeout: true, opened }));
  process.exit(1);
}, 8000);
