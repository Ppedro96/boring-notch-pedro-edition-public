import base64
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

INTEGRATIONS=Path(__file__).resolve().parents[1]/'Integrations'
sys.path.insert(0,str(INTEGRATIONS))
import continuity_desk as adapter
from continuity_store import Store

def module(name,file):
    spec=importlib.util.spec_from_file_location(name,INTEGRATIONS/file)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value

h=module('shared_desk_hub','desk-hub.py')
c=module('shared_desk_client','continuity-client.py')

class SharedDeskTests(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        self.base=Path(temp.name).resolve();self.root=self.base/'queue';self.root.mkdir()
        self.shared=self.base/'shared';self.store=Store(self.shared)
        for name,value in [('ROOT',self.root),('STATE',self.root/'desk-jobs'),('RESULTS',self.base/'results')]:
            p=patch.object(h,name,value);p.start();self.addCleanup(p.stop)
        self.input=self.base/'Vídeo original.mp4';self.input.write_bytes(b'synthetic input')
        self.blob=dict(sha256=h.digest(self.input),size=self.input.stat().st_size,name=self.input.name)
        self.store.blobs.joinpath(self.blob['sha256']).write_bytes(self.input.read_bytes())
        self.store.blobs.joinpath(self.blob['sha256']).chmod(0o600)

    def request(self,command,peer='mac',**kw):
        return dict(command=command,_continuityPeer=peer,_continuityRoot=str(self.shared),**kw)

    def submit(self,peer='mac',host='x99'):
        with patch.object(h,'capabilities',return_value=dict(online=True,ffmpeg=True)),patch.object(h,'start_queue'):
            return h.local_main(self.request('submit',peer,host=host,operation='video',blob=self.blob))['id']

    def test_remote_source_rejected_blob_retained_and_authenticated_provenance(self):
        with self.assertRaisesRegex(ValueError,'source paths'):
            h.local_main(self.request('submit',source=str(self.input),blob=self.blob))
        ident=self.submit();job=h.read_job(ident)
        self.assertEqual(job['name'],self.input.name);self.assertEqual(job['origin'],'mac')
        self.input.unlink()
        with patch.object(h,'start_queue'):
            jobs=h.local_main(self.request('jobs','x99'))['jobs']
        self.assertEqual(jobs[0]['id'],ident);self.assertNotIn('source',jobs[0])
        self.assertTrue(Path(job['source']).is_file())
        Path(job['source']).write_bytes(b'corruption')
        with self.assertRaisesRegex(ValueError,'verification'):self.submit()

    def test_fifo_all_executors_names_results_archive_retry_from_other_origin(self):
        ids=[self.submit('mac'),self.submit('x99'),self.submit('mac','alienware'),self.submit('x99','mac')]
        started=[];output=self.base/'worker-result.mp4';output.write_bytes(b'verified output')
        def rpc(host,req,timeout=20):
            if req['command']=='prepare':
                self.assertEqual(req['extension'],'.mp4');return dict(path=str(self.base/req['id']))
            if req['command']=='start':started.append((host,req['id']))
            if req['command']=='status':return dict(state='completed',output=str(output),sha256=h.digest(output))
            return dict(ok=True)
        def copy(host,src,dest,**kwargs):Path(dest).write_bytes(Path(src).read_bytes())
        with patch.object(h,'rpc',side_effect=rpc),patch.object(h,'scp',side_effect=copy):
            for host in ('x99','alienware','mac'):h.queue(host)
        self.assertEqual([ident for host,ident in started if host=='x99'],ids[:2])
        self.assertEqual({host for host,_ in started},set(h.HOSTS))
        for ident in ids:self.assertEqual(h.read_job(ident)['state'],'completed')
        result=h.local_main(self.request('result','x99',id=ids[0]))
        self.assertEqual(result['blob']['name'],self.input.name)
        self.assertEqual((self.store.blobs/result['blob']['sha256']).read_bytes(),output.read_bytes())
        h.local_main(self.request('archive','x99'))
        self.assertEqual(h.local_main(self.request('result','mac',id=ids[0]))['blob'],result['blob'])
        with patch.object(h,'capabilities',return_value=dict(online=True,ffmpeg=True)),patch.object(h,'start_queue'):
            retry=h.local_main(self.request('retry','x99',id=ids[0]))
        job=h.read_job(retry['id']);self.assertEqual(job['origin'],'mac');self.assertEqual(job['submittedBy'],'x99')
        self.assertEqual(job['retryOf'],ids[0]);self.assertEqual(job['blob'],self.blob)
        Path(h.read_job(ids[0])['output']).write_bytes(b'altered later')
        with self.assertRaisesRegex(ValueError,'integrity'):h.local_main(self.request('result',id=ids[0]))

    def test_cancellation_during_final_transfer_wins_without_stale_metadata(self):
        ident=self.submit();path=h.jobpath(ident)
        def rpc(host,req,timeout=20):
            if req['command']=='prepare':return dict(path=str(self.base/'remote'))
            if req['command']=='status':return dict(state='completed',output='/worker/out.mp4',sha256='f'*64)
            return dict(ok=True)
        def receive(*args,**kwargs):
            h.local_main(self.request('cancel','x99',id=ident))
            return str(self.base/'out.mp4')
        with patch.object(h,'rpc',side_effect=rpc),patch.object(h,'scp'),patch.object(h,'retrieve',side_effect=receive):h.queue('x99')
        self.assertEqual(h.read_job(ident)['state'],'cancelled')
        # Late cancel is a read-only no-op on any terminal result.
        job=h.read_job(ident);job.update(state='completed',output='keep');h.save(path,job)
        before=path.read_bytes();h.local_main(self.request('cancel',id=ident));self.assertEqual(path.read_bytes(),before)

    def test_running_cancel_offline_is_persistent_and_poll_does_not_spawn_locked_queue(self):
        ident=self.submit();job=h.read_job(ident);job.update(state='running',remoteStarted=True);h.save(h.jobpath(ident),job)
        with patch.object(h,'rpc',side_effect=RuntimeError('offline')),patch.object(h,'start_queue'):
            self.assertTrue(h.local_main(self.request('cancel',id=ident))['cancelPending'])
        self.assertTrue(h.jobpath(ident).with_suffix('.cancel').exists())
        with (h.STATE/'queue-x99.lock').open('a') as lock,patch.object(h.subprocess,'Popen') as popen:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            for _ in range(4):h.local_main(self.request('jobs'))
            popen.assert_not_called()

    def test_offline_cancel_recovery_and_restart_deliver_before_next_job(self):
        first=self.submit();second=self.submit()
        job=h.read_job(first);job.update(state='running',remoteStarted=True);h.save(h.jobpath(first),job)
        with patch.object(h,'rpc',side_effect=RuntimeError('offline')),patch.object(h,'start_queue'):
            reply=h.local_main(self.request('cancel',id=first))
        self.assertTrue(reply['cancelPending']);self.assertEqual(h.read_job(first)['state'],'running')
        events=[];online=False
        def rpc(host,r,timeout=20):
            if r['command']=='cancel':
                events.append('cancel-attempt')
                if not online:raise RuntimeError('still offline')
                events.append('cancel-ack');return dict(ok=True)
            if r['command']=='prepare':return dict(path=str(self.base/'remote'))
            if r['command']=='start':events.append('start-next');return dict(ok=True)
            if r['command']=='status':return dict(state='failed',detail='synthetic terminal')
            raise AssertionError(r)
        def recover(delay):
            nonlocal online
            self.assertEqual(h.read_job(first)['state'],'running')
            self.assertTrue(h.read_job(first)['cancelPending'])
            self.assertEqual(h.read_job(second)['state'],'waiting')
            online=True
        with patch.object(h,'rpc',side_effect=rpc),patch.object(h,'scp'),patch.object(h.time,'sleep',side_effect=recover):
            h.queue('x99')  # new worker instance after original GUI/worker exit
        self.assertEqual(h.read_job(first)['state'],'cancelled')
        self.assertTrue(h.read_job(first)['cancelAcknowledged'])
        self.assertLess(events.index('cancel-ack'),events.index('start-next'))

    def test_start_reply_loss_is_durable_and_fenced_before_terminal(self):
        ident=self.submit();attempts=[]
        def rpc(host,r,timeout=20):
            if r['command']=='prepare':return dict(path=str(self.base/'remote'))
            if r['command']=='start':
                stored=h.read_job(ident)
                self.assertTrue(stored['remoteStarted']);self.assertEqual(stored['remotePhase'],'starting')
                attempts.append('start-possibly-running');raise RuntimeError('reply lost')
            if r['command']=='cancel':
                attempts.append('cancel')
                if attempts.count('cancel')==1:raise RuntimeError('offline')
                return dict(ok=True)
            raise AssertionError('must not resubmit uncertain start')
        def waiting(delay):
            self.assertEqual(h.read_job(ident)['state'],'running')
            self.assertTrue(h.read_job(ident)['cancelPending'])
        with patch.object(h,'rpc',side_effect=rpc),patch.object(h,'scp'),patch.object(h.time,'sleep',side_effect=waiting):h.queue('x99')
        self.assertEqual(attempts,['start-possibly-running','cancel','cancel'])
        self.assertEqual(h.read_job(ident)['state'],'cancelled')
        self.assertTrue(h.read_job(ident)['cancelAcknowledged'])

    def test_restart_after_possible_start_and_cancel_never_reissues_start(self):
        ident=self.submit();job=h.read_job(ident)
        job.update(state='running',remoteStarted=True,remotePhase='starting');h.save(h.jobpath(ident),job)
        h.jobpath(ident).with_suffix('.cancel').touch()
        calls=[]
        def rpc(host,r,timeout=20):calls.append(r['command']);return dict(ok=True)
        with patch.object(h,'rpc',side_effect=rpc):h.queue('x99')
        self.assertEqual(calls,['cancel']);self.assertEqual(h.read_job(ident)['state'],'cancelled')

    def test_drain_submit_barrier_guarantees_successor_without_gui_poll(self):
        empty=threading.Event();release=threading.Event();submit_started=threading.Event();admitting=threading.Event()
        errors=[];children=[];submitted=[];original=h.entries;first=[True];original_admission=h.admission_lock
        @contextmanager
        def admission(host):
            if threading.current_thread().name=='producer':admitting.set()
            with original_admission(host):yield
        def worker(fd=None):
            try:h.queue('x99',fd)
            except Exception as error:errors.append(error)
        def entries():
            result=original()
            if first[0] and threading.current_thread().name=='draining':
                first[0]=False;self.assertEqual(result,[]);empty.set()
                if not release.wait(3):raise AssertionError('barrier timeout')
            return result
        def spawn(args,**kwargs):
            fd=os.dup(kwargs['pass_fds'][0])
            child=threading.Thread(target=lambda:worker(fd),name='successor')
            children.append(child);child.start();return Mock()
        def rpc(host,r,timeout=20):
            if r['command']=='prepare':return dict(path=str(self.base/'remote'))
            if r['command']=='status':return dict(state='failed',detail='executed')
            return dict(ok=True)
        def submit():
            submit_started.set()
            try:submitted.append(h.local_main(self.request('submit',host='x99',operation='video',blob=self.blob)))
            except Exception as error:errors.append(error)
        with patch.object(h,'admission_lock',side_effect=admission),patch.object(h,'entries',side_effect=entries),patch.object(h.subprocess,'Popen',side_effect=spawn) as popen,patch.object(h,'capabilities',return_value=dict(online=True,ffmpeg=True)),patch.object(h,'rpc',side_effect=rpc),patch.object(h,'scp'):
            draining=threading.Thread(target=worker,name='draining');draining.start()
            self.assertTrue(empty.wait(3))
            producer=threading.Thread(target=submit,name='producer');producer.start();self.assertTrue(submit_started.wait(3));self.assertTrue(admitting.wait(3))
            # The producer cannot publish while the final empty check owns admission.
            self.assertEqual(original(),[])
            release.set();draining.join(3);producer.join(3)
            for child in children:child.join(3)
            self.assertFalse(draining.is_alive());self.assertFalse(producer.is_alive())
            self.assertFalse(errors);self.assertEqual(popen.call_count,1)
        self.assertEqual(len(submitted),1)
        self.assertEqual(h.read_job(submitted[0]['id'])['state'],'failed')
        self.assertEqual(h.read_job(submitted[0]['id'])['detail'],'executed')

    def test_no_split_brain_routing_and_local_search_preserved(self):
        with patch.object(adapter,'enabled',return_value=True),patch.object(h,'local_main') as local,patch.object(c.Client,'_rpc',side_effect=c.Unavailable('offline')):
            # Injecting a fake marker into main cannot bypass shared routing.
            with patch.object(adapter,'config_path',return_value=self.base/'disabled.json'):
                with self.assertRaisesRegex(RuntimeError,'disabled'):h.main(dict(command='jobs',_continuityPeer='fake'))
            local.assert_not_called()
            h.main(dict(command='search',query='literal'));local.assert_called_once()

    def test_authoritative_layout_topic_updates_only_when_state_changes(self):
        with patch.object(h,'deskflow',return_value=dict(ok=True,layout='alienware-left',active=True,inputMode='mesh')):
            h.local_main(self.request('deskflow',action='status'))
            first=self.store.snapshot('desk')
            h.local_main(self.request('deskflow','x99',action='status'))
            self.assertEqual(self.store.snapshot('desk')['revision'],first['revision'])
        with patch.object(h,'deskflow',return_value=dict(ok=True,layout='alienware-left',active=False,inputMode='mesh')):
            h.local_main(self.request('deskflow','x99',action='stop'))
        last=self.store.snapshot('desk')
        self.assertGreater(last['revision'],first['revision'])
        self.assertFalse(last['items'][0]['payload']['active'])
        self.assertEqual(last['items'][0]['payload']['layout'],'alienware-left')

    def test_native_adapter_reuses_client_keeps_nested_id_and_local_download(self):
        fake=Mock();fake.stage_file.return_value=self.blob
        fake.request.return_value=dict(ok=True,result=dict(ok=True,id='a'*32))
        result=adapter.native(fake,dict(command='submit',source=str(self.input),host='x99',operation='video'),30)
        self.assertEqual(result['result']['id'],'a'*32);self.assertNotIn('id',result)
        wire=fake.request.call_args.args[0];self.assertNotIn('source',wire['request']);self.assertEqual(wire['request']['blob'],self.blob)
        fake.request.return_value=dict(ok=True,result=dict(ok=True,blob=self.blob,id='a'*32))
        fake.fetch_blob.return_value=self.input
        self.assertEqual(adapter.native(fake,dict(command='result',id='a'*32))['result']['output'],str(self.input))
        with patch.object(adapter,'broker',return_value=h):
            fake.request.return_value=dict(ok=True,result=dict(ok=True,jobs=[]))
            adapter.native(fake,dict(command='jobs'))
        self.assertEqual(fake.stage_file.call_count,1)

    def test_mac_remote_generated_path_and_linux_legacy_recursion_guard(self):
        with patch.object(h,'LOCAL_HOST','x99'),patch.object(h.subprocess,'run',return_value=Mock(returncode=0,stdout='{"ok":true}')) as run:
            h.scp('mac','/Users/example/.local/share/insight-notch/jobs/'+('a'*32)+'/result.mp4','/tmp/local')
            with self.assertRaises(ValueError):h.scp('mac','/Users/example/.local/share/pedro-notch/jobs/'+('a'*32)+'/result.mp4','/tmp/local')
            h.legacy_deskflow(dict(action='status'))
            code=run.call_args.args[0][-1].split("b64decode('")[1].split("')")[0]
            script=base64.b64decode(code).decode()
            self.assertIn('m.legacy_deskflow(',script);self.assertNotIn('m.main(',script)

    def test_real_two_peer_persistent_transport_staging_shared_result_and_local_cache(self):
        wrapper=self.base/'broker.py'
        wrapper.write_text('import importlib.util\nfrom pathlib import Path\n'
            +f's=importlib.util.spec_from_file_location("hub",{str(INTEGRATIONS/"desk-hub.py")!r})\n'
            +'h=importlib.util.module_from_spec(s);s.loader.exec_module(h)\n'
            +f'h.ROOT=Path({str(self.root)!r});h.STATE=h.ROOT/"desk-jobs"\n'
            +'h.start_queue=lambda:None\nh.capabilities=lambda host:dict(online=True,ffmpeg=True)\nlocal_main=h.local_main\n')
        (self.shared/'config.json').write_text(json.dumps(dict(broker=dict(script=str(wrapper)))))
        def cfg(peer):return dict(enabled=True,peer=peer,cache=str(self.base/('cache-'+peer)),server=dict(argv=[sys.executable,str(INTEGRATIONS/'continuity-server.py'),'--stdio','--peer',peer,'--root',str(self.shared)]))
        with c.Client(cfg('mac')) as first,c.Client(cfg('x99')) as second:
            self.assertTrue(first.connected.wait(5));self.assertTrue(second.connected.wait(5))
            child=first.child
            submit=first.request(dict(op='desk_local',request=dict(command='submit',source=str(self.input),host='x99',operation='video')),10)
            ident=submit['result']['id']
            with patch.object(adapter,'broker',return_value=h):
                listed=second.request(dict(op='desk_local',request=dict(command='jobs')),10)
            self.assertEqual(listed['result']['jobs'][0]['id'],ident)
            self.assertIs(first.child,child)
            output=self.base/'final.mp4';output.write_bytes(b'synthetic final')
            job=h.read_job(ident);job.update(state='completed',output=str(output),resultSha256=h.digest(output));h.save(h.jobpath(ident),job)
            a=first.request(dict(op='desk_local',request=dict(command='result',id=ident)),10)['result']
            b=second.request(dict(op='desk_local',request=dict(command='result',id=ident)),10)['result']
            self.assertNotEqual(a['output'],b['output']);self.assertEqual(Path(a['output']).read_bytes(),output.read_bytes())
            self.assertEqual(Path(b['output']).read_bytes(),output.read_bytes())
            self.assertTrue(Path(a['output']).is_file());self.assertEqual(Path(a['output']).name,self.input.name)
            first.close()
            self.assertEqual(first.fetch_blob(a['blob']).read_bytes(),output.read_bytes())

if __name__=='__main__':unittest.main()
