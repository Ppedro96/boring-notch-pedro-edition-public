import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

INTEGRATIONS = Path(__file__).resolve().parents[1] / 'Integrations'
sys.path.insert(0, str(INTEGRATIONS))
from continuity_store import Store, CHUNK, FRAME, validate_blob
spec = importlib.util.spec_from_file_location('continuity_client', INTEGRATIONS / 'continuity-client.py')
client_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client_module)
spec = importlib.util.spec_from_file_location('continuity_server', INTEGRATIONS / 'continuity-server.py')
server_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server_module)


def until(predicate, seconds=5):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        result = predicate()
        if result:
            return result
        time.sleep(.02)
    raise AssertionError('condition timed out')


class ContinuityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.clients = []
        self.sessions = []

    def tearDown(self):
        for client in self.clients:
            client.close()
        for session in self.sessions:
            session.close()
        self.temp.cleanup()

    def config(self, peer):
        return dict(enabled=True, peer=peer, cache=str(self.root / ('cache-' + peer)), server=dict(argv=[sys.executable, str(INTEGRATIONS / 'continuity-server.py'), '--stdio', '--peer', peer, '--root', str(self.root / 'server')]))

    def client(self, peer):
        events = []
        client = client_module.Client(self.config(peer), on_event=events.append)
        self.clients.append(client)
        until(lambda: any(e.get('state') == 'online' for e in events))
        return client, events

    def mutation(self, key='entry', **fields):
        return dict(op='put', topic='clipboard', key=key, payload=dict(kind='text', text=' exact \n whitespace ', capturedAt=time.time(), **fields), mutationId='mutation-' + key)

    def test_concurrent_patch_tombstone_and_idempotence(self):
        store = Store(self.root / 'server')
        request = self.mutation()
        result = store.mutate('one', request)
        self.assertTrue(store.mutate('one', request)['duplicate'])
        self.assertEqual(store.snapshot('clipboard')['items'][0]['payload']['text'], request['payload']['text'])
        def change(index):
            return Store(self.root / 'server').mutate('two', dict(op='patch', topic='clipboard', key='entry', payload=({'label': str(index)} if index % 2 else {'pinned': True}), mutationId=str(index)))
        with ThreadPoolExecutor(max_workers=8) as pool:
            revisions = list(pool.map(change, range(20)))
        self.assertEqual(len({r['revision'] for r in revisions}), 20)
        payload = store.snapshot('clipboard')['items'][0]['payload']
        self.assertTrue(payload['pinned'])
        self.assertIn(int(payload['label']), range(20))
        self.assertEqual(payload['text'], request['payload']['text'])
        store.mutate('one', dict(op='delete', topic='clipboard', key='entry', mutationId='deleted'))
        self.assertEqual(store.snapshot('clipboard')['items'], [])
        self.assertEqual(store.mutate('one', request)['revision'], result['revision'])
        self.assertEqual(store.snapshot('clipboard')['items'], [])
        with self.assertRaises(ValueError):
            store.mutate('one', dict(request, payload=dict(text='other')))

    def test_real_multiplexed_sessions_watch_and_get(self):
        one, events = self.client('one')
        two, _ = self.client('two')
        one.request(dict(id='stream-1', op='watch', topics=['clipboard', 'shelf']))
        initial = until(lambda: next((e for e in events if e.get('topic') == 'clipboard'), None))
        self.assertTrue(initial['initial'])
        self.assertTrue(initial['replayed'])
        self.assertEqual(initial['watchId'], 'stream-1')
        result = two.request(self.mutation())
        fresh = until(lambda: next((e for e in events if e.get('topic') == 'clipboard' and e.get('revision') == result['revision']), None))
        self.assertFalse(fresh['initial'])
        self.assertFalse(fresh['replayed'])
        self.assertEqual(fresh['changed'], ['entry'])
        self.assertEqual(one.request(dict(op='get', topic='clipboard'))['items'], fresh['items'])
        self.assertEqual(os.stat(one.database).st_mode & 0o777, 0o600)

    def test_offline_cache_outbox_reconnect_and_no_command_replay(self):
        one, events = self.client('one')
        two, _ = self.client('two')
        one.request(dict(op='watch', topics=['clipboard']))
        two.request(self.mutation())
        until(lambda: any(e.get('changed') == ['entry'] for e in events))
        # Point reconnection at a failing process while preserving the durable cache.
        one.config['server']['argv'] = [sys.executable, '-c', 'raise SystemExit(1)']
        one.child.terminate()
        until(lambda: not one.connected.is_set())
        cached = one.request(dict(op='get', topic='clipboard'), timeout=.1)
        self.assertTrue(cached['cached'])
        queued = one.request(dict(op='patch', topic='clipboard', key='entry', payload=dict(pinned=True), mutationId='offline-pin'), timeout=.1)
        self.assertTrue(queued['queued'])
        with self.assertRaises(client_module.Unavailable):
            one.request(dict(op='send_command', target='two', action='play'), timeout=.1)
        one.close()
        replacement, replay_events = self.client('one')
        replacement.request(dict(op='watch', topics=['clipboard']))
        until(lambda: Store(self.root / 'server').snapshot('clipboard')['items'][0]['payload'].get('pinned'))
        self.assertEqual(Store(self.root / 'server').snapshot('clipboard')['revision'], 2)
        self.assertTrue(next(e for e in replay_events if e.get('topic') == 'clipboard')['replayed'])
        with replacement.db() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM outbox').fetchone()[0], 0)

    def test_commands_peer_bound_expire_and_deduplicate(self):
        one, _ = self.client('one')
        two, events = self.client('two')
        three, wrong = self.client('three')
        two.request(dict(op='watch', topics=['media']))
        result = one.request(dict(op='send_command', target='two', action='seek', arguments=dict(position=12)))
        event = until(lambda: next((e for e in events if e.get('commandId') == result['commandId']), None))
        self.assertFalse(any(e.get('event') == 'command' for e in wrong))
        with self.assertRaises(client_module.RemoteError):
            three.request(dict(op='ack_command', commandId=result['commandId'], ok=True))
        two.request(dict(op='ack_command', commandId=result['commandId'], ok=True))
        store = Store(self.root / 'server')
        with store.db() as db:
            db.execute('UPDATE commands SET expires=? WHERE id=?', (time.time() - 1, result['commandId']))
        with self.assertRaises(client_module.RemoteError):
            two.request(dict(op='ack_command', commandId=result['commandId'], ok=True))
        # Feed an identical event through the real reader to prove persisted suppression.
        payload = (json.dumps(event) + '\n').encode()
        import io
        fake = type('Child', (), dict(stdout=io.BytesIO(payload), terminate=lambda self: None))()
        two._read(fake)
        self.assertEqual(len([e for e in events if e.get('commandId') == result['commandId']]), 1)
        for action in ['shell', 'pause;bad']:
            with self.assertRaises(client_module.RemoteError):
                one.request(dict(op='send_command', target='two', action=action))

    def test_expired_command_never_emitted(self):
        events = []
        session = server_module.Session(self.root / 'server', 'target', events.append)
        self.sessions.append(session)
        with session.store.db() as db:
            db.execute('INSERT INTO commands VALUES(?,?,?,?,?,?,?,?)', ('expired', 'source', 'target', session.session, 'play', '{}', time.time() - 1, None))
        time.sleep(.25)
        self.assertEqual(events, [])

    def test_real_blob_stream_and_offline_verified_fetch(self):
        one, _ = self.client('one')
        two, _ = self.client('two')
        selected = self.root / 'name $(touch bad).dat'
        selected.write_bytes(os.urandom(CHUNK + 199))
        blob = one.stage_file(selected)
        fetched = two.fetch_blob(blob)
        self.assertEqual(fetched.read_bytes(), selected.read_bytes())
        self.assertEqual(fetched.name, selected.name)
        self.assertFalse((self.root / 'bad').exists())
        two.close()
        self.assertEqual(two.fetch_blob(blob), fetched)
        fetched.write_bytes(b'corrupt')
        with self.assertRaises(client_module.Unavailable):
            two.fetch_blob(blob)
        self.assertFalse(list(two.blobs.glob('**/.partial-*')))

    def test_blob_integrity_scope_and_atomic_publication(self):
        store = Store(self.root / 'server')
        data = b'the actual file'
        blob = dict(sha256=hashlib.sha256(data).hexdigest(), size=len(data), name='file.dat')
        upload = store.upload_start('one', blob)['uploadId']
        with self.assertRaises(ValueError):
            store.upload_chunk('two', upload, 0, base64.b64encode(data).decode())
        with self.assertRaises(FileNotFoundError):
            store.blob_read(blob, 0)
        store.upload_chunk('one', upload, 0, base64.b64encode(b'x' * len(data)).decode())
        with self.assertRaises(ValueError):
            store.upload_finish('one', upload)
        self.assertFalse((store.blobs / blob['sha256']).exists())
        for invalid in ['../secret', '/secret', 'A' * 64, 'a' * 63]:
            with self.assertRaises(ValueError):
                store.blob_read(dict(blob, sha256=invalid), 0)
        for invalid in ['../file', 'x/y', 'x\\y', '..']:
            with self.assertRaises(ValueError):
                store.upload_start('one', dict(blob, name=invalid))
        with self.assertRaises(ValueError):
            store.upload_start('one', dict(blob, name='image.png', size=21 * 1024 ** 2))
        with self.assertRaises(ValueError):
            store.upload_chunk('one', upload, 0, 'x' * (CHUNK * 2))
        with patch('continuity_store.shutil.disk_usage') as free:
            free.return_value.free = 10
            with self.assertRaises(ValueError):
                store.upload_start('one', blob)

    def test_symlink_and_non_regular_source_rejected(self):
        one, _ = self.client('one')
        original = self.root / 'selected'
        original.write_bytes(b'hello')
        link = self.root / 'link'
        link.symlink_to(original)
        fifo = self.root / 'fifo'
        os.mkfifo(str(fifo))
        for path in [link, self.root, fifo]:
            with self.assertRaises((ValueError, IsADirectoryError)):
                one.stage_file(path)
        blob = one.stage_file(original)
        server_file = self.root / 'server' / 'blobs' / blob['sha256']
        server_file.unlink()
        server_file.symlink_to(original)
        with self.assertRaises(client_module.RemoteError):
            one.fetch_blob(blob)

    def test_desk_bypass_concurrency_and_explicit_unavailable(self):
        one, events = self.client('one')
        self.assertFalse(one.request(dict(op='desk', request=dict(command='status')))['result']['available'])
        broker = self.root / 'broker.py'
        broker.write_text('import time\ndef local_main(request):\n    time.sleep(.5)\n    return {"ok": True, "id":"job-id", "peer": request["_continuityPeer"], "layout":"existing", "inputMode":"mesh"}\n')
        (self.root / 'server' / 'config.json').write_text(json.dumps(dict(broker=dict(script=str(broker)))))
        one.request(dict(op='watch', topics=['shelf']))
        with ThreadPoolExecutor() as pool:
            pending = pool.submit(one.request, dict(op='desk', request=dict(command='status')), 5)
            start = time.monotonic()
            response = one.request(dict(op='put', topic='shelf', key='file', payload=dict(kind='text', name='text', text='hello', createdAt=time.time()), mutationId='shelf-text'))
            until(lambda: any(e.get('topic') == 'shelf' and e.get('revision') == response['revision'] for e in events))
            self.assertLess(time.monotonic() - start, .4)
            self.assertEqual(pending.result()['result']['inputMode'], 'mesh')
            self.assertEqual(pending.result()['result']['id'], 'job-id')
            self.assertEqual(pending.result()['result']['peer'], 'one')
        with self.assertRaises(client_module.RemoteError):
            one.request(dict(op='desk', request=dict(command='shell')))

    def test_one_shot_and_native_stdio_ids_and_disabled_default(self):
        result = client_module.one_shot(self.config('one'), dict(op='get', topic='shelf'))
        self.assertTrue(result['ok'])
        config = self.root / 'disabled.json'
        config.write_text('{}')
        process = subprocess.run([sys.executable, str(INTEGRATIONS / 'continuity-client.py'), '--stdio', '--config', str(config)], input='{"id":"native-id","op":"get","topic":"shelf"}\n', capture_output=True, text=True, timeout=10)
        frames = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(next(f for f in frames if f.get('id') == 'native-id')['available'], False)
        self.assertFalse((self.root / 'cache').exists())

    def test_topic_snapshot_bound_rolls_back_atomically(self):
        store = Store(self.root / 'server')
        payload = dict(kind='text', name='text', text='x' * 250000, createdAt=time.time())
        for index in range(2):
            store.mutate('one', dict(op='put', topic='shelf', key=str(index), payload=payload, mutationId=str(index)))
        before = store.snapshot('shelf')
        with self.assertRaises(ValueError):
            store.mutate('one', dict(op='put', topic='shelf', key='overflow', payload=payload, mutationId='overflow'))
        self.assertEqual(store.snapshot('shelf'), before)

    def test_native_enabled_stdio_concurrent_ids(self):
        config = self.root / 'config.json'
        config.write_text(json.dumps(self.config('native')))
        requests = ''.join(json.dumps(dict(id='request-' + str(i), op='get', topic='shelf')) + '\n' for i in range(3))
        # stdin remains open until transport is ready, as native apps do.
        process = subprocess.Popen([sys.executable, str(INTEGRATIONS / 'continuity-client.py'), '--stdio', '--config', str(config)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            while json.loads(process.stdout.readline()).get('state') != 'online':
                pass
            output, error = process.communicate(requests, timeout=10)
            replies = [json.loads(line) for line in output.splitlines() if 'id' in json.loads(line)]
            self.assertEqual({r['id'] for r in replies}, {'request-0', 'request-1', 'request-2'})
            self.assertTrue(all(r['ok'] for r in replies), error)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_clipboard_prunes_old_unpinned_and_preserves_pin(self):
        store = Store(self.root / 'server')
        for index in range(4):
            store.mutate('one', dict(op='put', topic='clipboard', key=str(index), payload=dict(kind='text', text='x' * 250000, capturedAt=time.time(), pinned=index == 0), mutationId=str(index)))
        self.assertEqual({item['id'] for item in store.snapshot('clipboard')['items']}, {'0', '3'})

    def test_large_blob_hash_does_not_hold_database_write_lock(self):
        store = Store(self.root / 'server')
        data = b'fixture'
        blob = dict(sha256=hashlib.sha256(data).hexdigest(), size=len(data), name='file.dat')
        upload = store.upload_start('one', blob)['uploadId']
        store.upload_chunk('one', upload, 0, base64.b64encode(data).decode())
        entered, release = threading.Event(), threading.Event()
        import continuity_store
        original = continuity_store.verified
        def blocked(*args):
            entered.set()
            release.wait(3)
            return original(*args)
        with patch('continuity_store.verified', side_effect=blocked), ThreadPoolExecutor() as pool:
            pending = pool.submit(store.upload_finish, 'one', upload)
            try:
                self.assertTrue(entered.wait(2))
                start = time.monotonic()
                store.mutate('one', self.mutation())
                self.assertLess(time.monotonic() - start, .2)
            finally:
                release.set()
            self.assertEqual(pending.result()['blob'], blob)

    def test_cached_get_watch_use_canonical_envelopes(self):
        client, events = self.client('one')
        client.request(dict(op='watch', topics=['clipboard']))
        client.request(self.mutation())
        until(lambda: any(e.get('changed') == ['entry'] for e in events))
        client.close()
        response = client.request(dict(op='get', topic='clipboard'))
        self.assertTrue(response['ok'])
        self.assertNotIn('event', response)
        client.request(dict(id='cached-stream', op='watch', topics=['clipboard']))
        event = events[-1]
        self.assertEqual(event['event'], 'snapshot')
        self.assertEqual(event['watchId'], 'cached-stream')
        self.assertNotIn('ok', event)
        # Also cover cache seeded from get, without a prior subscription.
        with client.db() as db:
            self.assertEqual(set(json.loads(db.execute('SELECT value FROM snapshots').fetchone()[0])), {'topic', 'revision', 'items'})
        other, other_events = self.client('two')
        other.request(dict(op='get', topic='clipboard'))
        other.close()
        other.request(dict(id='get-cache-stream', op='watch', topics=['clipboard']))
        self.assertEqual(other_events[-1]['event'], 'snapshot')
        self.assertEqual(other_events[-1]['watchId'], 'get-cache-stream')

    def test_deleted_patch_stale_replay_and_explicit_new_capture(self):
        store = Store(self.root / 'server')
        original = self.mutation()
        store.mutate('one', original)
        deleted = store.mutate('two', dict(op='delete', topic='clipboard', key='entry', mutationId='delete'))
        with self.assertRaisesRegex(ValueError, 'missing or deleted'):
            store.mutate('one', dict(op='patch', topic='clipboard', key='entry', payload=dict(pinned=True), mutationId='delayed-pin', replayed=True))
        stale = dict(original, mutationId='delayed-put', replayed=True, expectedRevision=1)
        with self.assertRaisesRegex(ValueError, 'stale upsert'):
            store.mutate('one', stale)
        with self.assertRaisesRegex(ValueError, 'new capture'):
            store.mutate('one', dict(stale, expectedRevision=deleted['revision']))
        fresh = dict(stale, expectedRevision=deleted['revision'], payload=dict(original['payload'], capturedAt=time.time() + .01))
        revision = store.mutate('one', fresh)['revision']
        self.assertEqual(len(store.snapshot('clipboard')['items']), 1)
        with self.assertRaisesRegex(ValueError, 'stale upsert'):
            store.mutate('one', dict(fresh, mutationId='older-live-replay', expectedRevision=revision - 1))

    def test_superseded_session_cannot_receive_or_ack(self):
        old_events, new_events = [], []
        old = server_module.Session(self.root / 'server', 'target', old_events.append)
        source = server_module.Session(self.root / 'server', 'source', lambda event: None)
        self.sessions.extend([old, source])
        old.request(dict(op='watch', topics=['media']))
        with old.lock:
            pending = source.request(dict(op='send_command', target='target', action='play'))
            replacement = server_module.Session(self.root / 'server', 'target', new_events.append)
            self.sessions.append(replacement)
            replacement.request(dict(op='watch', topics=['media']))
        time.sleep(.2)
        self.assertFalse(any(e.get('commandId') == pending['commandId'] for e in old_events))
        with self.assertRaises(ValueError):
            old.request(dict(op='ack_command', commandId=pending['commandId'], ok=True))
        current = source.request(dict(op='send_command', target='target', action='pause'))
        until(lambda: any(e.get('commandId') == current['commandId'] for e in new_events))
        newest = server_module.Session(self.root / 'server', 'target', lambda event: None)
        self.sessions.append(newest)
        newest.request(dict(op='watch', topics=['media']))
        with self.assertRaises(ValueError):
            replacement.request(dict(op='ack_command', commandId=current['commandId'], ok=True))

    def test_payload_privacy_ownership_and_merged_validation(self):
        store = Store(self.root / 'server')
        task = dict(taskId='job', host='one', agent='worker', title='task', status='running', progress=0, summary='', updatedAt=time.time())
        base = dict(op='put', topic='tasks', key='one:job', payload=task, mutationId='task')
        store.mutate('one', base)
        for invalid in [dict(base, key='two:job'), dict(base, payload=dict(task, host='two')), dict(base, payload=dict(task, tokens='private')), dict(base, payload=dict(task, permissionAnswer='yes')), dict(base, payload=dict(task, progress=True))]:
            with self.assertRaises(ValueError):
                store.mutate('one', dict(invalid, mutationId='invalid'))
        with self.assertRaises(ValueError):
            store.mutate('one', dict(op='patch', topic='tasks', key='one:job', payload=dict(taskId='other'), mutationId='bad-merge'))
        media = dict(host='one', title='', artist='', album='', playing=False, duration=0, position=0, available=True, updatedAt=time.time())
        store.mutate('one', dict(op='put', topic='media', key='one', payload=media, mutationId='media'))
        with self.assertRaises(ValueError):
            store.mutate('two', dict(op='delete', topic='media', key='one', mutationId='wrong-peer-delete'))
        # Offline invalid input must never enter persistent outbox, including top-level data.
        client, events = self.client('one')
        client.request(dict(op='get', topic='tasks'))
        client.close()
        for request in [dict(base, payload=dict(task, permissionAnswer='yes')), dict(base, tokens='private'), dict(op='patch', topic='tasks', key='one:job', payload=dict(host='two'), mutationId='bad-host')]:
            with self.assertRaises(ValueError):
                client.request(request)
        with client.db() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM outbox').fetchone()[0], 0)
        # Optional contract blob fields remain valid after verified staging.
        data = b'markdown'
        blob = dict(name='note.md', size=len(data), sha256=hashlib.sha256(data).hexdigest())
        upload = store.upload_start('one', blob)['uploadId']
        store.upload_chunk('one', upload, 0, base64.b64encode(data).decode())
        store.upload_finish('one', upload)
        store.mutate('one', dict(op='put', topic='links', key='note', payload=dict(title='note', url='local-note', note='', createdAt=time.time(), blob=blob, sync=False), mutationId='link'))
        store.mutate('one', dict(base, payload=dict(task, blob=blob), mutationId='task-result'))

    def test_cache_revision_comparison_and_pending_overlay(self):
        client, events = self.client('one')
        item = dict(id='entry', origin='two', updatedAt=time.time(), payload=self.mutation()['payload'])
        older = dict(topic='clipboard', revision=10, items=[item])
        newer = dict(topic='clipboard', revision=11, items=[])
        client._cache_authoritative(newer)
        # A delayed get completes after the newer snapshot event.
        with patch.object(client, '_rpc', return_value=dict(older, ok=True)):
            response = client.request(dict(op='get', topic='clipboard'))
        self.assertEqual(response['revision'], 11)
        self.assertEqual(response['items'], [])
        client.close()
        queued = self.mutation('offline')
        client.request(queued)
        client._cache_authoritative(dict(topic='clipboard', revision=12, items=[]))
        response = client.request(dict(op='get', topic='clipboard'))
        self.assertEqual(response['revision'], 12)
        self.assertEqual(response['items'][0]['id'], 'offline')
        self.assertTrue(response['queued'])
        with client.db() as db:
            self.assertEqual(json.loads(db.execute('SELECT value FROM snapshots').fetchone()[0])['items'], [])

    def test_query_only_same_peer_session_preserves_media_watcher(self):
        watcher, events = self.client('one')
        source, _ = self.client('two')
        watcher.request(dict(op='watch', topics=['media']))
        for operation in [dict(op='get', topic='media'), dict(op='desk', request=dict(command='status'))]:
            self.assertTrue(client_module.one_shot(self.config('one'), operation)['ok'])
        sent = source.request(dict(op='send_command', target='one', action='play'))
        until(lambda: any(e.get('commandId') == sent['commandId'] for e in events))
        watcher.request(dict(op='ack_command', commandId=sent['commandId'], ok=True))
        replacement, replacement_events = self.client('one')
        replacement.request(dict(op='watch', topics=['media']))
        sent = source.request(dict(op='send_command', target='one', action='pause'))
        until(lambda: any(e.get('commandId') == sent['commandId'] for e in replacement_events))
        self.assertFalse(any(e.get('commandId') == sent['commandId'] for e in events))

    def test_download_lock_is_process_safe_and_reserve_checked_inside(self):
        client, _ = self.client('one')
        blob = dict(name='file.bin', size=5, sha256=hashlib.sha256(b'hello').hexdigest())
        lock_path = client.cache_root / 'downloads.lock'
        script = "import fcntl,sys; f=open(sys.argv[1],'a+b'); fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); sys.stdin.readline()"
        holder = subprocess.Popen([sys.executable, '-c', script, str(lock_path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        entered = threading.Event()
        try:
            self.assertEqual(holder.stdout.readline().strip(), 'locked')
            with patch.object(client, '_fetch_blob_locked', side_effect=lambda *args: entered.set()), ThreadPoolExecutor() as pool:
                pending = pool.submit(client.fetch_blob, blob)
                self.assertFalse(entered.wait(.15))
                holder.communicate('release\n', timeout=2)
                pending.result(timeout=2)
                self.assertTrue(entered.is_set())
        finally:
            if holder.poll() is None:
                holder.kill()
                holder.wait()
        from continuity_store import RESERVE
        with patch('shutil.disk_usage') as usage:
            usage.return_value.free = RESERVE + blob['size'] - 1
            with patch.object(client, '_rpc') as rpc:
                with self.assertRaisesRegex(ValueError, 'reserve'):
                    client.fetch_blob(blob)
                rpc.assert_not_called()

    def _queue_shelf_edits(self, peer, explicit=False):
        store = Store(self.root / 'server')
        payload = dict(kind='text', name='note', text='original', createdAt=time.time())
        revision = store.mutate('seed', dict(op='put', topic='shelf', key=peer, payload=payload, mutationId='seed-' + peer))['revision']
        client, _ = self.client(peer)
        client.request(dict(op='get', topic='shelf'))
        client.close()
        requests = []
        for index, text in enumerate(('first edit', 'latest accepted edit')):
            request = dict(op='put', topic='shelf', key=peer, payload=dict(payload, text=text), mutationId=peer + '-' + str(index))
            if explicit:
                request['expectedRevision'] = revision
            self.assertTrue(client.request(request)['queued'])
            requests.append(request)
        return store, client, requests

    def test_successive_offline_puts_survive_restart_with_or_without_revision(self):
        for explicit in (False, True):
            with self.subTest(explicit=explicit):
                peer = 'explicit' if explicit else 'implicit'
                store, old, requests = self._queue_shelf_edits(peer, explicit)
                with old.db() as db:
                    wires = [json.loads(row[0]) for row in db.execute('SELECT value FROM outbox ORDER BY created,id')]
                self.assertEqual(wires[1]['parentMutationId'], requests[0]['mutationId'])
                self.assertEqual(wires[0]['expectedRevision'], wires[1]['expectedRevision'])
                replacement, events = self.client(peer)
                item = next(item for item in store.snapshot('shelf')['items'] if item['id'] == peer)
                self.assertEqual(item['payload']['text'], 'latest accepted edit')
                with replacement.db() as db:
                    self.assertEqual(db.execute('SELECT COUNT(*) FROM outbox').fetchone()[0], 0)
                    self.assertEqual(db.execute('SELECT COUNT(*) FROM conflicts').fetchone()[0], 0)
                # Retrying the original public request keeps derived wire identity stable.
                self.assertTrue(replacement.request(requests[-1])['duplicate'])

    def test_uncertain_committed_parent_replays_identically_before_latest_intent(self):
        store, old, requests = self._queue_shelf_edits('uncertain')
        with old.db() as db:
            first_wire = json.loads(db.execute('SELECT value FROM outbox ORDER BY created,id LIMIT 1').fetchone()[0])
        committed = store.mutate('uncertain', first_wire)
        replacement, events = self.client('uncertain')
        item = next(item for item in store.snapshot('shelf')['items'] if item['id'] == 'uncertain')
        self.assertEqual(item['payload']['text'], 'latest accepted edit')
        self.assertEqual(store.snapshot('shelf')['revision'], committed['revision'] + 1)
        self.assertFalse(any(e.get('event') == 'mutation_error' for e in events))
        self.assertTrue(replacement.request(requests[0])['duplicate'])

    def test_uncertain_live_put_cannot_be_overtaken_by_next_accepted_put(self):
        client, events = self.client('timeout')
        payload = dict(kind='text', name='note', text='original', createdAt=time.time())
        client.request(dict(op='put', topic='shelf', key='timeout', payload=payload, mutationId='timeout-seed'))
        store = Store(self.root / 'server')
        seen = []
        def lost_ack(request, timeout=15):
            seen.append(request['mutationId'])
            store.mutate('timeout', request)
            raise client_module.Unavailable('lost acknowledgement')
        with patch.object(client, '_rpc', side_effect=lost_ack), patch.object(client, '_reconnect_for_replay') as reconnect:
            first = dict(op='put', topic='shelf', key='timeout', payload=dict(payload, text='first'), mutationId='timeout-first')
            latest = dict(first, payload=dict(payload, text='latest'), mutationId='timeout-latest')
            self.assertTrue(client.request(first)['queued'])
            self.assertTrue(client.request(latest)['queued'])
            self.assertEqual(seen, ['timeout-first'])
            self.assertEqual(reconnect.call_count, 2)
        client.close()
        replacement, events = self.client('timeout')
        self.assertEqual(store.snapshot('shelf')['items'][0]['payload']['text'], 'latest')
        self.assertFalse(any(e.get('event') == 'mutation_error' for e in events))

    def test_conflicting_remote_delete_wins_and_retains_latest_offline_payload(self):
        store, old, requests = self._queue_shelf_edits('deleted', explicit=True)
        deleted = store.mutate('remote', dict(op='delete', topic='shelf', key='deleted', mutationId='remote-delete'))
        replacement, events = self.client('deleted')
        self.assertEqual(store.snapshot('shelf')['items'], [])
        self.assertEqual(store.snapshot('shelf')['revision'], deleted['revision'])
        errors = [event for event in events if event.get('event') == 'mutation_error']
        self.assertEqual(len(errors), 2)
        self.assertTrue(all(event['recoverable'] for event in errors))
        summaries = replacement.request(dict(op='conflicts'))['conflicts']
        self.assertEqual({item['mutationId'] for item in summaries}, {request['mutationId'] for request in requests})
        latest = replacement.request(dict(op='conflicts', mutationId=requests[-1]['mutationId']))['conflict']
        self.assertEqual(latest['request']['payload']['text'], 'latest accepted edit')
        self.assertNotIn('parentMutationId', latest['request'])
        with replacement.db() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM outbox').fetchone()[0], 0)
        replacement.request(dict(op='discard_conflict', mutationId=requests[-1]['mutationId']))
        self.assertIsNone(replacement.request(dict(op='conflicts', mutationId=requests[-1]['mutationId']))['conflict'])

    def test_remote_delete_between_causal_parent_and_child_still_wins(self):
        store, old, requests = self._queue_shelf_edits('interrupted')
        with old.db() as db:
            first_wire = json.loads(db.execute('SELECT value FROM outbox ORDER BY created,id LIMIT 1').fetchone()[0])
        store.mutate('interrupted', first_wire)
        store.mutate('remote', dict(op='delete', topic='shelf', key='interrupted', mutationId='between-delete'))
        replacement, events = self.client('interrupted')
        self.assertEqual(store.snapshot('shelf')['items'], [])
        latest = replacement.request(dict(op='conflicts', mutationId=requests[-1]['mutationId']))['conflict']
        self.assertEqual(latest['request']['payload']['text'], 'latest accepted edit')

    def test_protocol_rejects_oversize_frame(self):
        process = subprocess.run([sys.executable, str(INTEGRATIONS / 'continuity-server.py'), '--stdio', '--peer', 'one', '--root', str(self.root / 'server')], input=b'x' * (FRAME + 1), capture_output=True, timeout=10)
        self.assertIn('frame too large', json.loads(process.stdout)['error'])

if __name__ == '__main__':
    unittest.main()
