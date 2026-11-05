#!/usr/bin/env python3
"""Install one low-frequency login/recovery job for an existing local sync stack."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'Sources/ShelfCore/Tools'))
from shelf_config import configured_path

home=Path.home()
scripts=configured_path('scripts','~/Books/scripts')
logs=configured_path('logs','~/Books/logs')
state=configured_path('state','~/Books/state')
for folder in (scripts,logs,state):folder.mkdir(parents=True,exist_ok=True)
label='app.shelf.sync-runtime'
job=home/'Library/LaunchAgents'/f'{label}.plist'
job.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(job)],capture_output=True)
for name in ('sync_runtime_watchdog.py','shelf_config.py'):
    source=ROOT/'Sources/ShelfCore/Tools'/name
    destination=scripts/name
    if source.resolve()!=destination.resolve():shutil.copy2(source,destination)
value={'Label':label,'ProgramArguments':['/usr/bin/python3',str(scripts/'sync_runtime_watchdog.py')],
       'RunAtLoad':True,'StartInterval':120,'ProcessType':'Background',
       'EnvironmentVariables':{'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'},
       'StandardOutPath':str(logs/'sync-runtime.stdout.log'),'StandardErrorPath':str(logs/'sync-runtime.stderr.log')}
job.write_bytes(plistlib.dumps(value))
subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(job)],check=True)
print('Installed sync recovery at login and every two minutes. Healthy checks are silent; failed recovery backs off.')
