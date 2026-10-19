#!/usr/bin/env python3
"""Private six-device battery hub. Tokens grant own-device writes and family reads only."""
import argparse,hashlib,hmac,json,os,sqlite3,threading,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
DEVICES={'mac':'MacBook Pro','alienware':'Alienware','s23':'S23 Ultra','s25':'S25 Ultra','fold':'Z Fold6','tablet':'Tab S8+'}
FRESH=180
class Store:
 def __init__(self,path,keys):
  self.path=str(path);self.keys=keys;self.rate={};self.lock=threading.Lock()
  with self.db() as db:
   db.execute('PRAGMA journal_mode=WAL');db.execute('CREATE TABLE IF NOT EXISTS batteries(kind TEXT PRIMARY KEY,charge INTEGER NOT NULL,charging INTEGER NOT NULL,updated REAL NOT NULL)')
 def db(self):return sqlite3.connect(self.path,timeout=5)
 def authenticate(self,header):
  if not header.startswith('Bearer ') or len(header)>150:return None
  digest=hashlib.sha256(header[7:].encode()).hexdigest()
  return next((kind for kind,value in self.keys.items() if hmac.compare_digest(value,digest)),None)
 def allowed(self,kind):
  now=time.monotonic()
  with self.lock:
   begin,count=self.rate.get(kind,(now,0))
   if now-begin>=60:begin,count=now,0
   self.rate[kind]=(begin,count+1);return count<60
 def update(self,kind,value):
  if set(value)!={'charge','charging'} or type(value['charge'])is not int or not 0<=value['charge']<=100 or type(value['charging'])is not bool:raise ValueError('invalid battery')
  with self.db() as db:db.execute('INSERT INTO batteries VALUES(?,?,?,?) ON CONFLICT(kind) DO UPDATE SET charge=excluded.charge,charging=excluded.charging,updated=excluded.updated',(kind,value['charge'],int(value['charging']),time.time()))
 def snapshot(self):
  now=time.time()
  with self.db() as db:rows={row[0]:row[1:] for row in db.execute('SELECT kind,charge,charging,updated FROM batteries')}
  return {'updatedAt':now,'devices':[{'id':kind,'kind':kind,'name':name,'charge':rows[kind][0] if kind in rows else None,'charging':bool(rows[kind][1]) if kind in rows else False,'connected':kind in rows and now-rows[kind][2]<FRESH,'updatedAt':rows[kind][2] if kind in rows else 0} for kind,name in DEVICES.items()]}
class Handler(BaseHTTPRequestHandler):
 server_version='InsightBatteries/1';sys_version=''
 def log_message(self,*args):pass
 def setup(self):super().setup();self.connection.settimeout(8)
 def send(self,code,value):
  data=json.dumps(value,ensure_ascii=False,separators=(',',':')).encode()
  self.send_response(code);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Cache-Control','no-store, private');self.send_header('X-Content-Type-Options','nosniff');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def route(self,write=False):
  if self.server.allow_sources and self.client_address[0] not in self.server.allow_sources:return self.send(403,{'error':'forbidden'})
  if urlsplit(self.path).path!='/v1/batteries' or urlsplit(self.path).query:return self.send(404,{'error':'not found'})
  kind=self.server.store.authenticate(self.headers.get('Authorization',''))
  if not kind:return self.send(401,{'error':'unauthorized'})
  if not self.server.store.allowed(kind):return self.send(429,{'error':'rate limited'})
  if write:
   try:
    if self.headers.get('Transfer-Encoding') or self.headers.get('Content-Type','').split(';')[0]!='application/json':raise ValueError()
    length=int(self.headers.get('Content-Length','0'))
    if not 0<length<=512:raise ValueError()
    self.server.store.update(kind,json.loads(self.rfile.read(length)))
   except (ValueError,TypeError,KeyError):return self.send(400,{'error':'invalid battery payload'})
  return self.send(200,self.server.store.snapshot())
 def do_GET(self):self.route()
 def do_PUT(self):self.route(True)
class BoundedServer(ThreadingHTTPServer):
 daemon_threads=True
 def __init__(self,*args):self.slots=threading.BoundedSemaphore(16);super().__init__(*args)
 def process_request(self,request,address):
  if not self.slots.acquire(False):self.shutdown_request(request);return
  try:super().process_request(request,address)
  except BaseException:self.slots.release();raise
 def process_request_thread(self,request,address):
  try:super().process_request_thread(request,address)
  finally:self.slots.release()
def create_server(host,port,store,allow_sources=None):
 server=BoundedServer((host,port),Handler);server.store=store;server.allow_sources=allow_sources;return server
def main():
 p=argparse.ArgumentParser();p.add_argument('--bind',default='127.0.0.1');p.add_argument('--port',type=int,default=17874);p.add_argument('--state',required=True);p.add_argument('--keys',required=True);p.add_argument('--allow-source',action='append');a=p.parse_args()
 keys=json.loads(Path(a.keys).read_text())
 if set(keys)!=set(DEVICES) or any(not isinstance(v,str) or len(v)!=64 for v in keys.values()):raise ValueError('invalid credentials configuration')
 os.umask(0o077);Path(a.state).parent.mkdir(mode=0o700,parents=True,exist_ok=True)
 create_server(a.bind,a.port,Store(a.state,keys),a.allow_source).serve_forever()
if __name__=='__main__':main()
