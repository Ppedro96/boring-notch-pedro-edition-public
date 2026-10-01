'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function loadConfig(filename = path.join(os.homedir(), '.config/pedro-notch/integrations.json')) {
  let config = {};
  try {
    const stat = fs.lstatSync(filename);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 65536 || stat.uid !== process.getuid())
      throw Error('Invalid local integration configuration');
    config = JSON.parse(fs.readFileSync(filename, 'utf8'));
  } catch (error) {
    if (error.code !== 'ENOENT') throw Error('Cannot read local integration configuration');
  }
  const relayHost = typeof config.relayHost === 'string' ? config.relayHost : '';
  if (relayHost && !/^[a-zA-Z0-9_][a-zA-Z0-9_.@:-]{0,253}$/.test(relayHost))
    throw Error('Invalid SSH relay host');
  const names = Object.entries(config.deviceNames || {}).filter(([id, name]) =>
    /^[a-zA-Z0-9_]{1,128}$/.test(id) && typeof name === 'string' && name.length <= 100);
  return { relayHost, deviceNames: new Map(names.slice(0, 100)) };
}
module.exports = { loadConfig };
