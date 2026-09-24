import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createApp } from "../src/api.js";
import { testDB } from "./support.js";

const adminToken = "test-only-admin-secret-at-least-24-characters";

test("admin GUI can pause scraping, select a network, and queue approved documents", async () => {
  const db = await testDB();
  const app = createApp(db, { adminToken });
  const previousChoices = process.env.API_NETWORK_CHOICES;
  process.env.API_NETWORK_CHOICES = "127.0.0.1,192.168.1.25";
  const headers = { authorization: `Bearer ${adminToken}` };
  try {
    const page = await app.inject({ url: "/admin/settings", headers });
    assert.equal(page.statusCode, 200);
    assert.match(page.body, /192\.168\.1\.25/);
    const pause = await app.inject({
      method: "POST", url: "/admin/settings/scraping", headers,
      payload: { enabled: "false", reason: "Pause maintenance" },
    });
    assert.equal(pause.statusCode, 200);
    assert.equal((await db.query("SELECT value FROM app_settings WHERE key='scraping_enabled'")).rows[0].value, false);
    const network = await app.inject({
      method: "POST", url: "/admin/settings/network", headers,
      payload: { bindIP: "192.168.1.25", reason: "Use the LAN interface" },
    });
    assert.equal(network.statusCode, 200);
    assert.equal(network.json().requiresDeploy, true);
    assert.equal((await db.query("SELECT value FROM app_settings WHERE key='preferred_bind_ip'")).rows[0].value, "192.168.1.25");
    assert.equal((await app.inject({
      method: "POST", url: "/admin/settings/network", headers,
      payload: { bindIP: "8.8.8.8", reason: "Invalid address" },
    })).statusCode, 422);

    const origin = randomUUID();
    const doc = randomUUID();
    await db.query("INSERT INTO source_origins(id,origin,policy) VALUES($1,$2,$3)", [
      origin, "https://example.org", JSON.stringify({ enabled: true, reviewStatus: "approved" }),
    ]);
    await db.query("INSERT INTO source_documents(id,origin_id,fetch_url,identity_url,enabled) VALUES($1,$2,$3,$3,true)", [
      doc, origin, "https://example.org/event",
    ]);
    const queued = await app.inject({
      method: "POST", url: `/admin/documents/${doc}/fetch`, headers,
      payload: { reason: "Check the updated event" },
    });
    assert.equal(queued.statusCode, 200);
    assert.equal((await db.query("SELECT kind,status FROM jobs WHERE id=$1", [queued.json().jobID])).rows[0].kind, "fetch");
  } finally {
    if (previousChoices === undefined) delete process.env.API_NETWORK_CHOICES;
    else process.env.API_NETWORK_CHOICES = previousChoices;
    await app.close();
    await db.close();
  }
});
