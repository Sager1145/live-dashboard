import { PostgresDB } from "./db.js";
import { createApp } from "./api.js";
const db = new PostgresDB(
  process.env.DATABASE_URL ??
    "postgresql://livedash:livedash@localhost:5432/livedash",
);
const app = createApp(db, {
  adminToken: process.env.ADMIN_TOKEN ?? "",
  logger: true,
});
app.addHook("onClose", async () => db.close());
for (const signal of ["SIGINT", "SIGTERM"])
  process.on(signal, () => void app.close());
await app.listen({
  host: process.env.HOST ?? "127.0.0.1",
  port: Number(process.env.PORT ?? 3000),
});
