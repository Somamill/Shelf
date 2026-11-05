import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS=Path(__file__).resolve().parents[2]/'Sources/ShelfCore/Tools'
sys.path.insert(0,str(TOOLS))
spec=importlib.util.spec_from_file_location('runtime_watchdog',TOOLS/'sync_runtime_watchdog.py')
watchdog=importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)

class RuntimeTests(unittest.TestCase):
    def test_healthy_services_do_not_start_docker_or_log(self):
        with tempfile.TemporaryDirectory() as root,patch.object(watchdog,'STATE',Path(root)/'state'),patch.object(watchdog,'LOGS',Path(root)/'logs'),patch.object(watchdog,'healthy',return_value=True),patch.object(watchdog,'command') as command:
            watchdog.main()
            command.assert_not_called()
            self.assertFalse((watchdog.LOGS/'sync-runtime.log').exists())

    def test_retry_backoff_does_not_wake_docker(self):
        with tempfile.TemporaryDirectory() as root,patch.object(watchdog,'STATE',Path(root)),patch.object(watchdog,'LOGS',Path(root)),patch.object(watchdog,'healthy',return_value=False),patch.object(watchdog,'command') as command:
            watchdog.save(Path(root)/'sync-runtime-health.json',{'retryAfter':watchdog.time.time()+600})
            watchdog.main()
            command.assert_not_called()
