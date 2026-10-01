'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { loadConfig } = require('../Integrations/local-config.cjs');
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'notch-local-config-'));
try {
  const file = path.join(directory, 'integrations.json');
  assert.equal(loadConfig(file).relayHost, '');
  fs.writeFileSync(file, JSON.stringify({ relayHost: 'linux-relay', deviceNames: { phone_1: 'My phone' } }));
  assert.equal(loadConfig(file).relayHost, 'linux-relay');
  assert.equal(loadConfig(file).deviceNames.get('phone_1'), 'My phone');
  for (const relayHost of ['-oProxyCommand=anything', 'server;command', 'two hosts', 'host\ncommand']) {
    fs.writeFileSync(file, JSON.stringify({ relayHost }));
    assert.throws(() => loadConfig(file), /Invalid SSH relay host/);
  }
  const link = path.join(directory, 'link.json');
  fs.symlinkSync(file, link);
  assert.throws(() => loadConfig(link), /Cannot read/);
  fs.writeFileSync(file, '{invalid json');
  assert.throws(() => loadConfig(file), /Cannot read/);
  console.log('PedroLocalConfigTests passed');
} finally { fs.rmSync(directory, { recursive: true }); }
