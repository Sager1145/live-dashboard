import { readFile } from "node:fs/promises";
import { PostgresDB } from "../src/db.js";
import { createApp } from "../src/api.js";
const config = JSON.parse(
  await readFile("../.runtime/preview-env.json", "utf8"),
);
const db = new PostgresDB(config.databaseURL);
const app = createApp(db, { adminToken: config.adminToken });
app.addHook("onClose", async () => db.close());
for (const signal of ["SIGINT", "SIGTERM"])
  process.on(signal, () => void app.close());
await app.listen({ host: "127.0.0.1", port: 4318 });
console.log("Snapshot preview: http://127.0.0.1:4318");
