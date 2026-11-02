import assert from 'node:assert/strict';
import test from 'node:test';
import { toUpdateFeedEntry } from '../../tools/update_feed_entry.ts';

const row = {
  version: '2.4.0', build: 600,
  url: 'https://github.com/iebb/NekokoLPA2/releases/tag/v2.4.0%2B600',
  data: JSON.stringify({download_url: 'https://example.com/open.apk', signatures: ['community']}),
};

test('release-page column does not replace the public APK download', () => {
  const entry = toUpdateFeedEntry(row);
  assert.equal(entry.download_url, 'https://example.com/open.apk');
  assert.equal(entry.url, row.url);
});

test('legacy rows without a download retain their release-page fallback', () => {
  const entry = toUpdateFeedEntry({...row, data: '{}'});
  assert.equal(entry.download_url, row.url);
});

test('database version wins while signing metadata remains intact', () => {
  const entry = toUpdateFeedEntry({...row, data: JSON.stringify({version: 'old', build: 1, signatures: ['community']})});
  assert.equal(entry.version, '2.4.0');
  assert.equal(entry.build, 600);
  assert.deepEqual(entry.signatures, ['community']);
});
