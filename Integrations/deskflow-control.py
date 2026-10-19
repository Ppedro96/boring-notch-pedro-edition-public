#!/usr/bin/env python3
"""Deskflow session, confined to SSH loopback forwards. Only owns its own children."""
import ctypes, importlib.util, json, os, signal, subprocess, time, socket, sys, tempfile
from pathlib import Path
BASE=Path.home()/'.local/share/pedro-notch/deskflow';BASE.mkdir(mode=0o700,parents=True,exist_ok=True)
CORE='/Applications/Deskflow.app/Contents/MacOS/deskflow-core'
CONFIG=BASE/'server.ini'

def alive(pid):
    try:os.kill(int(pid),0);return True
    except (OSError,ValueError,TypeError):return False

def state():
    try:return json.loads((BASE/'session.json').read_text())
    except (OSError,ValueError):return {}

def allowed():
    lib=ctypes.cdll.LoadLibrary('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
    lib.AXIsProcessTrusted.restype=ctypes.c_bool
    # Notch/Python trust does not substitute Deskflow's own OS authorization.
    return bool(lib.AXIsProcessTrusted())

def stop():
    session=state()
    for key in ('server','x99','alienware','monitor'):
        pid=session.get(key)
        if alive(pid):
            try:os.kill(pid,signal.SIGTERM)
            except OSError:pass
    (BASE/'session.json').write_text('{}')
    return dict(ok=True,detail='Mesa contínua pausada')

def main(request):
    action=request.get('action','status');session=state()
    if action=='stop':return stop()
    if action=='status':
        text=(BASE/'server.log').read_text(errors='replace')[-12000:] if (BASE/'server.log').exists() else ''
        connected=[]
        try:
            live=json.loads((BASE/'connections.json').read_text())
            if live.get('server')==session.get('server') and time.time()-live.get('updated',0)<15 and alive(session.get('server')):
                connected=live.get('connected',[])
        except (OSError,ValueError):pass
        return dict(ok=True,running=alive(session.get('server')),connected=connected,detail=text[-1400:],installed=Path(CORE).exists())
    if action!='start':raise ValueError('Ação inválida')
    if alive(session.get('server')):return dict(ok=True,detail='Sessão já iniciada')
    layout=request.get('layout','x99-left')
    if layout not in ('x99-left','alienware-left'):raise ValueError('Disposição inválida')
    left,right=('X99','Alienware') if layout=='x99-left' else ('Alienware','X99')
    external=BASE/'screens.conf'
    external.write_text('section: links\n Mac:\n  left = '+left+'\n  right = '+right+'\n '+left+':\n  right = Mac\n '+right+':\n  left = Mac\nend\nsection: options\n keystroke(Control+Alt+Home) = switchToScreen(Mac)\nend\n')
    CONFIG.write_text('[core]\ncomputerName=Mac\ncoreMode=Server\ninterface=127.0.0.1\nport=24800\nprocessMode=Desktop\n[computer_Mac]\nname=Mac\n[computer_X99]\nname=X99\n[computer_Alienware]\nname=Alienware\n[security]\ntlsEnabled=false\n[server]\nexternalConfig=true\nexternalConfigFile='+str(external)+'\nenableClipboard=true\n[log]\nlevel=INFO\n')
    with (BASE/'server.log').open('w') as log:
        child=subprocess.Popen([CORE,'server','-s',str(CONFIG)],stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
    session={'server':child.pid};(BASE/'session.json').write_text(json.dumps(session))
    time.sleep(1)
    if child.poll() is not None:raise RuntimeError((BASE/'server.log').read_text(errors='replace')[-1400:])
    with (BASE/'monitor.log').open('w') as log:
        monitor=subprocess.Popen([sys.executable,str(Path(__file__).resolve()),'watch',str(child.pid)],stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
    session['monitor']=monitor.pid;(BASE/'session.json').write_text(json.dumps(session))
    time.sleep(.3)
    for host in ('x99','alienware'):
        with (BASE/(host+'-tunnel.log')).open('w') as log:
            proc=subprocess.Popen(['/usr/bin/ssh','-NT','-o','BatchMode=yes','-o','ConnectTimeout=5','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15','-o','ServerAliveCountMax=3','-R','127.0.0.1:24803:127.0.0.1:24800',host],stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
        session[host]=proc.pid;(BASE/'session.json').write_text(json.dumps(session))
    return dict(ok=True,detail='Servidor iniciado; conectando X99 e Alienware')

def watch(server):
    connection=socket.socket(socket.AF_UNIX);connection.settimeout(5)
    connection.connect(str(Path(tempfile.gettempdir())/'deskflow-core'))
    connection.sendall(b'hello=notch-status\n')
    first=connection.recv(4096).decode()
    version=first.strip().partition('=')[2]
    connection.sendall(('hello='+version+'\n').encode())
    connected=[];pending=''
    while alive(server):
        try:
            data=connection.recv(65536)
            if not data:break
            pending+=data.decode('utf-8',errors='replace')
            while '\n' in pending:
                line,pending=pending.split('\n',1)
                if line.startswith('connectedClients='):
                    names=line.partition('=')[2].split(',')
                    connected=[key for key,name in [('x99','X99'),('alienware','Alienware')] if name in names]
                elif line in ('connectionState=Listening','connectionState=Disconnected','bye'):connected=[]
        except socket.timeout:connection.sendall(b'noop\n')
        temp=BASE/'connections.tmp';temp.write_text(json.dumps(dict(server=int(server),connected=connected,updated=time.time())));temp.replace(BASE/'connections.json')
    connection.close()

if __name__=='__main__':
    try:
        if len(sys.argv)>1 and sys.argv[1]=='watch':watch(int(sys.argv[2]))
        else:print(json.dumps(main(json.load(sys.stdin)),ensure_ascii=False))
    except Exception as error:print(json.dumps(dict(ok=False,error=str(error)),ensure_ascii=False));__import__('sys').exit(1)
