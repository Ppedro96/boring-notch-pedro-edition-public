#!/usr/bin/env python3
"""Native NDJSON bridge and importable Client/one_shot API; stdlib only.

Configuration is disabled unless enabled:true. server.ssh is an argv list
(e.g. ["ssh", "private-alias"]), with server.script, server.root and optional
server.python. server.argv supplies the complete transport argv for local use.
Only trusted configuration enters SSH's remote command; requests/files use stdin.
"""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import shlex
import sqlite3
import subprocess
import sys
import threading
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from continuity_store import CHUNK, FRAME, TOPICS, ClosingConnection, validate_payload, identifier, private_dir, regular_open, validate_blob, verified, name

MUTATIONS = frozenset(('put', 'patch', 'delete'))

class Unavailable(Exception):
    pass

class RemoteError(Exception):
    pass

class Client:
    def __init__(self, config, on_event=None):
        if isinstance(config, (str, Path)):
            path = Path(config).expanduser()
            self.config = json.loads(path.read_text()) if path.is_file() else {}
        else:
            self.config = dict(config)
        self.enabled = self.config.get('enabled') is True
        self.peer = self.config.get('peer', 'local')
        self.on_event = on_event or (lambda event: None)
        self.stop = threading.Event()
        self.connected = threading.Event()
        self.lock = threading.RLock()
        self.watch_lock = threading.RLock()
        self.mutation_lock = threading.RLock()
        self.pending = {}
        self.topics = []
        self.watch_id = None
        self.child = None
        self.thread = None
        self.cache_root = None
        if self.enabled:
            self.cache_root = private_dir(self.config.get('cache', '~/.local/share/insight-notch/continuity'))
            self.blobs = private_dir(self.cache_root / 'blobs')
            self.database = self.cache_root / 'cache.sqlite3'
            if self.database.is_symlink():
                raise ValueError('symlink database')
            with self.db() as db:
                db.executescript('CREATE TABLE IF NOT EXISTS snapshots(topic TEXT PRIMARY KEY,value TEXT); CREATE TABLE IF NOT EXISTS outbox(id TEXT PRIMARY KEY,value TEXT,created REAL); CREATE TABLE IF NOT EXISTS consumed(id TEXT PRIMARY KEY,created REAL); CREATE TABLE IF NOT EXISTS intents(id TEXT PRIMARY KEY,fingerprint TEXT,expected INTEGER,parent TEXT); CREATE TABLE IF NOT EXISTS conflicts(id TEXT PRIMARY KEY,value TEXT,error TEXT,created REAL);')
            self.database.chmod(0o600)
            self.thread = threading.Thread(target=self._connect, daemon=True)
            self.thread.start()
        else:
            self._emit(dict(event='connection', state='disabled'))

    def db(self):
        return sqlite3.connect(str(self.database), timeout=15, factory=ClosingConnection)

    def _emit(self, event):
        try:
            if event.get('event') == 'snapshot':
                event = dict(event, watchId=self.watch_id)
            self.on_event(event)
        except Exception:
            pass  # A UI callback must never kill transport/storage.

    def _argv(self):
        server = self.config.get('server', {})
        if 'argv' in server:
            argv = server['argv']
        else:
            ssh = server.get('ssh', [])
            if not isinstance(ssh, list) or not ssh:
                raise ValueError('server.ssh argv required')
            remote = [server.get('python', 'python3'), server['script'], '--stdio', '--peer', self.peer, '--root', server['root']]
            argv = ssh + [' '.join(shlex.quote(str(value)) for value in remote)]
        if not isinstance(argv, list) or not argv or any(not isinstance(v, str) or '\0' in v for v in argv):
            raise ValueError('invalid transport argv')
        return argv

    def _connect(self):
        delay = .2
        while not self.stop.is_set():
            self._emit(dict(event='connection', state='connecting'))
            try:
                child = subprocess.Popen(self._argv(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=-1)
                with self.lock:
                    self.child = child
                threading.Thread(target=self._drain, args=(child.stderr,), daemon=True).start()
                reader = threading.Thread(target=self._read, args=(child,), daemon=True)
                reader.start()
                with self.mutation_lock:
                    self.connected.set()
                    self._rpc(dict(op='ping'), timeout=5)
                    with self.watch_lock:
                        if self.topics:
                            self._rpc(dict(op='watch', topics=self.topics))
                    with self.db() as db:
                        rows = db.execute('SELECT id,value FROM outbox ORDER BY created,id').fetchall()
                    replayed_topics = set()
                    for ident, value in rows:
                        request = json.loads(value)
                        replayed_topics.add(request['topic'])
                        request['replayed'] = True
                        try:
                            self._rpc(request)
                        except RemoteError as error:
                            with self.db() as db:
                                db.execute('BEGIN IMMEDIATE')
                                db.execute('INSERT OR REPLACE INTO conflicts VALUES(?,?,?,?)', (ident, value, str(error)[:256], time.time()))
                                db.execute('DELETE FROM outbox WHERE id=?', (ident,))
                            self._emit(dict(event='mutation_error', mutationId=ident, error=str(error)[:256], recoverable=True))
                        else:
                            with self.db() as db:
                                db.execute('DELETE FROM outbox WHERE id=?', (ident,))
                                db.execute('DELETE FROM conflicts WHERE id=?', (ident,))
                    for topic in replayed_topics:
                        self._cache_authoritative(self._rpc(dict(op='get', topic=topic)))
                        view, queued = self._view(topic)
                        self._emit(dict(view, event='snapshot', initial=False, cached=queued, replayed=True, queued=queued, changed=[]))
                self._emit(dict(event='connection', state='online'))
                delay = .2
                while not self.stop.wait(.1) and child.poll() is None and reader.is_alive():
                    pass
            except Exception as error:
                self._emit(dict(event='connection', state='offline', error=str(error)[:256]))
            finally:
                self.connected.clear()
                with self.lock:
                    child = self.child
                    self.child = None
                    for pending in self.pending.values():
                        pending.put(None)
                if child:
                    self._terminate(child)
            if not self.stop.is_set():
                self._emit(dict(event='connection', state='offline'))
                self.stop.wait(delay)
                delay = min(delay * 2, 5)

    def _drain(self, stream):
        try:
            while stream.read(4096):
                pass
        except OSError:
            pass

    def _read(self, child):
        try:
            while not self.stop.is_set():
                raw = child.stdout.readline(FRAME + 1)
                if not raw or len(raw) > FRAME or not raw.endswith(b'\n'):
                    break
                frame = json.loads(raw)
                if frame.get('event') == 'snapshot':
                    current, accepted = self._cache_authoritative(frame)
                    if accepted:
                        view, queued = self._view(frame['topic'])
                        self._emit(dict(view, event='snapshot', initial=bool(frame.get('initial')), cached=queued, replayed=queued or bool(frame.get('replayed')), queued=queued, changed=frame.get('changed', [])))
                elif frame.get('event') == 'command':
                    if frame.get('target') != self.peer or frame.get('expiresAt', 0) <= time.time():
                        continue
                    with self.db() as db:
                        db.execute('DELETE FROM consumed WHERE created<?', (time.time() - 86400,))
                        inserted = db.execute('INSERT OR IGNORE INTO consumed VALUES(?,?)', (frame['commandId'], time.time())).rowcount
                    if inserted:
                        self._emit(frame)
                elif frame.get('event'):
                    self._emit(frame)
                else:
                    with self.lock:
                        pending = self.pending.get(frame.get('id'))
                    if pending:
                        pending.put(frame)
        except (ValueError, OSError):
            pass
        finally:
            self.connected.clear()
            try:
                child.terminate()
            except OSError:
                pass

    def _rpc(self, request, timeout=15):
        ident = uuid.uuid4().hex
        frame = dict(request, id=ident)
        encoded = (json.dumps(frame, ensure_ascii=False, allow_nan=False) + '\n').encode('utf-8')
        if len(encoded) > FRAME:
            raise ValueError('frame too large')
        pending = queue.Queue()
        with self.lock:
            if not self.connected.is_set() or self.child is None:
                raise Unavailable('coordinator offline')
            self.pending[ident] = pending
            try:
                self.child.stdin.write(encoded)
                self.child.stdin.flush()
            except (OSError, ValueError):
                self.pending.pop(ident, None)
                raise Unavailable('coordinator disconnected')
        try:
            try:
                response = pending.get(timeout=timeout)
            except queue.Empty:
                raise Unavailable('coordinator request timed out')
            if response is None:
                raise Unavailable('coordinator disconnected')
            if not response.get('ok'):
                raise RemoteError(response.get('error', 'request failed'))
            return {k: v for k, v in response.items() if k != 'id'}
        finally:
            with self.lock:
                self.pending.pop(ident, None)

    def request(self, request, timeout=15):
        if not self.enabled:
            return dict(ok=False, error='continuity disabled', available=False)
        native_id = request.get('id')
        request = {k: v for k, v in request.items() if k not in ('id', 'timeout')}
        op = request.get('op')
        if op in ('conflicts', 'discard_conflict'):
            with self.db() as db:
                if op == 'discard_conflict':
                    identifier(request.get('mutationId'), 'mutationId')
                    db.execute('DELETE FROM conflicts WHERE id=?', (request['mutationId'],))
                    return dict(ok=True)
                if request.get('mutationId'):
                    row = db.execute('SELECT id,value,error,created FROM conflicts WHERE id=?', (request['mutationId'],)).fetchone()
                    return dict(ok=True, conflict=None if not row else dict(mutationId=row[0], request={k: v for k, v in json.loads(row[1]).items() if k != 'parentMutationId'}, error=row[2], createdAt=row[3]))
                rows = db.execute('SELECT id,value,error,created FROM conflicts ORDER BY created DESC,id LIMIT 100').fetchall()
                return dict(ok=True, conflicts=[dict(mutationId=row[0], topic=json.loads(row[1])['topic'], key=json.loads(row[1])['key'], error=row[2], createdAt=row[3]) for row in rows])
        if op == 'desk_local':
            from continuity_desk import native
            return native(self, request['request'], timeout)
        if op == 'stage_file':
            return dict(ok=True, blob=self.stage_file(request['path'], timeout))
        if op == 'fetch_blob':
            return dict(ok=True, path=str(self.fetch_blob(request['blob'], timeout)))
        if op == 'watch':
            topics = request.get('topics', sorted(TOPICS))
            if not isinstance(topics, list) or any(t not in TOPICS for t in topics):
                raise ValueError('unknown topic')
            with self.watch_lock:
                self.watch_id = native_id
                self.topics = list(dict.fromkeys(self.topics + topics))
                for topic in topics:
                    view, queued = self._view(topic)
                    if view is not None:
                        self._emit(dict(view, event='snapshot', cached=True, replayed=True, initial=True, queued=queued, changed=[]))
                if self.connected.is_set():
                    try:
                        return self._rpc(dict(op='watch', topics=self.topics), timeout)
                    except Unavailable:
                        pass
                return dict(ok=True, topics=self.topics, cached=True, offline=True)
        if op in MUTATIONS:
            with self.mutation_lock:
                return self._mutation(request, timeout)
        try:
            result = self._rpc(request, timeout)
            if op == 'get':
                current, accepted = self._cache_authoritative(result)
                view, queued = self._view(request['topic'])
                return dict(view, ok=True, cached=queued, initial=True, replayed=True, queued=queued, changed=[])
            return result
        except Unavailable:
            if op == 'get':
                view, queued = self._view(request['topic'])
                if view is not None:
                    return dict(view, ok=True, cached=True, replayed=True, initial=True, offline=True, queued=queued, changed=[])
            raise

    @staticmethod
    def _canonical(frame):
        topic = frame['topic']
        revision = frame['revision']
        if topic not in TOPICS or type(revision) is not int or revision < 0 or not isinstance(frame['items'], list):
            raise ValueError('invalid snapshot')
        return dict(topic=topic, revision=revision, items=frame['items'])

    def _cache_authoritative(self, frame):
        incoming = self._canonical(frame)
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT value FROM snapshots WHERE topic=?', (incoming['topic'],)).fetchone()
            if row:
                current = self._canonical(json.loads(row[0]))
                if current['revision'] > incoming['revision']:
                    return current, False
            db.execute('INSERT OR REPLACE INTO snapshots VALUES(?,?)', (incoming['topic'], json.dumps(incoming)))
        return incoming, True

    def _view(self, topic, db=None):
        if db is None:
            with self.db() as connection:
                connection.execute('BEGIN')
                return self._view(topic, connection)
        row = db.execute('SELECT value FROM snapshots WHERE topic=?', (topic,)).fetchone()
        pending = []
        for pending_row in db.execute('SELECT value FROM outbox ORDER BY created,id'):
            request = json.loads(pending_row[0])
            if request['topic'] == topic:
                pending.append(request)
        if not row and not pending:
            return None, False
        frame = self._canonical(json.loads(row[0])) if row else dict(topic=topic, revision=0, items=[])
        items = {item['id']: item for item in frame['items']}
        for request in pending:
            key = request['key']
            if request['op'] == 'delete':
                items.pop(key, None)
            elif request['op'] == 'put' or key in items:
                payload = dict(items[key]['payload']) if request['op'] == 'patch' else {}
                payload.update(request.get('payload', {}))
                items[key] = dict(id=key, origin=self.peer, updatedAt=time.time(), payload=payload)
        values = list(items.values())
        while len(values) > 300 or len(json.dumps(values, ensure_ascii=False).encode()) > 700 * 1024:
            victim = next((item for item in values if not item['payload'].get('pinned')), None)
            if victim is None:
                values = []
                break
            values.remove(victim)
        frame.update(items=values)
        if len(values) != len(items):
            frame['truncated'] = True
        return frame, bool(pending)

    def _mutation(self, request, timeout):
        if set(request) - {'op', 'topic', 'key', 'payload', 'mutationId', 'expectedRevision'}:
            raise ValueError('unknown mutation field')
        topic, key, operation = request.get('topic'), request.get('key'), request['op']
        ident = identifier(request.get('mutationId'), 'mutationId')
        payload = request.get('payload', {})
        validate_payload(self.peer, topic, key, payload, partial=operation != 'put')
        if operation == 'delete' and payload:
            raise ValueError('delete payload must be empty')
        expected = request.get('expectedRevision')
        if expected is not None and (type(expected) is not int or expected < 0):
            raise ValueError('invalid expectedRevision')
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            old = db.execute('SELECT value FROM outbox WHERE id=?', (ident,)).fetchone()
            source = json.dumps(request, sort_keys=True, allow_nan=False)
            fingerprint = hashlib.sha256(source.encode()).hexdigest()
            intent = db.execute('SELECT fingerprint,expected,parent FROM intents WHERE id=?', (ident,)).fetchone()
            if intent:
                if intent[0] != fingerprint:
                    raise ValueError('mutation identity reused')
                if intent[1] is not None:
                    request = dict(request, expectedRevision=intent[1])
                if intent[2]:
                    request = dict(request, parentMutationId=intent[2])
            elif old:
                # An older-version uncertain request must keep its exact wire identity.
                if json.loads(old[0]) != request:
                    raise ValueError('mutation identity reused')
            else:
                cached = db.execute('SELECT value FROM snapshots WHERE topic=?', (topic,)).fetchone()
                if 'expectedRevision' not in request and cached:
                    request = dict(request, expectedRevision=self._canonical(json.loads(cached[0]))['revision'])
                previous = None
                for pending in db.execute('SELECT id,value FROM outbox ORDER BY created,id'):
                    candidate = json.loads(pending[1])
                    if candidate['topic'] == topic and candidate['key'] == key:
                        previous = pending[0]
                if previous:
                    request = dict(request, parentMutationId=previous)
                db.execute('INSERT INTO intents VALUES(?,?,?,?)', (ident, fingerprint, request.get('expectedRevision'), previous))
            value = json.dumps(request, sort_keys=True, allow_nan=False)
            view, queued = self._view(topic, db)
            if operation == 'patch' and not old:
                base = next((item['payload'] for item in (view or {}).get('items', []) if item['id'] == key), None)
                if base is None:
                    raise ValueError('patch target absent from local cache; get/watch first')
                validate_payload(self.peer, topic, key, dict(base, **payload))
            count, size = db.execute('SELECT COUNT(*),COALESCE(SUM(LENGTH(value)),0) FROM (SELECT value FROM outbox UNION ALL SELECT value FROM conflicts)').fetchone()
            if not old and (count >= 1000 or size + len(value) > 16 * 1024 ** 2):
                raise ValueError('offline outbox/conflict storage full')
            db.execute('INSERT OR IGNORE INTO outbox VALUES(?,?,?)', (ident, value, time.time()))
            parent_pending = bool(request.get('parentMutationId') and db.execute('SELECT 1 FROM outbox WHERE id=?', (request['parentMutationId'],)).fetchone())
        if parent_pending:
            self._reconnect_for_replay()
            self._optimistic(request)
            return dict(ok=True, queued=True, mutationId=ident)
        try:
            result = self._rpc(request, timeout)
        except Unavailable:
            self._reconnect_for_replay()
            self._optimistic(request)
            return dict(ok=True, queued=True, mutationId=ident)
        except RemoteError as error:
            with self.db() as db:
                db.execute('BEGIN IMMEDIATE')
                db.execute('INSERT OR REPLACE INTO conflicts VALUES(?,?,?,?)', (ident, value, str(error)[:256], time.time()))
                db.execute('DELETE FROM outbox WHERE id=?', (ident,))
            raise
        with self.db() as db:
            db.execute('DELETE FROM outbox WHERE id=?', (ident,))
            db.execute('DELETE FROM conflicts WHERE id=?', (ident,))
        try:
            self._cache_authoritative(self._rpc(dict(op='get', topic=topic), timeout))
        except (Unavailable, RemoteError):
            pass
        return result

    def _reconnect_for_replay(self):
        # Uncertain requests must be retried in durable order, never overtaken by
        # another live request while their original server execution may continue.
        with self.lock:
            self.connected.clear()
            child = self.child
        if child:
            try:
                child.terminate()
            except OSError:
                pass

    def _optimistic(self, request):
        frame, queued = self._view(request['topic'])
        self._emit(dict(frame, event='snapshot', cached=True, replayed=True, initial=False, queued=queued, changed=[request['key']]))

    def stage_file(self, path, timeout=60):
        # The caller supplies only an explicitly selected local regular file.
        h = hashlib.sha256()
        with regular_open(path) as source:
            size = os.fstat(source.fileno()).st_size
            blob = validate_blob(dict(sha256='0' * 64, size=size, name=name(Path(path).name)))
            for chunk in iter(lambda: source.read(CHUNK), b''):
                h.update(chunk)
            blob['sha256'] = h.hexdigest()
            upload = self._rpc(dict(op='upload_start', blob=blob), timeout)['uploadId']
            source.seek(0)
            offset = 0
            while True:
                chunk = source.read(CHUNK)
                if not chunk:
                    break
                self._rpc(dict(op='upload_chunk', uploadId=upload, offset=offset, data=base64.b64encode(chunk).decode('ascii')), timeout)
                offset += len(chunk)
            self._rpc(dict(op='upload_finish', uploadId=upload), timeout)
        return blob

    def fetch_blob(self, blob, timeout=60):
        blob = validate_blob(blob)
        lock_path = self.cache_root / 'downloads.lock'
        fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        with os.fdopen(fd, 'a+b') as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                return self._fetch_blob_locked(blob, timeout)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def _fetch_blob_locked(self, blob, timeout):
        directory = private_dir(self.blobs / blob['sha256'])
        dest = directory / blob['name']
        if dest.exists() and verified(dest, blob):
            return dest
        from continuity_store import RESERVE
        import shutil
        if shutil.disk_usage(self.cache_root).free < blob['size'] + RESERVE:
            raise ValueError('insufficient disk reserve')
        temp = directory / ('.partial-' + uuid.uuid4().hex)
        try:
            offset = 0
            with open(str(temp), 'xb') as stream:
                os.chmod(str(temp), 0o600)
                while True:
                    response = self._rpc(dict(op='blob_read', blob=blob, offset=offset), timeout)
                    chunk = base64.b64decode(response['data'], validate=True)
                    if len(chunk) > CHUNK or response.get('offset') != offset or offset + len(chunk) > blob['size'] or (not chunk and not response['eof']):
                        raise ValueError('invalid blob chunk')
                    stream.write(chunk)
                    offset += len(chunk)
                    if response['eof']:
                        break
                stream.flush()
                os.fsync(stream.fileno())
            if not verified(temp, blob):
                raise ValueError('blob verification failed')
            os.replace(str(temp), str(dest))
            return dest
        finally:
            if temp.exists():
                temp.unlink()

    @staticmethod
    def _terminate(child):
        try:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=2)
        except OSError:
            pass
        for stream in (child.stdin, child.stdout, child.stderr):
            if stream:
                try:
                    stream.close()
                except OSError:
                    pass

    def close(self):
        self.stop.set()
        with self.lock:
            child = self.child
        if child:
            self._terminate(child)
        if self.thread and self.thread is not threading.current_thread():
            self.thread.join(timeout=4)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def one_shot(config, request, timeout=60):
    """Callable desk-hub integration: one_shot(config, {'op':'desk','request':...})."""
    with Client(config) as client:
        if client.enabled:
            client.connected.wait(min(timeout, 5))
        return client.request(request, timeout=timeout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stdio', action='store_true', required=True)
    parser.add_argument('--config', default=str(Path(__file__).parent / 'continuity' / 'config.json'))
    args = parser.parse_args()
    lock = threading.Lock()
    def emit(frame):
        with lock:
            sys.stdout.write(json.dumps(frame, ensure_ascii=False, allow_nan=False) + '\n')
            sys.stdout.flush()
    client = Client(args.config, on_event=emit)
    slots = threading.BoundedSemaphore(32)
    def process(request):
        ident = request.get('id')
        try:
            from continuity_store import identifier
            identifier(ident, 'request id')
            result = client.request(request, timeout=request.get('timeout', 60))
            emit(dict(result, id=ident))
        except Exception as error:
            emit(dict(id=ident, ok=False, error=str(error)[:256]))
        finally:
            slots.release()
    from concurrent.futures import ThreadPoolExecutor
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
                        raise ValueError('object required')
                    slots.acquire()
                    executor.submit(process, request)
                except (ValueError, UnicodeError):
                    emit(dict(id=None, ok=False, error='invalid JSON frame'))
    finally:
        client.close()

if __name__ == '__main__':
    main()
