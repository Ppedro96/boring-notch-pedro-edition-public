"""Launch signed input engines through launchd, preserving their own TCC identity."""
import os
from pathlib import Path
import plistlib
import re
import subprocess
import time


def target(label):
    if not re.fullmatch(r'local\.insight-notch\.[a-z-]+', label):
        raise ValueError('Invalid session agent label')
    return 'gui/'+str(os.getuid())+'/'+label


def info(label):
    result = subprocess.run(['/bin/launchctl', 'print', target(label)], capture_output=True, text=True, timeout=5)
    return result.stdout if result.returncode == 0 else ''


def owned(text, args):
    # Match the executable and dedicated runtime configuration, never a name alone.
    return bool(text and args[0] in text and args[args.index('--config')+1 if '--config' in args else args.index('-s')+1] in text)


def stop(label, args):
    text = info(label)
    if not text:
        return
    if not owned(text, args):
        raise RuntimeError('Session agent belongs to a different configuration')
    result = subprocess.run(['/bin/launchctl', 'bootout', target(label)], capture_output=True, text=True, timeout=10)
    if result.returncode and info(label):
        raise RuntimeError('Could not stop the owned session agent')


def start(label, args, directory, logfile, env=None):
    stop(label, args)
    path = Path(directory)/'session-agent.plist'
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    value = dict(Label=label, ProgramArguments=args, RunAtLoad=True, KeepAlive=False,
                 ProcessType='Interactive', LimitLoadToSessionType='Aqua',
                 StandardOutPath=str(logfile), StandardErrorPath=str(logfile))
    if env:
        value['EnvironmentVariables'] = env
    path.write_bytes(plistlib.dumps(value))
    path.chmod(0o600)
    result = subprocess.run(['/bin/launchctl', 'bootstrap', 'gui/'+str(os.getuid()), str(path)],
                            capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError('Could not start the graphical session agent: '+result.stderr[-300:])
    deadline = time.monotonic()+5
    while time.monotonic() < deadline:
        text = info(label)
        match = re.search(r'^\s*pid = (\d+)\s*$', text, re.M)
        if match and owned(text, args):
            return int(match[1])
        time.sleep(.1)
    raise RuntimeError('Input engine exited while starting')
