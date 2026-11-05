"""Run with: python3 -m unittest discover -s Tests/Python."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


class BridgeFailureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        config = root / "config.json"
        config.write_text(json.dumps({"paths": {
            "booksRoot": str(root), "state": str(root / "state"),
            "logs": str(root / "logs"),
        }}))
        tools = Path(__file__).resolve().parents[2] / "Sources/ShelfCore/Tools"
        with patch.dict(os.environ, SHELF_CONFIG=str(config)), patch.object(sys, "path", [str(tools)] + sys.path):
            # Configuration is read on import; avoid reusing another test's paths.
            with patch.dict(sys.modules):
                sys.modules.pop("shelf_config", None)
                spec = importlib.util.spec_from_file_location("bridge_under_test", tools / "kosync_calibre_bridge.py")
                self.bridge = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(self.bridge)

    def test_timeout_reports_failure_without_command_credentials_and_releases_lock(self):
        bridge = self.bridge
        failure = subprocess.TimeoutExpired(["calibredb", "--password", "private-value"], 150)
        with patch.object(bridge, "cmd", side_effect=failure):
            for _ in range(2):
                with self.assertRaises(SystemExit) as result:
                    bridge.main()
                self.assertEqual(result.exception.code, 1)
        output = Path(bridge.LOGFILE).read_text()
        self.assertEqual(output.count("bridge command timed out"), 2)
        self.assertNotIn("private-value", output)
        self.assertNotIn("BRIDGE END", output)

    def test_unavailable_docker_reports_actionable_warning_without_traceback(self):
        bridge = self.bridge
        failure = subprocess.CalledProcessError(1, [bridge.DOCKER, "exec", "kosync", "private-value"])
        with patch.object(bridge, "cmd", side_effect=failure):
            with self.assertRaises(SystemExit):
                bridge.main()
        output = Path(bridge.LOGFILE).read_text()
        self.assertIn("automatic recovery will retry", output)
        self.assertNotIn("private-value", output)
        self.assertNotIn("CalledProcessError", output)

    def test_activity_history_preserves_real_syncs_without_command_noise(self):
        bridge = self.bridge
        bridge.log("BRIDGE START")
        bridge.update_activity_history()
        bridge.log("SYNCED book=163 fields_updated=1 percentage=0.041 device=Shelf")
        bridge.log("WARNING unavailable dependency")
        events = [json.loads(line) for line in (Path(bridge.LOGS)/"reading-activity.jsonl").read_text().splitlines()]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["bookId"],163)
        self.assertEqual(events[0]["progress"],0.041)

    def test_failed_write_does_not_mark_field_as_synced(self):
        bridge = self.bridge
        book = {"*ko_progint": 10}
        with patch.object(bridge, "cmd", return_value=subprocess.CompletedProcess([], 1, "", "server unavailable")):
            self.assertEqual(bridge.set_custom_if_changed("#ko_progint", 1, 20, book), (False, False))
        self.assertEqual(book["*ko_progint"], 10)


if __name__ == "__main__":
    unittest.main()
