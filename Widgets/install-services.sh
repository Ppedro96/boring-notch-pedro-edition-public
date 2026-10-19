#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
/usr/bin/clang -O2 -Wall "$repo/Integrations/battery-availability.c" -framework IOKit -framework CoreFoundation -o "$repo/Integrations/battery-availability"
/usr/bin/python3 - "$repo" <<'PY'
import os,plistlib,shutil,subprocess,sys,time
from pathlib import Path
repo=Path(sys.argv[1]);runtime=Path.home()/'.local/share/pedro-notch';agents=Path.home()/'Library/LaunchAgents'
runtime.mkdir(mode=0o700,parents=True,exist_ok=True);agents.mkdir(parents=True,exist_ok=True)
backup=runtime/'backups'/('widget-availability-'+time.strftime('%Y%m%d-%H%M%S'));backup.mkdir(parents=True)
for name in ('battery-widgets.py','battery-collect.cjs','battery-availability'):
 target=runtime/name
 if target.exists():shutil.copy2(target,backup/name)
 temp=target.with_suffix('.install');shutil.copy2(repo/'Integrations'/name,temp);temp.replace(target)
uid=os.getuid()
cloud=(runtime/'battery-hub-client.json').exists()
if cloud:
 label='marketing.insight360.battery-availability'
 subprocess.run(['launchctl','bootout','gui/'+str(uid)+'/'+label],capture_output=True)
 previous=agents/(label+'.plist')
 if previous.exists():previous.replace(backup/previous.name)

for label,args,extra in [
 ('marketing.insight360.battery-widgets',['/usr/bin/python3',str(runtime/'battery-widgets.py')],{'StartInterval':30}),
 ('marketing.insight360.battery-availability',[str(runtime/'battery-availability'),str(runtime/'battery-availability.json')],{'KeepAlive':True,'ThrottleInterval':30})]:
 if cloud and label.endswith('battery-availability'):continue
 target=agents/(label+'.plist')
 if target.exists():shutil.copy2(target,backup/target.name)
 value={'Label':label,'ProgramArguments':args,'RunAtLoad':True,'ProcessType':'Background',
 'EnvironmentVariables':{'PATH':'/opt/homebrew/bin:/usr/bin:/bin'},
 'StandardOutPath':str(runtime/(label.rsplit('.',1)[-1]+'.log')),
 'StandardErrorPath':str(runtime/(label.rsplit('.',1)[-1]+'-error.log')),**extra}
 subprocess.run(['launchctl','bootout','gui/'+str(uid)+'/'+label],capture_output=True)
 target.write_bytes(plistlib.dumps(value));target.chmod(0o644)
 subprocess.run(['launchctl','bootstrap','gui/'+str(uid),str(target)],check=True)
 print('Installed '+label)
print('Backup: '+str(backup))
PY
