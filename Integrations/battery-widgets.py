#!/usr/bin/env python3
"""Battery-only local snapshots; pushes widgets via existing authenticated ADB."""
import base64,json,subprocess,time,os,re,concurrent.futures,fcntl,shlex,urllib.request
from pathlib import Path
ROOT=Path.home()/'.local/share/pedro-notch'
TARGET=Path.home()/'Library/Containers/marketing.insight360.batteries.widget/Data/batteries.json'
ADB='/opt/homebrew/bin/adb'
APP='/Applications/Insight Batteries.app/Contents/MacOS/InsightBatteries'
PACKAGE='marketing.insight360.batteries'
KINDS={'SM-S918':'s23','SM-S938':'s25','SM-F956':'fold','SM-X806':'tablet'}
def run(args,timeout=6):
 return subprocess.run(args,capture_output=True,text=True,timeout=timeout).stdout.strip()
def build_snapshot(source,mac,now,alive):
 devices=[]
 for value in source.get('devices',[]):
  if value.get('kind') not in ['s23','s25','fold','tablet']: continue
  value={key:value.get(key) for key in ['id','name','kind','charge','charging','connected','updatedAt']}
  value['connected']=bool(value.get('connected')) and alive
  value['updatedAt']=now if value['connected'] else value.get('updatedAt',0)
  devices.append(value)
 return {'updatedAt':now,'devices':[mac]+devices}
PROFILES={
 'demo_s23':('s23','S23 Ultra'),
 'demo_s25':('s25','S25 Ultra'),
 'demo_fold':('fold','Z Fold6'),
 'demo_tablet':('tablet','Tab S8+')}
def read_json(path,default):
 try:return json.loads(path.read_text())
 except (OSError,ValueError):return default
def atomic_json(path,value):
 path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
 temp=path.with_suffix('.tmp');temp.write_text(json.dumps(value,ensure_ascii=False,separators=(',',':')));temp.chmod(0o600);temp.replace(path)
def normalize_devices(current,previous,now):
 known={value.get('id','').removeprefix('x99:'):value for value in previous.get('devices',[])}
 incoming={value.get('id','').removeprefix('x99:'):value for value in current.get('devices',[])}
 values=[]
 for ident,(kind,name) in PROFILES.items():
  value=incoming.get(ident,{});old=known.get(ident,{})
  live=bool(value.get('paired') and value.get('reachable') and type(value.get('charge')) is int and 0<=value['charge']<=100)
  values.append(dict(id=ident,kind=kind,name=name,charge=value['charge'] if live else old.get('charge'),
   charging=bool(value.get('charging')) if live else bool(old.get('charging')),connected=live,
   updatedAt=now if live else old.get('updatedAt',0)))
 return {'devices':values}
def collect_source(now):
 previous=read_json(ROOT/'battery-snapshot.json',{})
 try:
  current=json.loads(run(['/opt/homebrew/bin/node',str(ROOT/'battery-collect.cjs')],timeout=10))
  if not current.get('ok'):raise ValueError('KDE Connect indisponível')
  return normalize_devices(current,previous,now)
 except (OSError,ValueError,subprocess.TimeoutExpired):
  # The independent bridge can recover while the Notch is closed. A fresh app
  # export is only a fallback; stale readings never receive a new timestamp.
  fallback=read_json(ROOT/'battery-source.json',{})
  if run(['/usr/bin/pgrep','-f','^/Applications/Insight Notch.app/Contents/MacOS/boringNotch$']):
   for value in fallback.get('devices',[]):
    if now-value.get('updatedAt',0)<90 and value.get('connected'):
     value['paired']=True;value['reachable']=True
   return normalize_devices(fallback,previous,now)
  return normalize_devices({},previous,now)
def validate_hub_snapshot(value,now):
 if not isinstance(value,dict) or not isinstance(value.get('devices'),list) or len(value['devices']) not in (5,6):raise ValueError('Snapshot inválido')
 required={'mac','s23','s25','fold','tablet'};kinds=required|{'alienware'};seen=set();devices=[]
 for d in value['devices']:
  kind=d.get('kind');charge=d.get('charge');updated=d.get('updatedAt')
  if kind not in kinds or kind in seen or (charge is not None and (type(charge)is not int or not 0<=charge<=100)) or type(updated)not in (int,float) or not 0<=updated<=now+60:raise ValueError('Bateria inválida')
  seen.add(kind)
  if kind=='alienware':continue  # The macOS widget remains Samsung-only.
  devices.append({'id':kind,'kind':kind,'name':'MacBook Pro' if kind=='mac' else next(name for k,name in PROFILES.values() if k==kind),
    'charge':charge,'charging':d.get('charging') is True,'connected':d.get('connected') is True and now-updated<180,'updatedAt':updated})
 if not required.issubset(seen):raise ValueError('Aparelho ausente')
 return {'updatedAt':now,'devices':devices}
def hub_snapshot(config,mac,now):
 if config.get('endpoint')!='https://batteries.example.com/v1/batteries' or not re.fullmatch(r'[A-Za-z0-9_-]{40,100}',config.get('token','')):raise ValueError('Configuração inválida')
 data=json.dumps({'charge':mac['charge'],'charging':mac['charging']}).encode()
 request=urllib.request.Request(config['endpoint'],data=data,method='PUT',headers={'Authorization':'Bearer '+config['token'],'Content-Type':'application/json','User-Agent':'InsightBatteriesMac/2'})
 with urllib.request.urlopen(request,timeout=10) as response:
  data=response.read(16385)
  if len(data)>16384:raise ValueError('Resposta grande demais')
  return validate_hub_snapshot(json.loads(data),now)
def main():
 now=time.time();config=read_json(ROOT/'battery-hub-client.json',{});hub=False
 text=run(['/usr/bin/pmset','-g','batt']);match=re.search(r'(\d+)%;',text)
 mac={'id':'mac','name':'MacBook Pro','kind':'mac','charge':int(match[1]) if match else None,
      'charging':'charging;' in text and 'discharging;' not in text,'connected':True,'updatedAt':now}
 if config:
  try:snapshot=hub_snapshot(config,mac,now);hub=True
  except (OSError,ValueError,subprocess.TimeoutExpired):
   previous=read_json(ROOT/'battery-snapshot.json',{})
   try:snapshot=validate_hub_snapshot(previous,now)
   except ValueError:snapshot={'updatedAt':now,'devices':[]}
   snapshot['devices']=[mac]+[d for d in snapshot['devices'] if d['kind']!='mac']
 else:snapshot=build_snapshot(collect_source(now),mac,now,True)
 data=json.dumps(snapshot,ensure_ascii=False,separators=(',',':'))
 if TARGET.parent.exists():atomic_json(TARGET,snapshot)
 atomic_json(ROOT/'battery-snapshot.json',snapshot)
 last=ROOT/'battery-widget-last-reload.json';previous=read_json(last,{})
 fingerprint=[[d['kind'],d['charge'],d['charging'],d['connected']] for d in snapshot['devices']]
 if Path(APP).exists() and (previous.get('values')!=fingerprint or now-previous.get('at',0)>120):
  try:
   reload=subprocess.run([APP,'--reload'],capture_output=True,timeout=10)
   if reload.returncode==0:atomic_json(last,{'values':fingerprint,'at':now})
  except (OSError,subprocess.TimeoutExpired):pass
 if config:
  health={'devices':len(snapshot['devices']),'connected':sum(bool(d['connected']) for d in snapshot['devices']),
   'mode':'internet','hubOnline':hub,'updatedAt':now,'duration':round(time.time()-now,2)}
  atomic_json(ROOT/'battery-widgets-health.json',health);print(json.dumps(health));return
 learned=read_json(ROOT/'scrcpy-devices.json',{});allowed={item.get('hardware') for item in learned.values()}
 encoded=base64.b64encode(data.encode()).decode()
 command=['shell','am','broadcast','-n',PACKAGE+'/.SyncReceiver','-a',PACKAGE+'.SYNC','--es','snapshot',encoded]
 def push_local(serial):
  try:
   hardware=run([ADB,'-s',serial,'shell','getprop','ro.serialno'],timeout=3)
   if hardware not in allowed:return None
   result=run([ADB,'-s',serial]+command,timeout=5)
   return hardware if 'Broadcast completed' in result else None
  except (OSError,subprocess.TimeoutExpired):return None
 def push_s23():
  try:
   prefix=['/usr/bin/ssh','-o','BatchMode=yes','-o','ConnectTimeout=3','x99']
   for line in run(prefix+['adb devices'],timeout=4).splitlines():
    parts=line.split()
    if len(parts)<2 or parts[1]!='device' or not re.fullmatch(r'[A-Za-z0-9._:\-]+',parts[0]):continue
    base=['adb','-s',parts[0]]
    if run(prefix+[shlex.join(base+['shell','getprop','ro.serialno'])],timeout=4)!='DEMO_S23':continue
    result=run(prefix+[shlex.join(base+command)],timeout=6)
    return 'DEMO_S23' if 'Broadcast completed' in result else None
  except (OSError,subprocess.TimeoutExpired):pass
  return None
 try:serials=[m[1] for line in run([ADB,'devices'],timeout=4).splitlines() if (m:=re.match(r'^(.*?)\s+device(?:\s|$)',line))][:8]
 except (OSError,subprocess.TimeoutExpired):serials=[]
 with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
  tasks=[pool.submit(push_local,serial) for serial in serials]+[pool.submit(push_s23)]
  pushed=sorted(set(result for task in tasks if (result:=task.result())))
 health={'devices':len(snapshot['devices']),'connected':sum(bool(d['connected']) for d in snapshot['devices']),
         'pushed':pushed,'updatedAt':now,'duration':round(time.time()-now,2)}
 atomic_json(ROOT/'battery-widgets-health.json',health)
 print(json.dumps(health))
if __name__=='__main__':
 ROOT.mkdir(mode=0o700,parents=True,exist_ok=True)
 with (ROOT/'battery-widgets.lock').open('a') as lock:
  try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  except BlockingIOError:raise SystemExit(0)
  try:main()
  except (OSError,ValueError,subprocess.TimeoutExpired) as error:print(type(error).__name__+': '+str(error))
