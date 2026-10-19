#!/usr/bin/env python3
"""SSH/stdio coordinator. Each authenticated SSH invocation fixes its peer identity."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
from pathlib import Path
import sys
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from continuity_store import Store, TOPICS, ACTIONS, FRAME, identifier

DESK_COMMANDS = frozenset(('status', 'capabilities', 'search', 'submit', 'jobs', 'list', 'job', 'cancel', 'archive', 'retry', 'result', 'retrieve', 'download', 'deskflow', 'input_status', 'input_start', 'input_stop', 'input_home', 'input_layout', 'input_mode'))

class Session:
    def __init__(self, root, peer, emit):
        self.store = Store(root)
        self.peer = identifier(peer, 'peer')
        self.session = uuid.uuid4().hex
        self.emit = emit
        self.watched = {}
        self.lock = threading.RLock()
        self.closed = threading.Event()
        self.broker_lock = threading.Lock()
        self.broker = None
        self.consumer = False
        self.last_revision = -1
        self.next_heartbeat = 0.0
        self.next_cleanup = 0.0
        with self.store.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS sessions(peer TEXT PRIMARY KEY,id TEXT,heartbeat REAL)')

        self.poller = threading.Thread(target=self._poll, daemon=True)
        self.poller.start()

    def _register_consumer(self):
        # Query-only one-shot sessions must never steal the native media consumer.
        if not self.consumer:
            with self.store.db() as db:
                db.execute('BEGIN IMMEDIATE')
                db.execute('DELETE FROM commands WHERE target=? AND ack IS NULL', (self.peer,))
                db.execute('INSERT OR REPLACE INTO sessions VALUES(?,?,?)', (self.peer, self.session, time.time()))
            self.consumer = True

    def _poll_once(self):
        with self.lock:
            if self.watched:
                with self.store.db() as db:
                    revision = db.execute('SELECT value FROM revision').fetchone()[0]
                    if revision != self.last_revision:
                        revisions = dict(db.execute('SELECT topic,MAX(revision) FROM items GROUP BY topic').fetchall())
                    else:
                        revisions = {}
                self.last_revision = revision
                for topic, previous in list(self.watched.items()):
                    if revisions.get(topic, 0) <= previous:
                        continue
                    snapshot = self.store.snapshot(topic)
                    self.watched[topic] = snapshot['revision']
                    with self.store.db() as db:
                        replayed = bool(db.execute('SELECT 1 FROM changes WHERE topic=? AND revision>? AND revision<=? AND replayed=1 LIMIT 1', (topic, previous, snapshot['revision'])).fetchone())
                        changes = db.execute('SELECT DISTINCT key FROM changes WHERE topic=? AND revision>? AND revision<=?', (topic, previous, snapshot['revision'])).fetchall()
                        oldest = db.execute('SELECT MIN(revision) FROM changes').fetchone()[0]
                    self.emit(dict(event='snapshot', initial=False, cached=False, replayed=replayed or bool(oldest and previous < oldest - 1), changed=[row[0] for row in changes], **snapshot))
        if not self.consumer:
            return
        tick = time.monotonic()
        heartbeat = tick >= self.next_heartbeat
        cleanup = tick >= self.next_cleanup
        with self.store.db() as db:
            # Idle polls are read-only. Maintain the original 100 ms command
            # cadence, but heartbeat at 2 Hz (well within the 2 s liveness TTL).
            pending = db.execute('SELECT 1 FROM commands WHERE target=? AND session=? AND ack IS NULL AND expires>? LIMIT 1', (self.peer, self.session, time.time())).fetchone()
            if not (heartbeat or cleanup or pending):
                return
            db.execute('BEGIN IMMEDIATE')
            if heartbeat:
                db.execute('UPDATE sessions SET heartbeat=? WHERE peer=? AND id=?', (time.time(), self.peer, self.session))
                self.next_heartbeat = tick + .5
            if cleanup:
                db.execute('DELETE FROM commands WHERE expires<?', (time.time() - 60,))
                self.next_cleanup = tick + 30
            rows = db.execute('SELECT * FROM commands WHERE target=? AND session=? AND ack IS NULL AND expires>? AND EXISTS(SELECT 1 FROM sessions WHERE peer=commands.target AND id=commands.session)', (self.peer, self.session, time.time())).fetchall()
            for row in rows:
                if db.execute('UPDATE commands SET ack=? WHERE id=? AND ack IS NULL', ('delivered', row['id'])).rowcount:
                    self.emit(dict(event='command', commandId=row['id'], target=row['target'], action=row['action'], arguments=json.loads(row['arguments']), expiresAt=row['expires']))

    def _poll(self):
        while not self.closed.wait(.1):
            try:
                self._poll_once()
            except (OSError, ValueError):
                self.closed.set()

    def close(self):
        self.closed.set()
        if self.poller is not threading.current_thread():
            self.poller.join(timeout=2)
        with self.store.db() as db:
            db.execute('DELETE FROM sessions WHERE peer=? AND id=?', (self.peer, self.session))

    def desk(self, request):
        if not isinstance(request, dict) or request.get('command') not in DESK_COMMANDS:
            raise ValueError('desk command not allowed')
        with self.broker_lock:
            if self.broker is None:
                config = self.store.root / 'config.json'
                if not config.is_file() or config.is_symlink():
                    return dict(available=False, error='desk broker unavailable')
                settings = json.loads(config.read_text())
                script = settings.get('broker', {}).get('script')
                if not script:
                    return dict(available=False, error='desk broker unavailable')
                path = Path(script).expanduser()
                if path.is_symlink() or not path.is_file():
                    raise ValueError('invalid broker script')
                spec = importlib.util.spec_from_file_location('continuity_desk_broker', str(path))
                broker = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(broker)
                if not callable(getattr(broker, 'local_main', None)):
                    return dict(available=False, error='desk broker unavailable: local_main missing')
                self.broker = broker
        # Deliberately outside locks: long broker operations cannot block watches.
        return self.broker.local_main(dict(request, _continuityPeer=self.peer, _continuityRoot=str(self.store.root)))

    def request(self, request):
        op = request.get('op')
        if op == 'ping':
            return dict(peer=self.peer)
        if op == 'watch':
            topics = request.get('topics', list(TOPICS))
            if not isinstance(topics, list) or any(t not in TOPICS for t in topics):
                raise ValueError('unknown topic')
            with self.lock:
                if 'media' in topics:
                    self._register_consumer()
                for topic in topics:
                    snapshot = self.store.snapshot(topic)
                    self.watched[topic] = snapshot['revision']
                    self.emit(dict(event='snapshot', initial=True, cached=False, replayed=True, changed=[], **snapshot))
            return dict(topics=topics)
        if op == 'get':
            return dict(initial=True, cached=False, replayed=True, changed=[], **self.store.snapshot(request['topic']))
        if op in ('put', 'patch', 'delete'):
            return self.store.mutate(self.peer, {k: v for k, v in request.items() if k != 'id'})
        if op == 'upload_start':
            return self.store.upload_start(self.peer, request['blob'])
        if op == 'upload_chunk':
            return self.store.upload_chunk(self.peer, request['uploadId'], request['offset'], request['data'])
        if op == 'upload_finish':
            return self.store.upload_finish(self.peer, request['uploadId'])
        if op == 'blob_read':
            return self.store.blob_read(request['blob'], request['offset'])
        if op == 'desk':
            return dict(result=self.desk(request['request']))
        if op == 'send_command':
            target = identifier(request['target'], 'target')
            action = request['action']
            arguments = request.get('arguments', {})
            if action not in ACTIONS or not isinstance(arguments, dict) or len(json.dumps(arguments)) > 4096:
                raise ValueError('invalid command')
            if action == 'seek' and (type(arguments.get('position')) not in (int, float) or not 0 <= arguments['position'] <= 864000):
                raise ValueError('invalid seek position')
            ident = uuid.uuid4().hex
            with self.store.db() as db:
                db.execute('BEGIN IMMEDIATE')
                session = db.execute('SELECT id FROM sessions WHERE peer=? AND heartbeat>?', (target, time.time() - 2)).fetchone()
                if not session:
                    raise ValueError('target unavailable')
                expires = time.time() + 10
                db.execute('INSERT INTO commands VALUES(?,?,?,?,?,?,?,NULL)', (ident, self.peer, target, session['id'], action, json.dumps(arguments), expires))
            return dict(commandId=ident, expiresAt=expires)
        if op == 'ack_command':
            with self.store.db() as db:
                db.execute('BEGIN IMMEDIATE')
                result = db.execute('UPDATE commands SET ack=? WHERE id=? AND target=? AND session=? AND expires>? AND EXISTS(SELECT 1 FROM sessions WHERE peer=commands.target AND id=commands.session)', (json.dumps(dict(ok=bool(request.get('ok')), error=str(request.get('error', ''))[:256])), request['commandId'], self.peer, self.session, time.time()))
                if not result.rowcount:
                    raise ValueError('unknown or expired command')
            return {}
        raise ValueError('unknown operation')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stdio', action='store_true', required=True)
    parser.add_argument('--peer', required=True)
    parser.add_argument('--root', required=True)
    args = parser.parse_args()
    lock = threading.Lock()
    def emit(frame):
        encoded = json.dumps(frame, ensure_ascii=False, allow_nan=False)
        with lock:
            sys.stdout.write(encoded + '\n')
            sys.stdout.flush()
    session = Session(args.root, args.peer, emit)
    slots = threading.BoundedSemaphore(32)
    def process(request):
        ident = request.get('id')
        try:
            identifier(ident, 'request id')
            data = session.request(request)
            emit(dict(data, id=ident, ok=data.get('ok', True)))
        except Exception as error:
            emit(dict(id=ident, ok=False, error=str(error)[:256]))
        finally:
            slots.release()
    try:
        with ThreadPoolExecutor(max_workers=8) as executor:
            while True:
                line = sys.stdin.buffer.readline(FRAME + 1)
                if not line:
                    break
                if len(line) > FRAME or not line.endswith(b'\n'):
                    emit(dict(id=None, ok=False, error='frame too large or incomplete'))
                    break
                try:
                    request = json.loads(line)
                    if not isinstance(request, dict):
                        raise ValueError('request object required')
                    slots.acquire()
                    executor.submit(process, request)
                except (ValueError, UnicodeError):
                    emit(dict(id=None, ok=False, error='invalid JSON frame'))
    finally:
        session.close()

if __name__ == '__main__':
    main()
