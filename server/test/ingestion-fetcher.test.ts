import assert from "node:assert/strict";
import test from "node:test";
import {
  assertPublicAddresses,
  fetchDocument,
  makeSnapshot,
  normalizeDocumentText,
  validateUrl,
  type SourcePolicy,
} from "../src/ingestion/index.js";

const approved: SourcePolicy = {
  id: "test",
  enabled: true,
  reviewStatus: "approved",
  robotsCheckedAt: "2026-09-22T00:00:00Z",
  termsReviewedAt: "2026-09-22T00:00:00Z",
  host: "example.com",
  allowedPaths: ["/events/"],
  contentTypes: ["text/html"],
};

test("URL policy requires HTTPS, exact host, allowed port, and bounded path", () => {
  assert.equal(
    validateUrl(new URL("https://example.com/events/item?p=1"), approved),
    undefined,
  );
  assert.match(
    validateUrl(new URL("http://example.com/events/"), approved) ?? "",
    /HTTPS/,
  );
  assert.match(
    validateUrl(new URL("https://example.com.evil.test/events/"), approved) ??
      "",
    /outside policy/,
  );
  assert.match(
    validateUrl(new URL("https://example.com/other"), approved) ?? "",
    /allowlist/,
  );
  assert.match(
    validateUrl(new URL("https://example.com:8443/events/"), approved) ?? "",
    /port/,
  );
});

test("address guard rejects private, loopback, metadata, documentation, and mapped IPs", () => {
  for (const address of [
    "127.0.0.1",
    "10.0.0.1",
    "169.254.169.254",
    "192.0.2.1",
  ])
    assert.throws(() => assertPublicAddresses([{ address, family: 4 }]));
  for (const address of ["::1", "fe80::1", "2001:db8::1", "::ffff:127.0.0.1"])
    assert.throws(() => assertPublicAddresses([{ address, family: 6 }]));
  assert.doesNotThrow(() =>
    assertPublicAddresses([{ address: "93.184.216.34", family: 4 }]),
  );
});

test("disabled and pending policies never reach DNS or transport", async () => {
  let called = false;
  const outcome = await fetchDocument({
    url: "https://example.com/events/",
    sourceDocumentId: "doc",
    policy: { ...approved, enabled: false, reviewStatus: "pending_review" },
    resolveAddresses: async () => {
      called = true;
      return [{ address: "93.184.216.34", family: 4 }];
    },
  });
  assert.equal(outcome.status, "blocked");
  assert.equal(called, false);
});

test("snapshot hashes raw bytes and normalized text independently", () => {
  const one = makeSnapshot({
    sourceDocumentId: "one",
    fetchUrl: "https://example.com/events/a",
    finalUrl: "https://example.com/events/a",
    statusCode: 200,
    headers: {},
    body: Buffer.from("<html>  A\r\nB </html>"),
  });
  const two = makeSnapshot({
    sourceDocumentId: "two",
    fetchUrl: "https://example.com/events/a",
    finalUrl: "https://example.com/events/a",
    statusCode: 200,
    headers: {},
    body: Buffer.from("<html> A\nB </html>"),
  });
  assert.notEqual(one.rawSha256, two.rawSha256);
  assert.equal(one.normalizedSha256, two.normalizedSha256);
  assert.equal(normalizeDocumentText("a  b\r\n\r\n\r\nc"), "a b\n\nc");
});

test("304, 403, and 429 retain the previous snapshot without fabricating an empty one", async () => {
  const previous = makeSnapshot({
    sourceDocumentId: "doc",
    fetchUrl: "https://example.com/events/a",
    finalUrl: "https://example.com/events/a",
    statusCode: 200,
    headers: { etag: '"v1"' },
    body: Buffer.from("<!doctype html><html><main>known good</main></html>"),
  });
  const base = {
    url: previous.fetchUrl,
    sourceDocumentId: "doc",
    policy: approved,
    previousSnapshot: previous,
    resolveAddresses: async () => [
      { address: "93.184.216.34", family: 4 as const },
    ],
  };
  const unchanged = await fetchDocument({
    ...base,
    transport: async () => ({
      statusCode: 304,
      headers: {},
      body: Buffer.alloc(0),
    }),
  });
  assert.equal(unchanged.status, "unchanged");
  if (unchanged.status === "unchanged")
    assert.equal(unchanged.snapshot.id, previous.id);
  const forbidden = await fetchDocument({
    ...base,
    transport: async () => ({
      statusCode: 403,
      headers: {},
      body: Buffer.from("Forbidden"),
    }),
  });
  assert.equal(forbidden.status, "blocked");
  if (forbidden.status === "blocked")
    assert.equal(forbidden.lastKnownSnapshot?.id, previous.id);
  const limited = await fetchDocument({
    ...base,
    transport: async () => ({
      statusCode: 429,
      headers: { "retry-after": "120" },
      body: Buffer.alloc(0),
    }),
  });
  assert.equal(limited.status, "rate_limited");
  if (limited.status === "rate_limited") {
    assert.equal(limited.retryAfter, "120");
    assert.equal(limited.lastKnownSnapshot?.id, previous.id);
  }
});

test("every redirect is rechecked and cross-origin redirects are rejected before transport", async () => {
  let calls = 0;
  const result = await fetchDocument({
    url: "https://example.com/events/a",
    sourceDocumentId: "doc",
    policy: approved,
    resolveAddresses: async () => [{ address: "93.184.216.34", family: 4 }],
    transport: async () => {
      calls += 1;
      return {
        statusCode: 302,
        headers: { location: "https://evil.example/events/a" },
        body: Buffer.alloc(0),
      };
    },
  });
  assert.equal(result.status, "blocked");
  assert.equal(calls, 1);
  if (result.status === "blocked")
    assert.match(result.issue, /redirect rejected/);
});
