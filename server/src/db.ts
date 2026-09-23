import pg from "pg";
import { readFile, readdir, access } from "node:fs/promises";
import { fileURLToPath } from "node:url";
export interface QueryResult<T = Record<string, any>> {
  rows: T[];
  rowCount?: number | null;
}
export interface DB {
  query<T = Record<string, any>>(
    sql: string,
    values?: any[],
  ): Promise<QueryResult<T>>;
  transaction<T>(fn: (db: DB) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}
export class PostgresDB implements DB {
  private pool: pg.Pool;
  constructor(connectionString: string) {
    this.pool = new pg.Pool({ connectionString, max: 10 });
  }
  async query<T = Record<string, any>>(
    sql: string,
    values: any[] = [],
  ): Promise<QueryResult<T>> {
    const r = await this.pool.query(sql, values);
    return { rows: r.rows, rowCount: r.rowCount };
  }
  async transaction<T>(fn: (db: DB) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      const db: DB = {
        query: async (sql, values = []) => {
          const r = await client.query(sql, values);
          return { rows: r.rows, rowCount: r.rowCount };
        },
        transaction: async (f) => f(db),
        close: async () => {},
      };
      const value = await fn(db);
      await client.query("COMMIT");
      return value;
    } catch (e) {
      await client.query("ROLLBACK");
      throw e;
    } finally {
      client.release();
    }
  }
  async close() {
    await this.pool.end();
  }
}
export async function migrate(db: DB, directory?: string) {
  if (!directory) {
    const source = fileURLToPath(new URL("../db/migrations/", import.meta.url));
    try {
      await access(source);
      directory = source;
    } catch {
      directory = fileURLToPath(
        new URL("../../db/migrations/", import.meta.url),
      );
    }
  }
  await db.query(
    "CREATE TABLE IF NOT EXISTS schema_migrations(version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())",
  );
  for (const name of (await readdir(directory))
    .filter((n) => n.endsWith(".sql"))
    .sort()) {
    await db.transaction(async (tx) => {
      await tx.query("LOCK TABLE schema_migrations IN EXCLUSIVE MODE");
      if (
        (
          await tx.query(
            "SELECT version FROM schema_migrations WHERE version=$1",
            [name],
          )
        ).rows.length
      )
        return;
      await tx.query(await readFile(`${directory}/${name}`, "utf8"));
      await tx.query("INSERT INTO schema_migrations(version) VALUES($1)", [
        name,
      ]);
    });
  }
}
