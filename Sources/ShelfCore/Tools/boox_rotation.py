#!/usr/bin/env python3
"""Enable Android auto-rotate and BOOX's per-app system-orientation override.

The BOOX override is exposed only in its E-Ink Center UI, so this helper uses
ADB's accessibility hierarchy to find controls by label instead of relying on
fixed screen coordinates.
"""

from __future__ import annotations

import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path


UI_DUMP = "/sdcard/shelf-boox-ui.xml"
ROTATION_TOGGLE = "Force to follow system orientation"


class SetupError(RuntimeError):
    pass


class Device:
    def __init__(self, adb: str, serial: str):
        self.adb = adb
        self.serial = serial

    def call(self, *args: str, check: bool = True) -> str:
        result = subprocess.run(
            [self.adb, "-s", self.serial, *args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
        )
        if check and result.returncode:
            raise SetupError(result.stdout.strip() or f"ADB command failed ({result.returncode})")
        return result.stdout.strip()

    def shell(self, *args: str, check: bool = True) -> str:
        return self.call("shell", *args, check=check)

    def dump_hierarchy(self) -> str:
        # BOOX firmware occasionally kills the first accessibility dump while
        # E-Ink Center is animating after an orientation transition.
        last = ""
        for attempt in range(3):
            result = subprocess.run(
                [self.adb, "-s", self.serial, "shell", "uiautomator", "dump", UI_DUMP],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=60,
            )
            last = result.stdout.strip()
            if result.returncode == 0:
                return self.shell("cat", UI_DUMP)
            time.sleep(1 + attempt)
        raise SetupError(last or "BOOX accessibility dump was interrupted")

    def tap(self, bounds: str) -> None:
        match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
        if not match:
            raise SetupError("BOOX returned an unreadable control position")
        left, top, right, bottom = map(int, match.groups())
        self.shell("input", "tap", str((left + right) // 2), str((top + bottom) // 2))
        time.sleep(0.7)

    def hierarchy(self) -> ET.Element:
        source = self.dump_hierarchy()
        try:
            return ET.fromstring(source)
        except ET.ParseError as exc:
            raise SetupError("Could not read the BOOX accessibility screen") from exc


def find_text(root: ET.Element, text: str) -> ET.Element | None:
    for node in root.iter("node"):
        if node.attrib.get("text", "").strip().casefold() == text.casefold():
            return node
    return None


def control_state(root: ET.Element, label: str) -> tuple[bool, str] | None:
    """Return (checked, switch bounds) next to a labelled BOOX setting."""
    parents = {child: parent for parent in root.iter() for child in parent}
    label_node = find_text(root, label)
    if label_node is None:
        return None
    current = label_node
    while current in parents:
        current = parents[current]
        controls = [
            n for n in current.iter("node")
            if n.attrib.get("checkable") == "true"
            and n.attrib.get("class", "").rsplit(".", 1)[-1] in {"Switch", "CheckBox"}
        ]
        if controls:
            control = controls[-1]
            return control.attrib.get("checked") == "true", control.attrib.get("bounds", "")
    return None


def ensure_label(device: Device, label: str, *, attempts: int = 2) -> ET.Element:
    for _ in range(attempts):
        root = device.hierarchy()
        node = find_text(root, label)
        if node is not None:
            return node
        time.sleep(0.7)
    raise SetupError(f"BOOX screen did not expose the '{label}' control")


def enable_rotation(device: Device) -> None:
    # Save the requested system setting before bringing KOReader to the front.
    device.shell("settings", "put", "system", "accelerometer_rotation", "1")
    if device.shell("settings", "get", "system", "accelerometer_rotation") != "1":
        raise SetupError("Android did not enable automatic screen rotation")

    device.shell("monkey", "-p", "org.koreader.launcher", "1", check=False)
    time.sleep(2)
    # BOOX tablet Control Center opens by swiping from the upper-right edge.
    size = device.shell("wm", "size")
    match = re.search(r"Physical size:\s*(\d+)x(\d+)", size)
    if not match:
        match = re.search(r"Override size:\s*(\d+)x(\d+)", size)
    if not match:
        raise SetupError("Could not determine the BOOX screen size")
    width, height = map(int, match.groups())
    edge_x = max(1, width - max(8, width // 120))
    device.shell("input", "swipe", str(edge_x), "1", str(edge_x), str(height // 2), "350")

    eink = ensure_label(device, "E-Ink Center")
    device.tap(eink.attrib.get("bounds", ""))
    optimize = ensure_label(device, "Optimize")
    device.tap(optimize.attrib.get("bounds", ""))
    others = ensure_label(device, "Others")
    device.tap(others.attrib.get("bounds", ""))

    for _ in range(3):
        root = device.hierarchy()
        state = control_state(root, ROTATION_TOGGLE)
        if state is not None:
            checked, bounds = state
            if not checked:
                device.tap(bounds)
            # Close BOOX's panels without sending Back through to KOReader.
            device.shell("input", "keyevent", "4", check=False)
            return
        time.sleep(0.7)
    raise SetupError("Could not find the per-app rotation switch in E-Ink Center")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: boox_rotation.py ADB_PATH DEVICE_SERIAL", file=sys.stderr)
        return 2
    try:
        enable_rotation(Device(sys.argv[1], sys.argv[2]))
    except Exception as exc:
        print(f"BOOX auto-rotation setup failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    print("BOOX auto-rotation enabled for Android and KOReader.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
