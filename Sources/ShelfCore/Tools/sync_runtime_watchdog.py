#!/usr/bin/env python3
"""Low-frequency local sync recovery. Healthy checks produce no log output."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import urllib.request
from shelf_config import configured_path, configuration_section

STATE = configured_path('state', '~/Books/state')
LOGS = configured_path('logs', '~/Books/logs')
TOOLS = configuration_section('tools')
DOCKER = TOOLS.get('docker') or shutil.which('docker') or '/opt/homebrew/bin/docker'
COLIMA = shutil.which('colima') or '/opt/homebrew/bin/colima'


def command(args, timeout=15):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def healthy(port, path):
    try:
        request = urllib.request.Request(f'http://127.0.0.1:{port}{path}', headers={'Accept':'application/vnd.koreader.v1+json'})
        with urllib.request.urlopen(request, timeout=3) as response:
            return response.status == 200
    except (OSError, ValueError):
        return False


def main():
    STATE.mkdir(parents=True, exist_ok=True)
    LOGS.mkdir(parents=True, exist_ok=True)
    with (STATE/'.sync-runtime-watchdog.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        statefile = STATE/'sync-runtime-health.json'
        try:
            state = json.loads(statefile.read_text())
        except (OSError, ValueError):
            state = {}
        now = time.time()
        endpoints = [('kosync',17200,'/healthcheck'), ('crosspoint-sync',17303,'/healthz')]
        failures = [name for name,port,path in endpoints if not healthy(port,path)]
        if not failures:
            if state.get('offline'):
                log('RECOVERED · KOReader Sync and CrossPoint are responding.')
            save(statefile, {'offline':False,'checkedAt':now,'failures':0})
            return
        if now < state.get('retryAfter',0):
            return
        attempt = int(state.get('failures',0))+1
        try:
            if command([DOCKER,'info','--format','{{.ServerVersion}}']).returncode:
                context = command([DOCKER,'context','show']).stdout.strip()
                if context != 'colima':
                    raise RuntimeError('Docker is offline; start the configured Docker runtime.')
                log('RECOVERING · Starting Colima for the local sync servers.')
                result = command([COLIMA,'start'],timeout=120)
                if result.returncode:
                    raise RuntimeError('Colima could not start; check its service log.')
            for name in failures:
                result = command([DOCKER,'inspect','--format','{{.State.Status}}',name])
                if result.returncode:
                    raise RuntimeError(f'The {name} container is missing; restore its existing deployment.')
                if result.stdout.strip() != 'running':
                    result = command([DOCKER,'start',name],timeout=45)
                elif attempt >= 2:
                    log(f'RECOVERING · Restarting unresponsive {name}.')
                    result = command([DOCKER,'restart',name],timeout=45)
                if result.returncode:
                    raise RuntimeError(f'{name} could not restart.')
            save(statefile, {'offline':True,'checkedAt':now,'failures':attempt,'retryAfter':now+120})
        except (subprocess.TimeoutExpired, RuntimeError, OSError) as error:
            message = str(error) if isinstance(error,RuntimeError) else 'Runtime recovery timed out or could not run.'
            if state.get('error') != message:
                log('WARNING · '+message)
            save(statefile, {'offline':True,'checkedAt':now,'failures':attempt,'retryAfter':now+min(900,120*attempt),'error':message})


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value))
    os.chmod(temporary,0o600)
    os.replace(temporary,path)


def log(message):
    with (LOGS/'sync-runtime.log').open('a') as output:
        output.write(time.strftime('[%Y-%m-%d %H:%M:%S] ')+message+'\n')


if __name__ == '__main__':
    main()
