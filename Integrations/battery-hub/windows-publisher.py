#!/usr/bin/env python3
"""Publish only Windows battery level/charging; no power or thermal setting changes."""
import argparse,ctypes,json,os,time,urllib.request
from pathlib import Path
class PowerStatus(ctypes.Structure):
 _fields_=[('ac',ctypes.c_ubyte),('flags',ctypes.c_ubyte),('percent',ctypes.c_ubyte),('saver',ctypes.c_ubyte),('remaining',ctypes.c_uint32),('full',ctypes.c_uint32)]
def payload(status):
 if status.flags==255 or status.flags&128 or not 0<=status.percent<=100:raise ValueError('Battery unavailable')
 return {'charge':int(status.percent),'charging':bool(status.flags&8)}
def battery():
 status=PowerStatus();fn=ctypes.WinDLL('kernel32',use_last_error=True).GetSystemPowerStatus
 fn.argtypes=[ctypes.POINTER(PowerStatus)];fn.restype=ctypes.c_int
 if not fn(ctypes.byref(status)):raise OSError('Power status unavailable')
 return payload(status)
def publish(config,value):
 if config.get('endpoint')!='https://batteries.example.com/v1/batteries':raise ValueError('Unexpected endpoint')
 request=urllib.request.Request(config['endpoint'],data=json.dumps(value).encode(),method='PUT',headers={'Authorization':'Bearer '+config['token'],'Content-Type':'application/json','User-Agent':'InsightBatteriesWindows/1'})
 with urllib.request.urlopen(request,timeout=10) as response:
  if response.status!=200:raise OSError('Hub unavailable')
  response.read(16384)
def save(path,value):
 temp=path.with_suffix('.tmp');temp.write_text(json.dumps(value),encoding='utf-8');temp.replace(path)
def main():
 p=argparse.ArgumentParser();p.add_argument('--config',required=True);p.add_argument('--once',action='store_true');p.add_argument('--read-only',action='store_true');a=p.parse_args()
 config_path=Path(a.config);config=json.loads(config_path.read_text(encoding='utf-8'));health=config_path.with_name('health.json');delay=30
 while True:
  status={'updatedAt':time.time(),'pid':os.getpid()}
  try:
   value=battery()
   if not a.read_only:publish(config,value)
   status.update(ok=True,**value);delay=30
  except Exception as error:status.update(ok=False,error=type(error).__name__);delay=min(delay*2,120)
  save(health,status)
  if a.once or a.read_only:
   print(json.dumps(status));return 0 if status['ok'] else 1
  time.sleep(delay)
if __name__=='__main__':raise SystemExit(main())
