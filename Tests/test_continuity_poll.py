"""Idle poll cost and freshness regressions for the persistent server."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

p=Path(__file__).resolve().parents[1]/'Integrations'/'continuity-server.py'
spec=importlib.util.spec_from_file_location('poll_server',p)
server=importlib.util.module_from_spec(spec);spec.loader.exec_module(server)

class PollTests(unittest.TestCase):
    def test_idle_skips_large_snapshots_changed_topic_and_commands_remain_fresh(self):
        with tempfile.TemporaryDirectory() as root:
            events=[];session=server.Session(Path(root).resolve(),'mac',events.append)
            session.closed.set();session.poller.join()
            try:
                session.request(dict(op='put',topic='clipboard',key='large',mutationId='large-1',payload=dict(kind='text',text='a'*200000,capturedAt=1)))
                session.request(dict(op='watch'))
                session._poll_once();events.clear()
                with patch.object(session.store,'snapshot',wraps=session.store.snapshot) as snapshot,patch.object(server.time,'monotonic',return_value=1):
                    session.next_heartbeat=2;session.next_cleanup=30
                    with session.store.db() as db:before=db.execute('SELECT heartbeat FROM sessions').fetchone()[0]
                    for _ in range(25):session._poll_once()
                    snapshot.assert_not_called()
                    with session.store.db() as db:after=db.execute('SELECT heartbeat FROM sessions').fetchone()[0]
                    self.assertEqual(before,after)
                    session.request(dict(op='put',topic='links',key='link',mutationId='link-1',payload=dict(title='test',url='https://example.test',note='',createdAt=1)))
                    session._poll_once();snapshot.assert_called_once_with('links')
                    self.assertEqual(events[0]['topic'],'links');self.assertEqual(events[0]['changed'],['link'])
                    command=session.request(dict(op='send_command',target='mac',action='play'))
                    session._poll_once()
                    self.assertEqual(events[-1]['event'],'command');self.assertEqual(events[-1]['commandId'],command['commandId'])
                    session.request(dict(op='ack_command',commandId=command['commandId'],ok=True))
                    self.assertEqual(len(events),2)
            finally:session.close()

if __name__=='__main__':unittest.main()
