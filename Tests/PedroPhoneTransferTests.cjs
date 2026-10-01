'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { Readable } = require('node:stream');
const { validateManifest, receiveFile, JobProgress, quote } = require('../Integrations/kde-file-transfer.cjs');

async function main() {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'notch-phone-test-'));
  try {
    const payload = crypto.randomBytes(1024 * 1024 + 317);
    const digest = crypto.createHash('sha256').update(payload).digest('hex') + '\n';
    const file = path.join(root, "a 'quoted' file.bin");
    const updates = [];
    await receiveFile(Readable.from([payload.subarray(0, 19), payload.subarray(19), Buffer.from(digest)]), file, payload.length, value => updates.push(value));
    assert.deepEqual(await fs.readFile(file), payload);
    assert.equal((await fs.stat(file)).mode & 0o777, 0o600);
    assert.equal(updates.at(-1).bytes, payload.length);
    assert(updates.every(v => v.phase === 'staging'));
    for (const [name, bytes, size] of [['truncated', payload.subarray(0, 10), payload.length], ['bad-hash', Buffer.concat([payload, Buffer.from('0'.repeat(64) + '\n')]), payload.length]]) {
      const target = path.join(root, name);
      await assert.rejects(receiveFile(Readable.from([bytes]), target, size, () => {}));
      await assert.rejects(fs.stat(target), { code: 'ENOENT' });
    }
    const empty = path.join(root, 'empty');
    await receiveFile(Readable.from([crypto.createHash('sha256').digest('hex') + '\n']), empty, 0, () => {});
    assert.equal((await fs.stat(empty)).size, 0);
    const manifest = { id: crypto.randomUUID(), device: 'phone_1', name: "a 'quoted' file.bin", size: payload.length };
    assert.deepEqual(validateManifest(manifest), manifest);
    for (const change of [{ name: '../file' }, { name: 'a\nfile' }, { name: '.' }, { size: -1 }, { device: 'x;whoami' }, { id: '../path' }])
      assert.throws(() => validateManifest({ ...manifest, ...change }));
    assert.equal(quote("a'b"), "'a'\\''b'");

    const tracker = new JobProgress('file', 100, 'S23', value => updates.push(value));
    const message = (member, body, object = '/JobViewServer/1', iface = 'org.kde.JobViewV2') => tracker.message({ path: object, interface: iface, member, body });
    message('setInfoMessage', ['Sending to other device']);
    message('setDescriptionField', [0, 'File', 'file']);
    message('setTotalAmount', [100, 'bytes']);
    assert.equal(tracker.selected, null);
    message('setInfoMessage', ['Sending to S23']);
    assert.equal(tracker.selected, '/JobViewServer/1');
    message('setProcessedAmount', [100, 'bytes']);
    assert.equal(updates.at(-1).phase, 'sending', '100% bytes alone is not completion');
    message('terminate', ['']);
    assert.equal((await tracker.result).phase, 'completed');

    const failure = new JobProgress('file', 100, 'S23', () => {});
    for (const [member, body] of [['setInfoMessage', ['Sending to S23']], ['setDescriptionField', [0, 'File', 'file']], ['setTotalAmount', [100, 'bytes']], ['setError', [2]], ['terminate', ['Disconnected']]])
      failure.message({ path: '/job', interface: 'org.kde.JobViewV2', member, body });
    assert.equal((await failure.result).phase, 'failed');
    const grouped = new JobProgress('file', 100, 'S23', () => {});
    for (const [member, body] of [['setInfoMessage', ['Sending to S23']], ['setDescriptionField', [0, 'File', 'file']], ['setTotalAmount', [100, 'bytes']], ['setTotalAmount', [200, 'bytes']]])
      grouped.message({ path: '/job', interface: 'org.kde.JobViewV2', member, body });
    assert.equal((await grouped.result).phase, 'unknown');
    const v3 = new JobProgress('file', 100, 'S23', () => {});
    const variant = value => ({ value });
    v3.message({ path: '/v3', interface: 'org.kde.JobViewV3', member: 'update', body: [{
      title: variant('Enviando para S23'), descriptionValue1: variant('file'), totalBytes: variant(100), processedBytes: variant(80),
    }] });
    assert.equal(v3.selected, '/v3');
    v3.message({ path: '/v3', interface: 'org.kde.JobViewV3', member: 'terminate', body: [0, '', {}] });
    assert.equal((await v3.result).phase, 'completed');
    console.log('PedroPhoneTransferTests passed: hash, partial cleanup, empty file, names, job matching, real completion, failure and grouped jobs');
  } finally { await fs.rm(root, { recursive: true, force: true }); }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
