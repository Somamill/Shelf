#!/usr/bin/env python3
"""Merge Calibre and KOReader Sync settings into KOReader's Lua settings files."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


TOKEN = re.compile(
    r'''\s+|--[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|'''
    r'''\[|\]|\{|\}|=|,|;|-?(?:\d+\.\d*|\d+)(?:[eE][+-]?\d+)?|[A-Za-z_][A-Za-z_0-9]*'''
)


def unquote(token: str) -> str:
    quote = token[0]
    body = token[1:-1]
    out: list[str] = []
    i = 0
    while i < len(body):
        ch = body[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        i += 1
        if i >= len(body):
            raise ValueError("unfinished Lua string escape")
        esc = body[i]
        simple = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}
        if esc in simple:
            out.append(simple[esc])
            i += 1
        elif esc in "\\\"'":
            out.append(esc)
            i += 1
        elif esc.isdigit():
            j = i
            while j < min(i + 3, len(body)) and body[j].isdigit():
                j += 1
            out.append(chr(int(body[i:j]) % 256))
            i = j
        elif esc == "z":
            i += 1
            while i < len(body) and body[i].isspace():
                i += 1
        elif esc == "\n":
            out.append("\n")
            i += 1
        else:
            raise ValueError(f"unsupported Lua string escape \\{esc}")
    return "".join(out)


class LuaDataParser:
    """Parser for the data-only Lua tables written by KOReader's LuaSettings."""

    def __init__(self, source: str):
        self.tokens = []
        pos = 0
        while pos < len(source):
            match = TOKEN.match(source, pos)
            if not match:
                raise ValueError(f"unsupported Lua syntax near byte {pos}")
            token = match.group(0)
            pos = match.end()
            if token.isspace() or token.startswith("--"):
                continue
            self.tokens.append(token)
        self.index = 0

    def peek(self) -> str | None:
        return self.tokens[self.index] if self.index < len(self.tokens) else None

    def take(self, expected: str | None = None) -> str:
        token = self.peek()
        if token is None or (expected is not None and token != expected):
            raise ValueError(f"expected {expected or 'value'}, got {token}")
        self.index += 1
        return token

    def parse(self):
        if self.peek() == "return":
            self.take("return")
        value = self.value()
        if self.peek() is not None:
            raise ValueError(f"unexpected trailing Lua token {self.peek()}")
        if not isinstance(value, dict):
            raise ValueError("KOReader settings root is not a table")
        return value

    def value(self):
        token = self.peek()
        if token == "{":
            return self.table()
        if token and token[:1] in ('"', "'"):
            return unquote(self.take())
        if token in ("true", "false", "nil"):
            self.take()
            return {"true": True, "false": False, "nil": None}[token]
        if token and re.fullmatch(r"-?\d+", token):
            self.take()
            return int(token)
        if token and re.fullmatch(r"-?(?:\d+\.\d*|\d+)(?:[eE][+-]?\d+)?", token):
            self.take()
            return float(token)
        raise ValueError(f"unsupported Lua value {token}")

    def table(self) -> dict:
        result = {}
        self.take("{")
        while self.peek() != "}":
            self.take("[")
            key = self.value()
            self.take("]")
            self.take("=")
            value = self.value()
            if key is None:
                raise ValueError("nil Lua table key")
            if value is not None:
                result[key] = value
            if self.peek() == "," or self.peek() == ";":
                self.take()
            elif self.peek() != "}":
                raise ValueError("expected a comma between Lua table entries")
        self.take("}")
        return result


def lua_quote(value: str) -> str:
    pieces = ['"']
    for ch in value:
        code = ord(ch)
        if ch == "\\":
            pieces.append("\\\\")
        elif ch == '"':
            pieces.append('\\"')
        elif ch == "\n":
            pieces.append("\\n")
        elif ch == "\r":
            pieces.append("\\r")
        elif ch == "\t":
            pieces.append("\\t")
        elif code < 32 or code == 127:
            pieces.append(f"\\{code:03d}")
        else:
            pieces.append(ch)
    pieces.append('"')
    return "".join(pieces)


def lua_value(value, indent: int = 0) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "nil"
    if isinstance(value, str):
        return lua_quote(value)
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, dict):
        if not value:
            return "{}"
        pad = " " * (indent + 1)
        items = []
        keys = sorted(value, key=lambda k: (0, k) if isinstance(k, int) else (1, str(k)))
        for key in keys:
            key_lua = str(key) if isinstance(key, int) else lua_quote(str(key))
            items.append(f"{pad}[{key_lua}] = {lua_value(value[key], indent + 1)},")
        return "{\n" + "\n".join(items) + "\n" + (" " * indent) + "}"
    raise ValueError(f"unsupported settings value type: {type(value).__name__}")


def read_settings(path: Path) -> dict:
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    return LuaDataParser(text).parse()


def write_settings(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("return " + lua_value(value) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: boox_settings.py EXISTING_DIR OUTPUT_DIR", file=sys.stderr)
        return 2
    values = json.load(sys.stdin)
    existing = Path(sys.argv[1])
    output = Path(sys.argv[2])
    opds_url = values["opds_url"]
    sync_url = values["sync_url"]
    username = values["username"]
    password = values["calibre_password"]
    userkey = values["kosync_userkey"]

    opds = read_settings(existing / "opds.lua")
    servers = opds.get("servers", {})
    if isinstance(servers, list):
        servers = {index + 1: server for index, server in enumerate(servers)}
    if not isinstance(servers, dict):
        raise ValueError("KOReader OPDS server list has an unsupported shape")
    server = next((item for item in servers.values() if isinstance(item, dict) and item.get("url") == opds_url), None)
    if server is None:
        numeric = [key for key in servers if isinstance(key, int)]
        server = {}
        servers[max(numeric, default=0) + 1] = server
    server.update({"title": "Calibre Library", "url": opds_url, "username": username, "password": password})
    opds["servers"] = servers
    opds.setdefault("settings", {})
    opds.setdefault("downloads", {})
    opds.setdefault("pending_syncs", {})
    write_settings(output / "opds.lua", opds)

    sync = read_settings(existing / "kosync.lua")
    sync_settings = sync.get("settings", {})
    if not isinstance(sync_settings, dict):
        raise ValueError("KOReader Sync settings have an unsupported shape")
    sync_settings.update({"custom_server": sync_url, "username": username, "userkey": userkey})
    sync["settings"] = sync_settings
    write_settings(output / "kosync.lua", sync)

    # Preserve the monolithic legacy settings file too; newer KOReader releases
    # migrate away from this storage key, while older releases still read it.
    reader = read_settings(existing / "settings.reader.lua")
    legacy = reader.get("kosync", {})
    if not isinstance(legacy, dict):
        raise ValueError("legacy KOReader Sync settings have an unsupported shape")
    legacy.update({"custom_server": sync_url, "username": username, "userkey": userkey})
    reader["kosync"] = legacy
    write_settings(output / "settings.reader.lua", reader)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"BOOX settings merge failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
