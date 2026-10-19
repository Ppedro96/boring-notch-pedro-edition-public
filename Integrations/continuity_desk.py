"""Local desk dispatch for a persistent continuity Client; no transport of local paths."""
import importlib.util
import json
from pathlib import Path

SHARED = frozenset(('status', 'capabilities', 'submit', 'jobs', 'list', 'job', 'cancel',
                    'archive', 'retry', 'result', 'retrieve', 'download', 'deskflow',
                    'input_status', 'input_start', 'input_stop', 'input_home', 'input_layout', 'input_mode'))


def config_path():
    return Path(__file__).parent / 'continuity' / 'config.json'


def enabled():
    path = config_path()
    if not path.exists():
        return False
    # A malformed configured bridge must fail, never quietly become a second queue.
    return json.loads(path.read_text()).get('enabled') is True


def broker():
    spec = importlib.util.spec_from_file_location('desk_local_broker', Path(__file__).with_name('desk-hub.py'))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def native(client, request, timeout=60):
    """Return broker shape inside result, with result.output always local for downloads."""
    request = {k: v for k, v in request.items() if not k.startswith('_continuity')}
    command = request.get('command')
    if command not in SHARED:
        return dict(ok=True, result=broker().local_main(request))
    if request.pop('legacyLocal', False):
        if command not in ('result', 'retrieve', 'download', 'job'):
            raise ValueError('legacy history is read-only')
        return dict(ok=True, result=broker().legacy_history(request))
    if command == 'submit':
        if 'source' in request:
            request['blob'] = client.stage_file(request.pop('source'), timeout)
        request.pop('originalName', None)
    response = client.request(dict(op='desk', request=request), timeout)
    result = response.get('result', {})
    if result.get('ok') and command in ('result', 'retrieve', 'download'):
        if 'blob' not in result:
            raise ValueError('coordinator returned no verified result')
        result = dict(result, output=str(client.fetch_blob(result['blob'], timeout)))
    if result.get('ok') and command in ('jobs', 'list'):
        result = dict(result, localHistory=broker().local_history())
    return dict(response, result=result)
