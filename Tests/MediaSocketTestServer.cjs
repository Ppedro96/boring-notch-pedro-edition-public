// Local-only player fixture. Uses Node's standard library and fictional credentials.
const http = require('node:http');
const crypto = require('node:crypto');
const sockets = new Set();
const token = 'fixture+a/b?c&d=e';
let song = { title: 'Track A', artist: 'Artist', album: 'Album', isPaused: false, elapsedSeconds: 10, songDuration: 200 };
const stats = { upgrades: 0, rejected: 0, covers: {}, auth: 0 };
let port;
let authDelay = 0;
function frame(text) {
  const body = Buffer.from(text);
  if (body.length < 126) return Buffer.concat([Buffer.from([0x81, body.length]), body]);
  const head = Buffer.alloc(4); head[0] = 0x81; head[1] = 126; head.writeUInt16BE(body.length, 2);
  return Buffer.concat([head, body]);
}
function emit() {
  const data = frame(JSON.stringify({ type: 'PLAYER_INFO', song }));
  for (const socket of sockets) if (!socket.destroyed) socket.write(data);
}
function reply(response, value, code = 200) {
  response.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(value));
}
const server = http.createServer((request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname;
  if (path === '/auth/boringNotch') { stats.auth++; return setTimeout(() => reply(response, { accessToken: token }), authDelay); }
  if (path === '/api/v1/song') return reply(response, song);
  if (path === '/api/v1/like-state') return reply(response, { state: 'LIKE' });
  if (path === '/stats') return reply(response, stats);
  if (path.startsWith('/cover/')) {
    stats.covers[path] = (stats.covers[path] || 0) + 1;
    return setTimeout(() => { if (!response.destroyed) { response.writeHead(200, { 'Cache-Control': 'no-store' }); response.end(path); } }, path.endsWith('slow') ? 350 : 0);
  }
  if (path === '/control') {
    let data = ''; request.on('data', chunk => data += chunk);
    request.on('end', () => {
      const command = JSON.parse(data);
      if (command.authDelay !== undefined) authDelay = command.authDelay;
      if (command.song) { song = { ...song, ...command.song }; emit(); }
      if (command.drop) for (const socket of [...sockets]) socket.destroy();
      reply(response, { ok: true });
    }); return;
  }
  reply(response, {}, 404);
});
server.on('upgrade', (request, socket) => {
  const url = new URL(request.url, 'http://localhost');
  if (url.searchParams.get('token') !== token || request.headers.authorization !== `Bearer ${token}`) {
    stats.rejected++; socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n'); return;
  }
  stats.upgrades++;
  const accept = crypto.createHash('sha1').update(request.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  sockets.add(socket); socket.on('error', () => {}); socket.on('close', () => sockets.delete(socket));
  socket.on('data', data => { if ((data[0] & 15) === 8) socket.end(); });
  socket.write(frame(JSON.stringify({ type: 'PLAYER_INFO', song })));
});
server.listen(0, '127.0.0.1', () => {
  port = server.address().port;
  song.imageSrc = `http://127.0.0.1:${port}/cover/A`;
  process.stdout.write(`${port}\n`);
});
