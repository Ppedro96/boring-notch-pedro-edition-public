const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { emit, createEvent } = require('../Integrations/notch-notify.cjs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'notch-bridge-test-'));
try {
  const options = { id: '../../escape', title: 'Test', state: 'completed' };
  const a = emit(options, root);
  const files = fs.readdirSync(root);
  assert.equal(files.length, 1);
  assert.match(files[0], /^[a-f0-9]{64}\.json$/);
  const first = fs.readFileSync(path.join(root, files[0]), 'utf8');
  const b = emit(options, root);
  assert.equal(a.revision, b.revision);
  assert.equal(first, fs.readFileSync(path.join(root, files[0]), 'utf8'));
  assert.notEqual(a.revision, emit({ ...options, state: 'waiting' }, root).revision);
  for (const invalid of [{ progress: 'NaN' }, { progress: 101 }, { progress: -1 }, { url: 'file:///etc/passwd' },
    { url: 'https://user:pass@example.com' }, { title: '' }, { kind: 'execute' }, { state: 'approved' }]) {
    assert.throws(() => createEvent({ ...options, ...invalid }));
  }
  assert.equal(fs.statSync(path.join(root, files[0])).mode & 0o777, 0o600);
  console.log('PedroActivityBridgeTests passed');
} finally { fs.rmSync(root, { recursive: true }); }
