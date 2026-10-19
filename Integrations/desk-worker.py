#!/usr/bin/env python3
"""Private, on-demand desktop worker. JSON stdin; no network listener or shell tasks."""
import base64, hashlib, importlib.util, json, os, platform, re, shutil, subprocess, sys, tempfile, threading, time, uuid
from pathlib import Path
# Interactive scheduled tasks may inherit unusable console handles. Job mode uses its own log.
if len(sys.argv)>2 and sys.argv[1]=='run' and re.fullmatch('[a-f0-9]{32}',sys.argv[2]):
    console=Path.home()/'.local/share/insight-notch/jobs'/sys.argv[2]/'worker.log'
    sys.stdout=sys.stderr=console.open('a',encoding='utf-8')
    sys.stdin=open(os.devnull)
if hasattr(sys.stdout, 'reconfigure'): sys.stdout.reconfigure(encoding='utf-8')
if hasattr(sys.stdin, 'reconfigure'): sys.stdin.reconfigure(encoding='utf-8')
BASE = Path.home()/'.local/share/insight-notch'
JOBS = BASE/'jobs'

def write(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp-'+uuid.uuid4().hex)
    temp.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
    temp.replace(path)

def jobdir(ident):
    if not re.fullmatch('[a-f0-9]{32}', ident): raise ValueError('Identificador inválido')
    return JOBS/ident

def roots():
    home=Path.home()
    candidates=[home/n for n in ('Desktop','Documents','Downloads','Movies','Music','Videos','Pictures')]
    available={str(i):str(p.resolve()) for i,p in enumerate(candidates) if p.is_dir()}
    mountbase=Path('/Volumes') if sys.platform=='darwin' else Path('/mnt')
    names=('Brutos','Dados_Insight') if sys.platform=='darwin' else ('nas-brutos','nas-dados')
    if os.name!='nt':
        # Inspect mount names without stat/resolve calls into an unresponsive SMB share.
        try: mounted={p.name for p in mountbase.iterdir()}
        except OSError: mounted=set()
        for i,name in enumerate(names,start=len(candidates)):
            if name in mounted:available[str(i)]=str(mountbase/name)
    return available

def safe_file(root, relative):
    available=roots()
    if root not in available: raise ValueError('Origem indisponível')
    if not isinstance(relative,str) or Path(relative).is_absolute() or '..' in Path(relative).parts:raise ValueError('Caminho inválido')
    base=Path(available[root]).resolve(); path=(base/relative).resolve()
    if base not in path.parents or not path.is_file() or any(p.startswith('.') for p in Path(relative).parts):
        raise ValueError('Arquivo fora da origem permitida')
    return path

def _search(query, results, state):
    query=query.strip().casefold()
    if len(query)<2 or len(query)>160: raise ValueError('Digite entre 2 e 160 caracteres')
    visited=0; end=time.monotonic()+7; truncated=False
    available=roots();state["roots"]=available
    for key,root in available.items():
        root_end = min(end, time.monotonic()+1.0); root_visited=0
        stack=[(Path(root),0)]
        while stack:
            directory,depth=stack.pop()
            if time.monotonic()>root_end or root_visited>=8000 or len(results)>=80:
                truncated=True; break
            try:
                with os.scandir(directory) as entries:
                    for entry in entries:
                        visited+=1;root_visited+=1
                        if root_visited>8000 or time.monotonic()>root_end:truncated=True;break
                        if entry.name.startswith('.') or entry.name in ('node_modules','Library','AppData','venv','__pycache__','Codex'): continue
                        if entry.is_symlink(): continue
                        if entry.is_dir(follow_symlinks=False) and depth<6: stack.append((Path(entry.path),depth+1))
                        elif entry.is_file(follow_symlinks=False) and query in entry.name.casefold():
                            stat=entry.stat(follow_symlinks=False)
                            results.append(dict(id=hashlib.sha256(entry.path.encode()).hexdigest(),name=entry.name,path=entry.path,
                                root=key,relative=str(Path(entry.path).relative_to(root)),size=stat.st_size,modified=stat.st_mtime))
                        if root_visited>=8000 or len(results)>=80 or time.monotonic()>root_end: break
            except (OSError,PermissionError): continue
        if time.monotonic()>end or len(results)>=80:break
    return dict(ok=True, results=sorted(results,key=lambda r:r['modified'],reverse=True),truncated=truncated,roots=available)

SEARCH_TIMEOUT=8

def search(query):
    query=query.strip().casefold()
    if len(query)<2 or len(query)>160:raise ValueError('Digite entre 2 e 160 caracteres')
    results=[];state={}
    def scan():
        try:state['reply']=_search(query,results,state)
        except Exception as error:state['error']=str(error)
    thread=threading.Thread(target=scan,daemon=True);thread.start();thread.join(SEARCH_TIMEOUT)
    if 'reply' in state:return state['reply']
    if 'error' in state:raise RuntimeError(state['error'])
    # A blocked filesystem call cannot discard results from healthy personal folders.
    return dict(ok=True,results=sorted(list(results),key=lambda r:r['modified'],reverse=True),truncated=True,roots=state.get('roots',{}))

def ffmpeg(): return shutil.which('ffmpeg') or ('/opt/homebrew/bin/ffmpeg' if Path('/opt/homebrew/bin/ffmpeg').exists() else None)
def local_models():
    return [p for p in (Path.home()/'.cache/huggingface/hub').glob('models--*faster-whisper*/snapshots/*') if (p/'model.bin').is_file()]

def capabilities():
    return dict(ok=True,hostname=platform.node(),ffmpeg=bool(ffmpeg()),transcribe=bool(importlib.util.find_spec('faster_whisper')) and bool(local_models()),
                roots=roots(),platform=sys.platform,load=os.getloadavg()[0] if hasattr(os,'getloadavg') else None)

def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(4*1024*1024),b''): h.update(chunk)
    return h.hexdigest()

def process(ident):
    directory=jobdir(ident); status=directory/'status.json'; request=json.loads((directory/'request.json').read_text(encoding='utf-8'))
    state=dict(id=ident,pid=os.getpid(),state='running',progress=0,detail='Preparando',updated=time.time())
    def update(**values): state.update(values,updated=time.time());write(status,state)
    child=None
    try:
        operation=request['operation']; source=directory/'input'; source=next(directory.glob('input.*'),source)
        output=directory/('result.txt' if operation=='transcribe' else 'result.m4a' if operation=='audio' else 'result.mp4')
        update(output=str(output))
        if operation=='transcribe':
            from faster_whisper import WhisperModel
            # Use an existing local model only; never trigger a multi-GB download from the Notch.
            models=local_models()
            if not models: raise ValueError('Nenhum modelo de transcrição local disponível')
            update(detail='Transcrevendo com modelo local')
            models.sort(key=lambda p: (0 if 'small' in str(p) else 1 if 'base' in str(p) else 2, str(p)))
            model=WhisperModel(str(models[0]),device='cpu',compute_type='int8',cpu_threads=4)
            segments,info=model.transcribe(str(source),beam_size=3)
            with output.open('w',encoding='utf-8') as f:
                for segment in segments:
                    if (directory/'cancel').exists(): raise InterruptedError('Cancelado')
                    f.write(segment.text.strip()+'\n'); f.flush()
                    update(progress=min(99,segment.end/max(1,info.duration)*100))
        else:
            binary=ffmpeg()
            if not binary: raise ValueError('FFmpeg indisponível nesta máquina')
            if operation not in ('audio','video'): raise ValueError('Operação inválida')
            probe=shutil.which('ffprobe') or str(Path(binary).with_name('ffprobe'))
            duration=float(subprocess.check_output([probe,'-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(source)],text=True,timeout=20).strip())
            options=['-vn','-c:a','aac','-b:a','192k'] if operation=='audio' else ['-vf','scale=\'min(1920,iw)\':-2','-c:v','libx264','-preset','fast','-crf','23','-c:a','aac','-movflags','+faststart','-threads','4']
            with (directory/'ffmpeg.log').open('w') as log:
                child=subprocess.Popen([binary,'-nostdin','-n','-i',str(source)]+options+['-progress',str(directory/'progress'),str(output)],stdout=log,stderr=log)
                while child.poll() is None:
                    if (directory/'cancel').exists():
                        child.terminate(); child.wait(timeout=8); raise InterruptedError('Cancelado')
                    try:
                        text=(directory/'progress').read_text(encoding='utf-8'); stamps=re.findall(r'out_time_us=(\d+)',text)
                        progress=min(99,int(stamps[-1])/1000000/max(1,duration)*100) if stamps else 0
                        update(progress=progress,detail='Convertendo')
                    except OSError: pass
                    time.sleep(.5)
                if child.returncode: raise RuntimeError((directory/'ffmpeg.log').read_text(errors='replace')[-700:])
        if (directory/'cancel').exists(): raise InterruptedError('Cancelado')
        update(state='completed',progress=100,detail='Resultado pronto',sha256=digest(output),size=output.stat().st_size)
    except BaseException as error:
        if child and child.poll() is None: child.kill();child.wait()
        update(state='cancelled' if isinstance(error,InterruptedError) else 'failed',detail=str(error)[-1000:])


def deskflow_windows_launcher(binary, config, pidfile, launcher_log):
    # pythonw has no console; CREATE_NO_WINDOW also prevents the console-mode
    # Deskflow core from opening one. Waiting keeps the child owned by the task.
    return ("import subprocess,sys,traceback\nfrom pathlib import Path\n"
            + "with open(" + repr(str(launcher_log)) + ", 'a', encoding='utf-8') as log:\n"
            + "    try:\n"
            + "        child=subprocess.Popen(" + repr([str(binary),'client','-s',str(config)])
            + ", cwd=" + repr(str(binary.parent))
            + ", stdin=subprocess.DEVNULL, stdout=log, stderr=log, creationflags=subprocess.CREATE_NO_WINDOW)\n"
            + "        Path(" + repr(str(pidfile)) + ").write_text(str(child.pid), encoding='ascii')\n"
            + "        code=child.wait()\n"
            + "    except Exception:\n        traceback.print_exc(file=log)\n        raise\n"
            + "sys.exit(code)\n")


def deskflow(request):
    action=request.get('action','status')
    home=Path.home(); config=BASE/'deskflow-client.ini'; logfile=BASE/'deskflow-client.log';pidfile=BASE/'deskflow-client.pid'
    if os.name=='nt': binary=next((BASE/'deskflow').rglob('deskflow-core.exe'),None)
    else: binary=BASE/'deskflow/usr/bin/deskflow-core'
    if action=='status':
        return dict(ok=True,installed=bool(binary and binary.exists()),detail=logfile.read_text(errors='replace')[-1400:] if logfile.exists() else 'Não iniciado')
    if not binary or not binary.exists():raise ValueError('Deskflow não instalado')
    config.write_text('[core]\ncomputerName='+('Alienware' if os.name=='nt' else 'X99')+'\ncoreMode=Client\nport=24803\nprocessMode=Desktop\n[client]\nremoteHost=127.0.0.1\n[security]\ntlsEnabled=false\n[log]\nlevel=INFO\ntoFile=true\nfile='+str(logfile).replace('\\','/')+'\n')
    if os.name=='nt':
        # A scheduled interactive task attaches to Pedro's existing desktop, unlike an SSH session.
        def literal(value):return "'"+str(value).replace("'","''")+"'"
        task='InsightNotchDeskflow'
        stop_client=("$owned=@(Get-CimInstance Win32_Process -Filter \"Name='deskflow-core.exe'\" | Where-Object { $_.ExecutablePath -eq "
                     +literal(binary)+" -and $_.CommandLine -and $_.CommandLine.Contains("+literal(config)+") }); "
                     +"Stop-ScheduledTask -TaskName '"+task+"' -ErrorAction SilentlyContinue; "
                     +"foreach($process in $owned){$live=Get-CimInstance Win32_Process -Filter ('ProcessId='+$process.ProcessId); "
                     +"if($live -and $live.CreationDate -eq $process.CreationDate -and $live.ExecutablePath -eq $process.ExecutablePath){"
                     +"Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue; "
                     +"Wait-Process -Id $process.ProcessId -Timeout 5 -ErrorAction SilentlyContinue}}; ")
        if action=='stop':script=stop_client+"exit 0"
        elif action=='start':
            pythonw=Path(sys.executable).with_name('pythonw.exe')
            if not pythonw.is_file():raise RuntimeError('Python windowless executable is unavailable')
            launcher=BASE/'deskflow-launch.pyw'
            launcher.write_text(deskflow_windows_launcher(binary,config,pidfile,BASE/'deskflow-launch.log'),encoding='utf-8')
            args=subprocess.list2cmdline(['-I',str(launcher)])
            script=("$ErrorActionPreference='Stop'; "
                    + "$old=Get-ScheduledTask -TaskName '"+task+"' -ErrorAction SilentlyContinue; "
                    + "if($old -and $old.State -eq 'Running' -and $old.Actions[0].Execute -eq "+literal(pythonw)
                    + " -and $old.Actions[0].Arguments -eq "+literal(args)+"){exit 0}; "+stop_client
                    + "$a=New-ScheduledTaskAction -Execute "+literal(pythonw)+" -Argument "+literal(args)+" -WorkingDirectory "+literal(BASE)+"; "
                    + "$p=New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited; "
                    + "$s=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero); "
                    + "Register-ScheduledTask -TaskName '"+task+"' -Action $a -Principal $p -Settings $s -Force | Out-Null; "
                    + "Start-ScheduledTask -TaskName '"+task+"'")
        else:raise ValueError('Ação inválida')
        result=subprocess.run(['powershell','-NoProfile','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()],capture_output=True,text=True,timeout=20)
        if result.returncode:raise RuntimeError(result.stderr[-800:])
    else:
        if action=='stop':
            try:
                pid=int(pidfile.read_text(encoding='utf-8'));cmd=Path('/proc')/str(pid)/'cmdline'
                if cmd.exists() and str(binary).encode() in cmd.read_bytes():os.kill(pid,15)
            except (OSError,ValueError):pass
        elif action=='start':
            try:
                pid=int(pidfile.read_text(encoding='utf-8'))
                if (Path('/proc')/str(pid)/'cmdline').exists() and str(binary).encode() in (Path('/proc')/str(pid)/'cmdline').read_bytes():return dict(ok=True,detail='Já iniciado')
            except (OSError,ValueError):pass
            env=dict(os.environ,XDG_RUNTIME_DIR='/run/user/'+str(os.getuid()),DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/'+str(os.getuid())+'/bus',DISPLAY=':0',WAYLAND_DISPLAY='wayland-0',XDG_SESSION_TYPE='wayland',QT_QPA_PLATFORM='wayland')
            for process in Path('/proc').iterdir():
                try:
                    if (process/'comm').read_text(encoding='utf-8').strip() != 'plasmashell' or process.stat().st_uid != os.getuid():continue
                    desktop = dict(item.split('=',1) for item in (process/'environ').read_bytes().decode().split('\0') if '=' in item)
                    for key in ('DISPLAY','WAYLAND_DISPLAY','XAUTHORITY','DBUS_SESSION_BUS_ADDRESS','XDG_RUNTIME_DIR','XDG_SESSION_TYPE'):
                        if key in desktop:env[key]=desktop[key]
                    break
                except OSError:continue
            with logfile.open('w') as log:
                proc=subprocess.Popen([str(binary),'client','-s',str(config)],stdin=subprocess.DEVNULL,stdout=log,stderr=log,env=env,start_new_session=True)
            pidfile.write_text(str(proc.pid))
        else:raise ValueError('Ação inválida')
    return dict(ok=True,detail='Cliente '+action)

def main(request):
    command=request['command']
    if command=='deskflow': return deskflow(request)
    if command=='capabilities': return capabilities()
    if command=='search': return search(request['query'])
    if command=='stage':
        source=safe_file(request['root'],request['relative']);ident=uuid.uuid4().hex;directory=jobdir(ident);directory.mkdir(mode=0o700,parents=True)
        target=directory/('result'+source.suffix[:20])
        try:os.link(source,target)
        except OSError:
            if source.stat().st_size > shutil.disk_usage(directory).free-1024**3:raise ValueError('Espaço insuficiente para preparar a cópia')
            shutil.copyfile(source,target)
        sha=digest(target);write(directory/'status.json',dict(state='completed'))
        return dict(ok=True,id=ident,path=str(target),sha256=sha,name=source.name)
    if command=='prepare':
        directory=jobdir(request['id']);directory.mkdir(mode=0o700,parents=True,exist_ok=False)
        extension=request.get('extension','')
        if not re.fullmatch(r'\.[A-Za-z0-9]{1,10}',extension): extension='.bin'
        return dict(ok=True,path=str(directory/('input'+extension)))
    if command not in ('start','status','cancel','release'):raise ValueError('Comando inválido')
    directory=jobdir(request['id'])
    if command=='release':
        status=json.loads((directory/'status.json').read_text(encoding='utf-8'))
        if status.get('state')!='completed' or directory.is_symlink():raise ValueError('Trabalho ainda não concluído')
        shutil.rmtree(directory)
        if os.name=='nt':subprocess.run(['schtasks','/Delete','/TN','InsightNotchJob-'+request['id'],'/F'],capture_output=True,timeout=15)
        return dict(ok=True)
    if command=='start':
        if request['operation'] not in ('audio','video','transcribe'): raise ValueError('Operação inválida')
        if (directory/'request.json').exists(): raise ValueError('Trabalho já iniciado')
        write(directory/'request.json',request)
        write(directory/'status.json',dict(id=request['id'],state='waiting',progress=0,detail='Aguardando execução'))
        flags={'creationflags':subprocess.CREATE_NO_WINDOW|subprocess.DETACHED_PROCESS} if os.name=='nt' else {'start_new_session':True}
        if os.name=='nt':
            literal=lambda value:"'"+str(value).replace("'","''")+"'"
            launch="$env:PYTHONUTF8='1'; & "+literal(sys.executable)+" -u "+literal(Path(__file__).resolve())+" run "+literal(request['id'])+" 1> "+literal(directory/'stdout.log')+" 2> "+literal(directory/'stderr.log')+"; exit $LASTEXITCODE"
            arguments='-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '+base64.b64encode(launch.encode('utf-16le')).decode()
            script="$a=New-ScheduledTaskAction -Execute 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe' -Argument "+literal(arguments)+" -WorkingDirectory "+literal(directory)+"; $p=New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Limited; $s=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 1); Register-ScheduledTask -TaskName 'InsightNotchJob-"+request['id']+"' -Action $a -Principal $p -Settings $s -Force | Out-Null; Start-ScheduledTask -TaskName 'InsightNotchJob-"+request['id']+"'"
            result=subprocess.run(['powershell','-NoProfile','-EncodedCommand',base64.b64encode(script.encode('utf-16le')).decode()],capture_output=True,text=True,timeout=20)
            if result.returncode:raise RuntimeError(result.stderr[-700:])
        else:
            with (directory/'worker.log').open('w') as log:
                subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'run',request['id']],stdin=subprocess.DEVNULL,stdout=log,stderr=log,**flags)
        return dict(ok=True)
    if command=='status':
        status=json.loads((directory/'status.json').read_text(encoding='utf-8'))
        if status.get('state')=='running' and status.get('pid'):
            alive=True
            if os.name=='nt':
                import ctypes
                kernel=ctypes.windll.kernel32;kernel.OpenProcess.restype=ctypes.c_void_p
                handle=kernel.OpenProcess(0x1000,False,status['pid'])
                if handle:
                    code=ctypes.c_ulong();kernel.GetExitCodeProcess(ctypes.c_void_p(handle),ctypes.byref(code));kernel.CloseHandle(ctypes.c_void_p(handle));alive=code.value==259
                else:alive=False
            else:
                try:os.kill(status['pid'],0)
                except OSError:alive=False
            if not alive:status.update(state='failed',detail='Processamento interrompido; pode tentar novamente');write(directory/'status.json',status)
        return dict(ok=True,**status)
    if command=='cancel': (directory/'cancel').touch();return dict(ok=True)
    raise ValueError('Comando inválido')

if __name__=='__main__':
    try:
        if len(sys.argv)>1 and sys.argv[1]=='run': process(sys.argv[2])
        else: print(json.dumps(main(json.load(sys.stdin)),ensure_ascii=False))
    except Exception as error:
        if len(sys.argv)>2 and sys.argv[1]=='run':
            write(jobdir(sys.argv[2])/'status.json',dict(id=sys.argv[2],state='failed',detail=str(error)))
        print(json.dumps(dict(ok=False,error=str(error)),ensure_ascii=False));sys.exit(1)
