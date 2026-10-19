"""Private transactional continuity state and verified content-addressed blobs."""
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import time
import threading
import uuid

TOPICS = frozenset(('clipboard', 'shelf', 'links', 'alerts', 'tasks', 'media', 'desk'))
ACTIONS = frozenset(('play', 'pause', 'toggle', 'next', 'previous', 'seek', 'raise'))
MAX_BLOB = 2 * 1024 ** 3
MAX_PNG = 20 * 1024 ** 2
CHUNK = 512 * 1024
FRAME = 1024 * 1024
RESERVE = 1024 ** 3

def private_dir(path):
    path = Path(path).expanduser().absolute()
    if path.is_symlink():
        raise ValueError('symlink directory')
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_uid != os.getuid():
        raise ValueError('directory belongs to another user')
    path.chmod(0o700)
    return path

def identifier(value, label='identifier'):
    if not isinstance(value, str) or not value or len(value) > 256 or any(ord(c) < 32 for c in value):
        raise ValueError('invalid ' + label)
    return value

def digest(value):
    if not isinstance(value, str) or not re.fullmatch('[a-f0-9]{64}', value):
        raise ValueError('invalid blob hash')
    return value

def name(value):
    if not isinstance(value, str) or not value or value in ('.', '..') or '/' in value or '\\' in value or len(value.encode('utf-8')) > 255 or any(ord(c) < 32 for c in value):
        raise ValueError('invalid file name')
    return value

def validate_blob(blob):
    if not isinstance(blob, dict) or set(blob) != {'sha256', 'size', 'name'}:
        raise ValueError('invalid blob descriptor')
    digest(blob['sha256'])
    name(blob['name'])
    size = blob['size']
    if type(size) is not int or not 0 <= size <= MAX_BLOB:
        raise ValueError('invalid blob size')
    if blob['name'].lower().endswith('.png') and size > MAX_PNG:
        raise ValueError('PNG too large')
    return dict(sha256=blob['sha256'], size=size, name=blob['name'])

FIELDS = {
    'clipboard': {'kind', 'text', 'blob', 'label', 'pinned', 'capturedAt'},
    'shelf': {'kind', 'name', 'text', 'url', 'blob', 'createdAt'},
    'links': {'title', 'url', 'note', 'createdAt', 'blob', 'sync'},
    'alerts': {'alertId', 'stateHash', 'dismissed'},
    'tasks': {'taskId', 'host', 'agent', 'title', 'status', 'progress', 'summary', 'updatedAt', 'blob'},
    'media': {'host', 'title', 'artist', 'album', 'playing', 'duration', 'position', 'available', 'updatedAt'},
    'desk': {'layout', 'active', 'inputMode', 'updatedAt'},
}
REQUIRED = {
    'clipboard': {'kind', 'capturedAt'}, 'shelf': {'kind', 'name', 'createdAt'},
    'links': {'title', 'url', 'note', 'createdAt'}, 'alerts': {'alertId', 'stateHash', 'dismissed'},
    'tasks': FIELDS['tasks'] - {'blob'}, 'media': FIELDS['media'], 'desk': FIELDS['desk'],
}

def validate_payload(peer, topic, key, payload, partial=False):
    """Shared allowlist: call on partial edits AND on their complete merged result."""
    identifier(peer, 'peer')
    identifier(key, 'key')
    if topic not in TOPICS or not isinstance(payload, dict) or set(payload) - FIELDS[topic]:
        raise ValueError('unknown topic payload field')
    if len(json.dumps(payload, ensure_ascii=False, allow_nan=False).encode()) > 384 * 1024:
        raise ValueError('payload too large')
    if topic == 'tasks':
        if not key.startswith(peer + ':') or not key[len(peer) + 1:]:
            raise ValueError('task key must be peer:taskId')
        if 'taskId' in payload and payload['taskId'] != key[len(peer) + 1:]:
            raise ValueError('task identity mismatch')
    if topic == 'media' and key != peer:
        raise ValueError('media key must equal peer')
    if topic in ('tasks', 'media') and 'host' in payload and payload['host'] != peer:
        raise ValueError('host must equal peer')
    for field, value in payload.items():
        if field == 'blob':
            validate_blob(value)
        elif field in ('pinned', 'playing', 'available', 'active', 'dismissed', 'sync'):
            if type(value) is not bool:
                raise ValueError('boolean required: ' + field)
            if field == 'dismissed' and value is not True or field == 'sync' and value is not False:
                raise ValueError('invalid acknowledgement/sync value')
        elif field in ('capturedAt', 'createdAt', 'updatedAt', 'progress', 'duration', 'position'):
            if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                raise ValueError('finite nonnegative number required: ' + field)
            if field == 'progress' and value > 100:
                raise ValueError('progress exceeds 100')
        elif field == 'layout':
            if not isinstance(value, (str, dict, list)):
                raise ValueError('invalid desk layout')
            # Desk layout is configuration data, never an alternate metadata channel.
            def inspect(node):
                if isinstance(node, dict):
                    for k, v in node.items():
                        if any(word in k.lower() for word in ('token', 'permission', 'secret', 'password', 'transcript')):
                            raise ValueError('private layout field')
                        inspect(v)
                elif isinstance(node, list):
                    for item in node:
                        inspect(item)
            inspect(value)
        elif not isinstance(value, str) or len(value.encode()) > (256 * 1024 if field == 'text' else 16 * 1024):
            raise ValueError('invalid string: ' + field)
    if topic == 'clipboard':
        if 'kind' in payload and payload['kind'] not in ('text', 'link', 'image'):
            raise ValueError('invalid clipboard kind')
        if 'blob' in payload and (payload['blob']['size'] > MAX_PNG or not payload['blob']['name'].lower().endswith('.png')):
            raise ValueError('clipboard image must be bounded PNG')
    if topic == 'shelf' and 'kind' in payload and payload['kind'] not in ('file', 'text', 'link'):
        raise ValueError('invalid shelf kind')
    if not partial:
        if not REQUIRED[topic] <= set(payload):
            raise ValueError('missing required topic fields')
        if topic == 'clipboard' and ('blob' if payload['kind'] == 'image' else 'text') not in payload:
            raise ValueError('missing clipboard content')
        if topic == 'shelf' and {'file': 'blob', 'text': 'text', 'link': 'url'}[payload['kind']] not in payload:
            raise ValueError('missing shelf content')
    return payload

def regular_open(path, mode='rb'):
    """Reject symlinks in every path component and atomically open the final file."""
    path = Path(path).expanduser().absolute()
    if any(p.is_symlink() for p in [path] + list(path.parents)):
        raise ValueError('symlink file')
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError('regular file required')
    flags = os.O_RDONLY if mode == 'rb' else os.O_WRONLY
    fd = os.open(str(path), flags | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise ValueError('regular file required')
    return os.fdopen(fd, mode)

def verified(path, blob):
    blob = validate_blob(blob)
    h = hashlib.sha256()
    with regular_open(path) as stream:
        count = 0
        while True:
            chunk = stream.read(CHUNK)
            if not chunk:
                break
            count += len(chunk)
            h.update(chunk)
    return count == blob['size'] and h.hexdigest() == blob['sha256']

class ClosingConnection(sqlite3.Connection):
    def __exit__(self, *args):
        try:
            return super().__exit__(*args)
        finally:
            self.close()

class Store:
    def __init__(self, root):
        self.root = private_dir(root)
        self.blobs = private_dir(self.root / 'blobs')
        self.uploads = private_dir(self.root / 'uploads')
        self.verified_blobs = {}
        self.verify_lock = threading.Lock()
        self.db_path = self.root / 'state.sqlite3'
        if self.db_path.is_symlink():
            raise ValueError('symlink database')
        with self.db() as db:
            db.executescript('''
              PRAGMA journal_mode=WAL;
              CREATE TABLE IF NOT EXISTS changes(revision INTEGER,topic TEXT,replayed INTEGER,key TEXT);
              CREATE TABLE IF NOT EXISTS revision(value INTEGER NOT NULL);
              INSERT INTO revision SELECT 0 WHERE NOT EXISTS(SELECT 1 FROM revision);
              CREATE TABLE IF NOT EXISTS items(topic TEXT,key TEXT,origin TEXT,updated REAL,payload TEXT,deleted INTEGER,revision INTEGER,PRIMARY KEY(topic,key));
              CREATE TABLE IF NOT EXISTS mutations(peer TEXT,id TEXT,request TEXT,revision INTEGER,PRIMARY KEY(peer,id));
              CREATE TABLE IF NOT EXISTS lineage(peer TEXT,id TEXT,topic TEXT,key TEXT,revision INTEGER,PRIMARY KEY(peer,id));
              CREATE TABLE IF NOT EXISTS commands(id TEXT PRIMARY KEY,source TEXT,target TEXT,session TEXT,action TEXT,arguments TEXT,expires REAL,ack TEXT);
              CREATE TABLE IF NOT EXISTS uploads(id TEXT PRIMARY KEY,peer TEXT,blob TEXT,received INTEGER,created REAL);
            ''')
        self.db_path.chmod(0o600)

    def db(self):
        db = sqlite3.connect(str(self.db_path), timeout=15, factory=ClosingConnection)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA busy_timeout=15000')
        return db

    def snapshot(self, topic):
        if topic not in TOPICS:
            raise ValueError('unknown topic')
        with self.db() as db:
            db.execute('BEGIN')
            revision = db.execute('SELECT COALESCE(MAX(revision),0) FROM items WHERE topic=?', (topic,)).fetchone()[0]
            rows = db.execute('SELECT * FROM items WHERE topic=? AND deleted=0 ORDER BY updated,key', (topic,)).fetchall()
        return dict(topic=topic, revision=revision, items=[dict(id=r['key'], origin=r['origin'], updatedAt=r['updated'], payload=json.loads(r['payload'])) for r in rows])

    def mutate(self, peer, request):
        if set(request) - {'op', 'topic', 'key', 'payload', 'mutationId', 'expectedRevision', 'replayed', 'parentMutationId'}:
            raise ValueError('unknown mutation field')
        topic, key = request['topic'], identifier(request['key'])
        if topic not in TOPICS:
            raise ValueError('unknown topic')
        mutation = identifier(request['mutationId'])
        operation = request['op']
        payload = request.get('payload', {})
        if operation not in ('put', 'patch', 'delete'):
            raise ValueError('invalid mutation operation')
        validate_payload(peer, topic, key, payload, partial=operation != 'put')
        if operation == 'delete' and payload:
            raise ValueError('delete payload must be empty')
        if 'blob' in payload and not verified(self.blobs / payload['blob']['sha256'], payload['blob']):
            raise ValueError('blob must be verified before publication')
        expected = request.get('expectedRevision')
        if expected is not None and (type(expected) is not int or expected < 0):
            raise ValueError('invalid expectedRevision')
        parent = request.get('parentMutationId')
        if parent is not None:
            identifier(parent, 'parent mutation')
            if parent == mutation:
                raise ValueError('mutation cannot be its own parent')
        canonical = hashlib.sha256(json.dumps({k: v for k, v in request.items() if k != 'replayed'}, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            old = db.execute('SELECT * FROM mutations WHERE peer=? AND id=?', (peer, mutation)).fetchone()
            if old:
                if old['request'] != canonical:
                    raise ValueError('mutation identity reused')
                db.execute('INSERT OR IGNORE INTO lineage VALUES(?,?,?,?,?)', (peer, mutation, topic, key, old['revision']))
                return dict(revision=old['revision'], duplicate=True)
            row = db.execute('SELECT * FROM items WHERE topic=? AND key=?', (topic, key)).fetchone()
            if operation == 'patch':
                if not row or row['deleted']:
                    raise ValueError('patch target missing or deleted')
                previous = json.loads(row['payload'])
                previous.update(payload)
                payload = previous
            if operation == 'put' and row and (row['deleted'] or request.get('replayed') or parent):
                predecessor = db.execute('SELECT revision FROM lineage WHERE peer=? AND id=? AND topic=? AND key=?', (peer, parent, topic, key)).fetchone() if parent else None
                follows_current = bool(predecessor and not row['deleted'] and predecessor['revision'] == row['revision'])
                if parent and not row['deleted'] and not follows_current:
                    raise ValueError('causal predecessor no longer current')
                if not follows_current and (expected is None or expected < row['revision']):
                    raise ValueError('stale upsert conflicts with server revision')
                if row['deleted'] and topic == 'clipboard' and payload.get('capturedAt', 0) <= row['updated']:
                    raise ValueError('clipboard recapture must be a new capture event')
            if operation != 'delete':
                validate_payload(peer, topic, key, payload)
            revision = db.execute('SELECT value FROM revision').fetchone()[0] + 1
            db.execute('UPDATE revision SET value=?', (revision,))
            db.execute('INSERT INTO changes VALUES(?,?,?,?)', (revision, topic, int(bool(request.get('replayed'))), key))
            db.execute('DELETE FROM changes WHERE revision<?', (revision - 2000,))
            db.execute('INSERT OR REPLACE INTO items VALUES(?,?,?,?,?,?,?)', (topic, key, peer, time.time(), json.dumps(payload), int(operation == 'delete'), revision))
            if topic == 'tasks':
                expired = db.execute("SELECT key,payload FROM items WHERE topic='tasks' AND deleted=0 AND updated<?", (time.time() - 30 * 86400,)).fetchall()
                for item in expired:
                    if json.loads(item['payload']).get('status') in ('done', 'completed', 'failed', 'cancelled', 'archived'):
                        db.execute("UPDATE items SET deleted=1,payload='{}',revision=? WHERE topic='tasks' AND key=?", (revision, item['key']))
                        db.execute('INSERT INTO changes VALUES(?,?,?,?)', (revision, topic, 1, item['key']))
            rows = db.execute('SELECT key,origin,updated,payload FROM items WHERE topic=? AND deleted=0 ORDER BY updated,key', (topic,)).fetchall()
            frame_items = [dict(id=r['key'], origin=r['origin'], updatedAt=r['updated'], payload=json.loads(r['payload'])) for r in rows]
            while len(frame_items) > 300 or len(json.dumps(frame_items, ensure_ascii=False).encode()) > 700 * 1024:
                victim = next((item for item in frame_items if topic == 'clipboard' and item['id'] != key and not item['payload'].get('pinned')), None)
                if victim is None:
                    raise ValueError('topic retention limit reached; remove old items or pins')
                db.execute("UPDATE items SET deleted=1,payload='{}',revision=?,updated=? WHERE topic=? AND key=?", (revision, time.time(), topic, victim['id']))
                # All pruned identities are included in the same committed snapshot.
                db.execute('INSERT INTO changes VALUES(?,?,?,?)', (revision, topic, int(bool(request.get('replayed'))), victim['id']))
                frame_items.remove(victim)
            db.execute('INSERT INTO mutations VALUES(?,?,?,?)', (peer, mutation, canonical, revision))
            db.execute('INSERT INTO lineage VALUES(?,?,?,?,?)', (peer, mutation, topic, key, revision))
        return dict(revision=revision)

    def upload_start(self, peer, blob):
        blob = validate_blob(blob)
        if shutil.disk_usage(self.root).free < blob['size'] + RESERVE:
            raise ValueError('insufficient disk reserve')
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            stale = db.execute('SELECT id FROM uploads WHERE created<?', (time.time() - 86400,)).fetchall()
            for row in stale:
                try:
                    (self.uploads / row[0]).unlink()
                except FileNotFoundError:
                    pass
            db.execute('DELETE FROM uploads WHERE created<?', (time.time() - 86400,))
            remaining = sum(json.loads(row['blob'])['size'] - row['received'] for row in db.execute('SELECT blob,received FROM uploads'))
            if shutil.disk_usage(self.root).free < remaining + blob['size'] + RESERVE:
                raise ValueError('insufficient disk reserve')
            if db.execute('SELECT COUNT(*) FROM uploads WHERE peer=?', (peer,)).fetchone()[0] >= 32:
                raise ValueError('too many unfinished uploads')
            upload = uuid.uuid4().hex
            with open(str(self.uploads / upload), 'xb') as stream:
                os.chmod(stream.name, 0o600)
            db.execute('INSERT INTO uploads VALUES(?,?,?,?,?)', (upload, peer, json.dumps(blob), 0, time.time()))
        return dict(uploadId=upload, chunkSize=CHUNK)

    def _upload(self, db, peer, upload):
        if not isinstance(upload, str) or not re.fullmatch('[a-f0-9]{32}', upload):
            raise ValueError('invalid upload')
        row = db.execute('SELECT * FROM uploads WHERE id=? AND peer=?', (upload, peer)).fetchone()
        if not row:
            raise ValueError('unknown upload for peer')
        return row, json.loads(row['blob'])

    def upload_chunk(self, peer, upload, offset, data):
        if not isinstance(data, str) or len(data) > ((CHUNK + 2) // 3) * 4:
            raise ValueError('chunk too large')
        chunk = base64.b64decode(data, validate=True)
        if len(chunk) > CHUNK or type(offset) is not int:
            raise ValueError('invalid chunk')
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row, blob = self._upload(db, peer, upload)
            if offset != row['received'] or offset + len(chunk) > blob['size']:
                raise ValueError('invalid chunk offset or size')
            path = self.uploads / upload
            with regular_open(path, 'wb') as stream:
                stream.seek(offset)
                stream.write(chunk)
                stream.flush()
                os.fsync(stream.fileno())
            db.execute('UPDATE uploads SET received=? WHERE id=?', (offset + len(chunk), upload))
        return dict(received=offset + len(chunk))

    def upload_finish(self, peer, upload):
        # Hash outside the write transaction: large uploads cannot stall heartbeats
        # or topic mutations/subscriptions while their content is being verified.
        with self.db() as db:
            row, blob = self._upload(db, peer, upload)
        path = self.uploads / upload
        if row['received'] != blob['size'] or not verified(path, blob):
            raise ValueError('blob verification failed')
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            latest, current = self._upload(db, peer, upload)
            if latest['received'] != row['received'] or current != blob:
                raise ValueError('upload changed during verification')
            os.replace(str(path), str(self.blobs / blob['sha256']))
            db.execute('DELETE FROM uploads WHERE id=?', (upload,))
        return dict(blob=blob)

    def blob_read(self, blob, offset):
        blob = validate_blob(blob)
        if type(offset) is not int or offset < 0 or offset > blob['size']:
            raise ValueError('invalid offset')
        path = self.blobs / blob['sha256']
        # Verify the whole content before making any bytes available.
        with self.verify_lock:
            st = path.stat()
            fingerprint = (st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns, blob['size'])
            if self.verified_blobs.get(blob['sha256']) != fingerprint:
                if not verified(path, blob):
                    raise ValueError('blob verification failed')
                if len(self.verified_blobs) >= 128:
                    self.verified_blobs.clear()
                self.verified_blobs[blob['sha256']] = fingerprint
        with regular_open(path) as stream:
            stream.seek(offset)
            chunk = stream.read(CHUNK)
        return dict(data=base64.b64encode(chunk).decode('ascii'), offset=offset, eof=offset + len(chunk) == blob['size'])
