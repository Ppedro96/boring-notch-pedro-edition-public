#!/usr/bin/env python3
"""Install/update the signed widget and provision each key over already authorized ADB."""
import argparse,base64,json,subprocess
from pathlib import Path
PKG='marketing.insight360.batteries';ADB='/opt/homebrew/bin/adb'
def command(args,timeout=30):
 p=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
 if p.returncode:raise RuntimeError((p.stdout+p.stderr)[-350:])
 return p.stdout
REMOTE=r'''
import json,re,subprocess,sys
from pathlib import Path
r=json.load(sys.stdin)
def run(a):
 p=subprocess.run(a,capture_output=True,text=True,timeout=30)
 if p.returncode:raise RuntimeError('ADB command failed')
 return p.stdout
serial=next((line.split()[0] for line in run(['adb','devices']).splitlines()[1:] if len(line.split())>1 and line.split()[1]=='device' and run(['adb','-s',line.split()[0],'shell','getprop','ro.serialno']).strip()=='DEMO_S23'),None)
if not serial:raise RuntimeError('S23 unavailable')
a=['adb','-s',serial]
run(a+['install','-r',str(Path.home()/'.cache/InsightBatteries-cloud.apk')])
run(a+['shell','pm','grant','marketing.insight360.batteries','android.permission.POST_NOTIFICATIONS'])
run(a+['shell','dumpsys','deviceidle','whitelist','+marketing.insight360.batteries'])
result=run(a+['shell','am','broadcast','-n','marketing.insight360.batteries/.SyncReceiver','-a','marketing.insight360.batteries.SYNC','--es','endpoint',r['endpoint'],'--es','token',r['token']])
if 'result=-1' not in result:raise RuntimeError('Configuration rejected')
run(a+['shell','am','start-foreground-service','-n','marketing.insight360.batteries/.BatterySyncService'])
print(json.dumps({'device':'s23','installed':True,'configured':True}))
'''
def main():
 p=argparse.ArgumentParser();p.add_argument('--config',required=True);p.add_argument('--apk',required=True);p.add_argument('--s23',action='store_true');a=p.parse_args();c=json.loads(Path(a.config).read_text())
 if a.s23:
  subprocess.run(['scp','-q',a.apk,'x99:.cache/InsightBatteries-cloud.apk'],check=True)
  code='python3 -c "import base64;exec(base64.b64decode(\''+base64.b64encode(REMOTE.encode()).decode()+'\'))"'
  r=subprocess.run(['ssh','x99',code],input=json.dumps({'endpoint':c['endpoint'],'token':c['tokens']['s23']}),text=True,capture_output=True,timeout=60)
  if r.returncode:raise RuntimeError('S23 deployment failed: '+r.stderr[-200:])
  print(r.stdout.strip());return
 profiles={'DEMO_FOLD':'fold','DEMO_TABLET':'tablet','DEMO_S25':'s25'}
 for line in command([ADB,'devices']).splitlines()[1:]:
  if '\tdevice' not in line:continue
  serial=line.split('\t')[0];base=[ADB,'-s',serial];hardware=command(base+['shell','getprop','ro.serialno']).strip();kind=profiles.get(hardware)
  if not kind:continue
  command(base+['install','-r',a.apk]);command(base+['shell','pm','grant',PKG,'android.permission.POST_NOTIFICATIONS']);command(base+['shell','dumpsys','deviceidle','whitelist','+'+PKG])
  result=command(base+['shell','am','broadcast','-n',PKG+'/.SyncReceiver','-a',PKG+'.SYNC','--es','endpoint',c['endpoint'],'--es','token',c['tokens'][kind]])
  if 'result=-1' not in result:raise RuntimeError('Configuration rejected for '+kind)
  command(base+['shell','am','start-foreground-service','-n',PKG+'/.BatterySyncService'])
  print(json.dumps({'device':kind,'installed':True,'configured':True}))
if __name__=='__main__':main()
