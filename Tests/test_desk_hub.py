import importlib.util,json,tempfile,unittest
from pathlib import Path
from unittest.mock import patch

def module(name,file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).resolve().parents[1]/'Integrations'/file)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
w=module('worker','desk-worker.py');h=module('hub','desk-hub.py')
class DeskTests(unittest.TestCase):
    def test_rejects_unknown_hosts_and_commands(self):
        for host in ['-oProxyCommand=bad','alienware; touch /tmp/bad','lab']:
            with self.assertRaises(ValueError):h.checkhost(host)
        with self.assertRaises(ValueError):w.main({'command':'shell','args':'bad'})
    def test_job_identifiers_never_escape(self):
        for ident in ['../escape','x'*32,'a'*31,'a'*32+'/bad']:
            with self.assertRaises(ValueError):w.jobdir(ident)
            with self.assertRaises(ValueError):h.jobpath(ident)
    def test_file_scope_and_symlink_escape(self):
        with tempfile.TemporaryDirectory() as root:
            base=Path(root)/'allowed';base.mkdir();((base/'ok.txt').resolve()).write_text('ok');(Path(root)/'secret').write_text('private')
            (base/'escape').symlink_to(Path(root)/'secret');(base/'.hidden').write_text('hidden')
            with patch.object(w,'roots',return_value={'0':str(base)}):
                self.assertEqual(w.safe_file('0','ok.txt'),(base/'ok.txt').resolve())
                for relative in ['../secret',str(Path(root)/'secret'),'escape','.hidden']:
                    with self.assertRaises(ValueError):w.safe_file('0',relative)
    def test_search_literal_unicode_and_no_hidden_or_symlink(self):
        with tempfile.TemporaryDirectory() as root:
            base=Path(root);(base/'Áudio $(touch bad).mp4').write_text('test');(base/'.Áudio private').write_text('no')
            (base/'Áudio-link').symlink_to(base/'Áudio $(touch bad).mp4')
            with patch.object(w,'roots',return_value={'0':str(base)}):
                result=w.search('áudio');self.assertEqual(len(result['results']),1)
                self.assertEqual(result['results'][0]['relative'],'Áudio $(touch bad).mp4')
                self.assertFalse((base/'bad').exists())
    def test_blocked_share_preserves_results_with_bounded_search(self):
        import threading,time
        release=threading.Event()
        def blocked(query,results,state):
            results.append({'name':'healthy.txt','modified':1});state['roots']={'0':'/healthy'}
            release.wait(2)
        try:
            with patch.object(w,'_search',side_effect=blocked),patch.object(w,'SEARCH_TIMEOUT',.03):
                start=time.monotonic();result=w.search('healthy')
                self.assertLess(time.monotonic()-start,.5)
                self.assertTrue(result['truncated']);self.assertEqual(result['results'][0]['name'],'healthy.txt')
        finally:release.set()
    def test_scp_only_generated_remote_paths(self):
        for source in ['C:/Users/user/Downloads/user.txt','/tmp/test','/home/user/.local/share/insight-notch/jobs/'+('a'*32)+'/x;bad']:
            with self.assertRaises(ValueError):h.scp('x99',source,'/tmp/local')
    def test_windows_generated_path_normalization(self):
        from unittest.mock import Mock
        with patch.object(h.subprocess,'run',return_value=Mock(returncode=0)) as call:
            h.scp('alienware','C:\\Users\\user\\.local\\share\\insight-notch\\jobs\\'+('a'*32)+'\\result.mp4','/tmp/test')
            self.assertIn('alienware:C:/Users/user/.local/share/insight-notch/jobs/'+('a'*32)+'/result.mp4',call.call_args.args[0])
    def test_result_integrity_failure_never_publishes(self):
        with tempfile.TemporaryDirectory() as root:
            def copy(host,source,dest):Path(dest).write_bytes(b'corrupt')
            with patch.object(h,'RESULTS',Path(root)),patch.object(h,'scp',side_effect=copy):
                with self.assertRaises(ValueError):h.retrieve('x99','ignored','incorrect','movie.mp4')
                self.assertEqual(list(Path(root).iterdir()),[])
    def test_prepare_never_overwrites_existing_job(self):
        with tempfile.TemporaryDirectory() as root,patch.object(w,'JOBS',Path(root)):
            request=dict(command='prepare',id='a'*32,extension='.mp4;bad')
            self.assertTrue(w.main(request)['path'].endswith('input.bin'))
            with self.assertRaises(FileExistsError):w.main(request)
    def test_cancel_is_persistent_and_separate_from_progress(self):
        with tempfile.TemporaryDirectory() as root,patch.object(h,'STATE',Path(root)):
            ident='a'*32;h.save(h.jobpath(ident),dict(id=ident,state='waiting',host='mac'))
            h.main(dict(command='cancel',id=ident))
            self.assertTrue(h.jobpath(ident).with_suffix('.cancel').exists())
            self.assertEqual(json.loads(h.jobpath(ident).read_text())['state'],'cancelled')
    def test_missing_model_is_not_advertised(self):
        with patch.object(w,'local_models',return_value=[]):self.assertFalse(w.capabilities()['transcribe'])
    def test_remote_search_values_only_travel_over_json_stdin(self):
        from unittest.mock import Mock
        query='name; $(echo bad) "quoted"'
        with patch.object(h.subprocess,'run',return_value=Mock(stdout='{"ok":true}',stderr='')) as call:
            h.rpc('alienware',dict(command='search',query=query))
            self.assertEqual(json.loads(call.call_args.kwargs['input'])['query'],query)
            self.assertNotIn(query,' '.join(call.call_args.args[0]))
    def test_auto_uses_available_machine_with_shortest_queue(self):
        with tempfile.TemporaryDirectory() as root:
            source=Path(root)/'video.mp4';source.write_bytes(b'fixture')
            with patch.object(h,'entries',return_value=[dict(host='x99',state='running')]),patch.object(h,'capabilities',return_value=dict(online=True,ffmpeg=True)),patch.object(h,'save') as save,patch.object(h,'start_queue'):
                h.main(dict(command='submit',host='auto',source=str(source),operation='video'))
                self.assertEqual(save.call_args.args[1]['host'],'alienware')
    def test_interrupted_worker_is_not_reported_running_forever(self):
        with tempfile.TemporaryDirectory() as root,patch.object(w,'JOBS',Path(root)):
            ident='a'*32;directory=w.jobdir(ident);directory.mkdir()
            w.write(directory/'status.json',dict(id=ident,state='running',pid=999999999))
            with patch.object(w.os,'kill',side_effect=ProcessLookupError()):
                result=w.main(dict(command='status',id=ident))
                self.assertEqual(result['state'],'failed')
    def test_cancel_upload_terminates_only_its_child(self):
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as root:
            cancel=Path(root)/'cancel';cancel.touch();child=Mock(poll=Mock(return_value=None))
            with patch.object(h.subprocess,'Popen',return_value=child):
                with self.assertRaises(InterruptedError):h.scp('x99','/tmp/source','/home/user/.local/share/insight-notch/jobs/'+('a'*32)+'/input.mp4',upload=True,cancel=cancel)
                child.terminate.assert_called_once()
    def test_windows_deskflow_uses_no_console_and_preserves_literal_paths(self):
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as root:
            base=Path(root); binary=base/"app with 'quotes'"/'deskflow-core.exe'
            config=base/'config with spaces.ini';pidfile=base/'client.pid';logfile=base/'launch.log'
            child=Mock(pid=4321);child.wait.return_value=0
            launcher=w.deskflow_windows_launcher(binary,config,pidfile,logfile)
            compile(launcher,'deskflow-launch.pyw','exec')
            with patch.object(w.subprocess,'CREATE_NO_WINDOW',0x08000000,create=True),patch.object(w.subprocess,'Popen',return_value=child) as call:
                with self.assertRaises(SystemExit) as stopped:exec(launcher,{'__name__':'__main__'})
            self.assertEqual(stopped.exception.code,0)
            self.assertEqual(call.call_args.args[0],[str(binary),'client','-s',str(config)])
            self.assertEqual(call.call_args.kwargs['creationflags'],0x08000000)
            self.assertFalse(call.call_args.kwargs.get('shell',False))
            self.assertEqual(call.call_args.kwargs['stdin'],w.subprocess.DEVNULL)
            self.assertEqual(call.call_args.kwargs['cwd'],str(binary.parent))
            self.assertIs(call.call_args.kwargs['stdout'],call.call_args.kwargs['stderr'])
            self.assertEqual(pidfile.read_text(),'4321')
            child.wait.assert_called_once()

    def test_windows_deskflow_task_gets_the_client_exit_code(self):
        from unittest.mock import Mock
        with tempfile.TemporaryDirectory() as root:
            base=Path(root);child=Mock(pid=4321);child.wait.return_value=7
            launcher=w.deskflow_windows_launcher(base/'core.exe',base/'client.ini',base/'pid',base/'log')
            with patch.object(w.subprocess,'CREATE_NO_WINDOW',0x08000000,create=True),patch.object(w.subprocess,'Popen',return_value=child):
                with self.assertRaises(SystemExit) as stopped:exec(launcher,{'__name__':'__main__'})
            self.assertEqual(stopped.exception.code,7)

if __name__=='__main__':unittest.main()
