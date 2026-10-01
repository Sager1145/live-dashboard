import test from 'node:test';
import assert from 'node:assert/strict';
import { dispatchRefresh } from '../refresh-client.js';

test('manual trigger sends token only to the fixed GitHub Actions endpoint', async () => {
  await dispatchRefresh('test-only-token', async (url, options) => {
    assert.equal(url, 'https://api.github.com/repos/Sager1145/live-dashboard/actions/workflows/pages-catalog.yml/dispatches');
    assert.equal(options.headers.Authorization, 'Bearer test-only-token');
    assert.deepEqual(JSON.parse(options.body), { ref: 'main' });
    assert.equal(options.redirect, 'error');
    assert.equal(options.credentials, 'omit');
    return { status: 204 };
  });
});

test('failed trigger never reports success or exposes token in the error', async () => {
  for (const status of [401, 403, 404, 422, 500]) {
    await assert.rejects(dispatchRefresh('test-only-token', async () => ({ status })), (error) => {
      assert.ok(!error.message.includes('test-only-token'));
      return true;
    });
  }
  await assert.rejects(dispatchRefresh('test-only-token', async () => { throw new Error('test-only-token'); }), /无法连接 GitHub/);
});
