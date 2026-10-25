"""Small shared reader for Shelf's private per-user JSON configuration."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any


def _load() -> dict[str, Any]:
    configured = os.environ.get("SHELF_CONFIG")
    path = Path(configured).expanduser() if configured else Path.home() / "Library/Application Support/Shelf/config.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


_CONFIG = _load()


def configured_value(section: str, key: str, fallback: str) -> str:
    values = _CONFIG.get(section, {})
    value = values.get(key) if isinstance(values, dict) else None
    return value if isinstance(value, str) and value else fallback


def configuration_section(section: str) -> dict[str, Any]:
    value = _CONFIG.get(section, {})
    return value if isinstance(value, dict) else {}


def configured_path(key: str, fallback: str) -> Path:
    value: Any = _CONFIG.get("paths", {})
    for part in key.split("."):
        value = value.get(part) if isinstance(value, dict) else None
    return Path(value).expanduser() if isinstance(value, str) and value else Path(fallback).expanduser()
