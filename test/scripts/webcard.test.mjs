import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import vm from 'node:vm';

const source = readFileSync(new URL('../../web/webcard.js', import.meta.url), 'utf8');
function webcard({ installed = true, respond, crypto = webcrypto } = {}) {
  const context = {
    console: { info() {} }, navigator: { userAgent: 'test Windows NT' },
    document: { getElementById: () => installed ? {} : null },
    setTimeout: (fn) => setTimeout(fn, 15),
    window: {
      crypto, location: { origin: 'https://fixture.invalid' }, addEventListener() {},
      postMessage(request) {
        if (respond) queueMicrotask(() => context.navigator.webcard.responseCallback(respond(request)));
      },
    },
  };
  vm.runInNewContext(source, context);
  return context.navigator.webcard;
}

test('version response resolves without breaking later reader requests', async () => {
  const requests = [];
  const card = webcard({ respond(request) {
    requests.push(request);
    return request.c === 10
      ? { i: request.i, verExt: '0.4.1', verNat: '0.4.2' }
      : { i: request.i, d: [{ n: 'Fixture SIM reader', a: '3B00' }] };
  } });
  const versions = await card.getVersions();
  assert.equal(versions.addon, '0.4.1');
  assert.equal(versions.app, '0.4.2');
  const readers = await card.readers();
  assert.equal(readers[0].name, 'Fixture SIM reader');
  assert.notEqual(requests[0].i, requests[1].i);
  assert.equal(card.pendingRequests.size, 0);
});

test('absent extension returns disabled status rather than rejecting', async () => {
  const versions = await webcard({ installed: false }).getVersions();
  assert.equal(versions.addon, 'EXTENSION DISABLED');
  assert.equal(versions.app, 'EXTENSION DISABLED');
});

test('synchronous UUID failure is contained by version-query fallback', async () => {
  const versions = await webcard({ crypto: { randomUUID() { throw new Error('unavailable'); } } }).getVersions();
  assert.equal(versions.app, 'EXTENSION DISABLED');
});

test('timeout clears its pending request and ignores a late version reply', async () => {
  let request;
  const card = webcard({ respond(value) { request = value; return { i: 'unmatched' }; } });
  const versions = await card.getVersions();
  assert.equal(versions.app, '?');
  assert.equal(card.pendingRequests.size, 0);
  card.responseCallback({ i: request.i, verNat: 'late' });
  assert.equal(versions.app, '?');
});
