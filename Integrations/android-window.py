#!/usr/bin/env python3
"""Original Android icons and per-app native macOS identity. All IPC stays on authorized ADB/SSH."""
import base64, hashlib, json, os, plistlib, re, shutil, subprocess, time
from pathlib import Path
ROOT=Path.home()/'.local/share/pedro-notch'
BRIDGE='marketing.insight360.appicons'
ADB='/opt/homebrew/bin/adb'
RES=Path(__file__).parent/'AndroidAppIcons'
REMOTE_CODE=r'''
import base64,json,re,subprocess,sys,time
from pathlib import Path
r=json.load(sys.stdin)
def run(args):
 p=subprocess.run(args,capture_output=True,timeout=35)
 if p.returncode:raise RuntimeError((p.stderr+p.stdout).decode(errors='replace')[-600:])
 return p.stdout
serials=[m[1] for l in run(['adb','devices']).decode().splitlines() if (m:=re.match(r'^(.*?)\s+device(?:\s|$)',l))]
serial=next((s for s in serials if run(['adb','-s',s,'shell','getprop','ro.serialno']).strip()==b'DEMO_S23'),None)
if not serial:raise ValueError('S23 indisponivel')
a=['adb','-s',serial]
if not subprocess.run(a+['shell','pm','path','marketing.insight360.appicons'],capture_output=True,timeout=8).stdout.strip():
 apk=Path.home()/'.cache/InsightAppIcons.apk';apk.write_bytes(base64.b64decode(r['apk']))
 run(a+['install','-r',str(apk)])
package=r['package']
if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+',package):raise ValueError('Pacote invalido')
run(a+['shell','am','broadcast','-n','marketing.insight360.appicons/.IconReceiver','--es','package',package])
prefix='/sdcard/Android/data/marketing.insight360.appicons/files/icons/'+package
meta=json.loads(run(a+['exec-out','cat',prefix+'.json']))
meta['png']=base64.b64encode(run(a+['exec-out','cat',prefix+'.png'])).decode()
print(json.dumps(meta))
'''

def call(args,**kwargs):
    r=subprocess.run(args,capture_output=True,timeout=40,**kwargs)
    if r.returncode:raise RuntimeError(r.stderr.decode(errors='replace')[-300:])
    return r.stdout

def validate(ident,package=None):
    if not re.fullmatch(r"[a-f0-9]{32}",ident):raise ValueError("Aparelho invalido")
    if package is not None and not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+",package):raise ValueError("Pacote invalido")

def export_icon(ident,package,selected):
    validate(ident,package)
    cache=ROOT/'android-icons'/ident/package;cache.mkdir(mode=0o700,parents=True,exist_ok=True)
    image=cache/'scrcpy.png';meta=cache/'meta.json'
    if image.exists() and meta.exists() and time.time()-image.stat().st_mtime<86400:return json.loads(meta.read_text()),image
    if selected:
        args=[ADB,'-s',selected['transport']]
        if not subprocess.run(args+['shell','pm','path',BRIDGE],capture_output=True,timeout=8).stdout.strip():call(args+['install','-r',str(RES/'InsightAppIcons.apk')])
        call(args+['shell','am','broadcast','-n',BRIDGE+'/.IconReceiver','--es','package',package])
        prefix='/sdcard/Android/data/'+BRIDGE+'/files/icons/'+package
        value=json.loads(call(args+['exec-out','cat',prefix+'.json']))
        data=call(args+['exec-out','cat',prefix+'.png'])
    else:
        request=dict(package=package,apk=base64.b64encode((RES/'InsightAppIcons.apk').read_bytes()).decode())
        command='python3 -c "import base64;exec(base64.b64decode(\''+base64.b64encode(REMOTE_CODE.encode()).decode()+'\'))"'
        value=json.loads(call(['/usr/bin/ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','x99',command],input=json.dumps(request).encode()))
        data=base64.b64decode(value.pop('png'))
    if not data.startswith(b'\x89PNG\r\n\x1a\n') or len(data)>2*1024*1024:raise ValueError('Icone Android invalido')
    image.write_bytes(data);meta.write_text(json.dumps(value,ensure_ascii=False));return value,image

def replace_binary(source,destination):
    # Vendor binaries may be read-only; replace the inode rather than overwriting it.
    temporary=destination.with_name(destination.name+".tmp")
    if temporary.exists():temporary.unlink()
    shutil.copy2(source,temporary)
    temporary.replace(destination)

def bundle(ident,device,package,selected):
    validate(ident,package)
    name=device;image=None
    if package:
        try:
            meta,image=export_icon(ident,package,selected);name=''.join(c for c in str(meta.get('name') or package) if c.isprintable())[:80]
        except Exception as error:
            print('Ícone original indisponível: '+str(error),flush=True);name=package.split('.')[-1].capitalize()
    key=hashlib.sha256((ident+':'+(package or 'screen')).encode()).hexdigest()[:20]
    title=name+' · '+device if package else device
    app=ROOT/'AndroidWindows'/(key+'.app');contents=app/'Contents';resources=contents/'Resources';executables=contents/'MacOS'
    resources.mkdir(mode=0o700,parents=True,exist_ok=True);executables.mkdir(mode=0o700,exist_ok=True)
    icon=resources/'scrcpy.png'
    changed=not (executables/'ScrcpyCore').exists()
    if image and (not icon.exists() or image.read_bytes()!=icon.read_bytes()):shutil.copyfile(image,icon);changed=True
    elif not icon.exists():call([str(RES/'InsightAndroidLauncher'),'icon',str(icon),device.replace(' Ultra','')]);changed=True
    version=str(Path('/Applications/scrcpy.app/Contents/MacOS/scrcpy').stat().st_mtime_ns)
    info={'CFBundleIdentifier':'marketing.insight360.android.'+key,'CFBundleName':title,'CFBundleDisplayName':title,
          'CFBundleExecutable':'InsightAndroid','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'1',
          'CFBundleIconFile':'AppIcon','NSHighResolutionCapable':True,'LSUIElement':True,
          'InsightDeviceID':ident,'InsightBrokerPath':str(Path(__file__).with_name('scrcpy-phone.py').resolve()),'InsightScrcpyVersion':version,'InsightLauncherVersion':str((RES/'InsightAndroidLauncher').stat().st_mtime_ns)}
    if package:info['InsightAndroidPackage']=package
    plist=contents/'Info.plist'
    old=plistlib.loads(plist.read_bytes()) if plist.exists() else {}
    if old!=info:changed=True
    if changed:
        replace_binary('/Applications/scrcpy.app/Contents/MacOS/scrcpy',executables/'ScrcpyCore')
        replace_binary(RES/'InsightAndroidLauncher',executables/'InsightAndroid')
        iconset=resources/'AppIcon.iconset';iconset.mkdir(exist_ok=True)
        for size in (16,32,128,256,512):
            for scale in (1,2):
                path=iconset/('icon_'+str(size)+'x'+str(size)+('@2x' if scale==2 else '')+'.png')
                call(['/usr/bin/sips','-z',str(size*scale),str(size*scale),str(icon),'--out',str(path)])
        call(['/usr/bin/iconutil','-c','icns',str(iconset),'-o',str(resources/'AppIcon.icns')])
        shutil.rmtree(iconset);plist.write_bytes(plistlib.dumps(info))
        call(['/usr/bin/codesign','--force','--deep','--sign','-',str(app)])
    return str(executables/'ScrcpyCore'),resources,title
