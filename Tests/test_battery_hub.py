import hashlib,http.client,importlib.util,json,tempfile,threading,time,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('battery_hub',Path(__file__).parents[1]/'Integrations/battery-hub/server.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class HubTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.tokens={k:k+'test-token' for k in m.DEVICES};self.store=m.Store(Path(self.temp.name)/'db.sqlite',{k:hashlib.sha256(v.encode()).hexdigest() for k,v in self.tokens.items()})
  self.server=m.create_server('127.0.0.1',0,self.store);self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
 def tearDown(self):self.server.shutdown();self.server.server_close();self.temp.cleanup()
 def request(self,method='GET',kind='s23',payload=None,token=None,path='/v1/batteries'):
  c=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=3);headers={'Authorization':'Bearer '+(self.tokens[kind] if token is None else token)}
  if payload is not None:headers['Content-Type']='application/json'
  c.request(method,path,None if payload is None else json.dumps(payload),headers);r=c.getresponse();value=json.loads(r.read());c.close();return r.status,value
 def test_no_anonymous_read_or_write(self):
  for method in ('GET','PUT'):self.assertEqual(self.request(method,token='wrong',payload={'charge':50,'charging':False} if method=='PUT' else None)[0],401)
 def test_own_identity_bound_to_token_and_snapshot_shared(self):
  self.assertEqual(self.request('PUT',payload={'charge':78,'charging':True})[0],200)
  code,data=self.request(kind='tablet');self.assertEqual(code,200);self.assertEqual(len(data['devices']),6)
  device=next(d for d in data['devices'] if d['kind']=='s23');self.assertEqual(device['charge'],78);self.assertTrue(device['connected'])
  self.assertEqual(self.request('PUT',payload={'kind':'tablet','charge':2,'charging':False})[0],400)
 def test_alienware_has_own_write_identity(self):
  code,data=self.request('PUT',kind='alienware',payload={'charge':78,'charging':False})
  self.assertEqual(code,200)
  value=next(d for d in data['devices'] if d['kind']=='alienware')
  self.assertEqual(value['name'],'Alienware');self.assertEqual(value['charge'],78)
  self.assertTrue(value['connected'])
 def test_invalid_values_and_private_fields_rejected(self):
  for value in [dict(charge=-1,charging=False),dict(charge=True,charging=False),dict(charge=50,charging='false'),dict(charge=50,charging=False,messages=['secret'])]:self.assertEqual(self.request('PUT',payload=value)[0],400)
 def test_no_tokens_or_unrelated_data_in_snapshot(self):
  data=json.dumps(self.request()[1]);self.assertNotIn('token',data);self.assertNotIn('test-token',data);self.assertNotIn('hardware',data)
 def test_age_uses_server_time_and_persists(self):
  self.store.update('s25',{'charge':88,'charging':False})
  with self.store.db() as db:db.execute('UPDATE batteries SET updated=? WHERE kind=?',(time.time()-181,'s25'))
  d=next(d for d in self.store.snapshot()['devices'] if d['kind']=='s25');self.assertFalse(d['connected']);self.assertEqual(d['charge'],88)
  other=m.Store(self.store.path,self.store.keys);self.assertEqual(next(d for d in other.snapshot()['devices'] if d['kind']=='s25')['charge'],88)
 def test_unsupported_routes_and_rate_limits(self):
  self.assertEqual(self.request(path='/v1/batteries?token=x')[0],404)
  for _ in range(60):self.store.allowed('s23')
  self.assertEqual(self.request()[0],429)
if __name__=='__main__':unittest.main()
