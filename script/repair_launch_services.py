#!/usr/bin/env python3
"""Keep the installed Insight Notch as the sole launchable registered copy.

Preserves backup contents, moving legacy bundles out of /Applications. Does not
modify the installed bundle, preferences, signature, or privacy authorizations.
"""
from __future__ import annotations
import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import time

IDENTIFIER = 'theboringteam.boringnotch'
INSTALLED = Path('/Applications/Insight Notch.app')
LSREGISTER = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
BACKUPS = Path.home() / 'Library/Application Support/PedroEditionBackups'


def is_notch_bundle(path):
    try:
        with (Path(path) / 'Contents/Info.plist').open('rb') as file:
            return plistlib.load(file).get('CFBundleIdentifier') == IDENTIFIER
    except (OSError, plistlib.InvalidFileException):
        return False


def processes():
    output = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
    result = []
    for line in output.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            result.append((int(parts[0]), parts[1]))
    return result


def stop_instances(stop_all=False):
    roots = {Path(command[:-len('/Contents/MacOS/boringNotch')])
             for _, command in processes() if command.endswith('/Contents/MacOS/boringNotch')}
    roots = {p for p in roots if is_notch_bundle(p) and (stop_all or p != INSTALLED)}
    selected = [(pid, command) for pid, command in processes()
                if any(command == str(root / 'Contents/MacOS/boringNotch') or
                       command.startswith(str(root / 'Contents/XPCServices') + '/') for root in roots)]
    if not selected:
        return []
    for pid, _ in selected:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        alive = {pid for pid, _ in processes()}
        if not any(pid in alive for pid, _ in selected):
            break
        time.sleep(0.1)
    alive = {pid for pid, _ in processes()}
    for pid, _ in selected:
        if pid in alive:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    return [str(root) for root in sorted(roots)]


def registered_copies():
    output = subprocess.check_output([LSREGISTER, '-dump'], text=True)
    result = set()
    for record in re.split(r'\n-+\n', output):
        if not re.search(r'^\s*identifier:\s*' + re.escape(IDENTIFIER) + r'\s*$', record, re.M):
            continue
        match = re.search(r'^\s*path:\s*(.*?)\s+\(0x[0-9a-f]+\)\s*$', record, re.M)
        if match:
            result.add(Path(match.group(1)))
    return result


def repair():
    if not is_notch_bundle(INSTALLED):
        raise SystemExit('The installed Insight Notch bundle was not found; no registrations changed.')
    stopped = stop_instances()
    copies = registered_copies()
    moved = []
    report = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'stopped': stopped, 'moved': moved, 'unregister_warnings': []}
    BACKUPS.mkdir(parents=True, exist_ok=True)
    report_path = BACKUPS / ('launch-repair-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.json')
    def save_report():
        report_path.write_text(json.dumps(report, indent=2) + '\n')
    save_report()
    # Hidden archive is outside the application scan paths. Never overwrite backups.
    archive = BACKUPS / '.legacy-apps'
    archive.mkdir(parents=True, exist_ok=True)
    for path in sorted(copies):
        if path.parent != Path('/Applications') or not path.name.startswith('boringNotch.app.') or not is_notch_bundle(path):
            continue
        destination = archive / path.name
        if destination.exists():
            destination = archive / (path.name + '-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
        path.rename(destination)
        moved.append({'from': str(path), 'to': str(destination)})
        save_report()
    # Unregister only this product's other copies, including moved bundle records.
    paths_to_remove = (copies - {INSTALLED}) | {Path(item['to']) for item in moved}
    for path in sorted(paths_to_remove):
        result = subprocess.run([LSREGISTER, '-u', str(path)], text=True, capture_output=True)
        # A moved/hidden or already unregistered bundle can return -10814.
        # The fresh registry snapshot below determines whether removal succeeded.
        if result.returncode:
            report['unregister_warnings'].append({'path': str(path), 'output': result.stdout + result.stderr})
    subprocess.run([LSREGISTER, '-f', str(INSTALLED)], check=True, stdout=subprocess.DEVNULL)
    remaining = registered_copies()
    report['registered'] = [str(p) for p in sorted(remaining)]
    save_report()
    print(f'Stopped {len(stopped)} duplicate app(s); preserved {len(moved)} legacy backup(s).')
    print(f'Registered copies: {len(remaining)}; report: {report_path}')
    if remaining != {INSTALLED}:
        raise SystemExit('Unexpected registered copies remain; inspect the repair report.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--stop-all', action='store_true', help='Stop all product instances before installation; do not change registrations.')
    args = parser.parse_args()
    if args.stop_all:
        print(f'Stopped {len(stop_instances(stop_all=True))} app(s).')
    else:
        repair()
