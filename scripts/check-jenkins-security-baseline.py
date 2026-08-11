#!/usr/bin/env python3
"""Match installed Jenkins core/plugins against official update-center warnings."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any, NoReturn


SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")
MAX_UPDATE_CENTER_BYTES = 64 * 1024 * 1024
IGNORED_PLUGIN_COLUMNS = {"enabled", "disabled", "pinned"}


def fail(message: str) -> NoReturn:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def read_core_version(path: Path) -> str:
    try:
        lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    except (OSError, UnicodeDecodeError) as error:
        fail(f"cannot read controller version: {error}")
    if len(lines) != 1 or SAFE_COMPONENT.fullmatch(lines[0]) is None:
        fail("controller version evidence must contain one safe version")
    return lines[0]


def read_plugins(path: Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as error:
        fail(f"cannot read plugin inventory: {error}")
    plugins: dict[str, str] = {}
    for line_number, line in enumerate(lines, 1):
        fields = line.split()
        if not fields:
            continue
        name = fields[0]
        if SAFE_COMPONENT.fullmatch(name) is None:
            fail(f"unsafe plugin name on inventory line {line_number}")
        candidates = [field for field in fields[1:] if field.lower() not in IGNORED_PLUGIN_COLUMNS]
        version = next((field for field in reversed(candidates) if any(character.isdigit() for character in field)), "")
        if not version or SAFE_COMPONENT.fullmatch(version) is None:
            fail(f"could not identify a safe plugin version on inventory line {line_number}")
        if name in plugins and plugins[name] != version:
            fail(f"plugin inventory contains conflicting versions for {name}")
        plugins[name] = version
    return dict(sorted(plugins.items()))


def read_update_center(path: Path, max_age_hours: int) -> tuple[dict[str, Any], str]:
    try:
        if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_UPDATE_CENTER_BYTES:
            fail("update-center evidence must be a bounded regular file")
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"cannot read update-center evidence: {error}")
    if not isinstance(payload, dict) or not isinstance(payload.get("warnings"), list):
        fail("update-center evidence is missing warnings")
    timestamp_text = payload.get("generationTimestamp")
    if not isinstance(timestamp_text, str):
        fail("update-center evidence is missing generationTimestamp")
    try:
        generated = dt.datetime.fromisoformat(timestamp_text.replace("Z", "+00:00"))
    except ValueError as error:
        fail(f"invalid update-center generationTimestamp: {error}")
    if generated.tzinfo is None:
        fail("update-center generationTimestamp must contain a timezone")
    now = dt.datetime.now(dt.timezone.utc)
    age = now - generated.astimezone(dt.timezone.utc)
    if age < dt.timedelta(minutes=-10) or age > dt.timedelta(hours=max_age_hours):
        fail(f"update-center evidence is stale or from the future: {timestamp_text}")
    return payload, timestamp_text


def affected(version: str, version_ranges: Any) -> bool:
    if not isinstance(version_ranges, list):
        fail("security warning versions must be an array")
    for item in version_ranges:
        if not isinstance(item, dict) or not isinstance(item.get("pattern"), str):
            fail("security warning contains an invalid version pattern")
        pattern = item["pattern"]
        if len(pattern) > 4096:
            fail("security warning version pattern is unexpectedly large")
        try:
            if re.fullmatch(pattern, version):
                return True
        except re.error as error:
            fail(f"security warning contains an invalid version pattern: {error}")
    return False


def evaluate(core: str, plugins: dict[str, str], payload: dict[str, Any]) -> list[dict[str, str]]:
    matches: list[dict[str, str]] = []
    for warning in payload["warnings"]:
        if not isinstance(warning, dict):
            fail("security warning must be an object")
        warning_type = warning.get("type")
        name = warning.get("name")
        if warning_type == "core":
            component = "core"
            installed = core
        elif warning_type == "plugin" and isinstance(name, str) and name in plugins:
            component = name
            installed = plugins[name]
        else:
            continue
        if not affected(installed, warning.get("versions")):
            continue
        message = warning.get("message")
        url = warning.get("url")
        if not isinstance(message, str) or not isinstance(url, str):
            fail("matched security warning lacks message or URL")
        matches.append(
            {
                "component": component,
                "installed_version": installed,
                "message": message,
                "url": url,
            }
        )
    return sorted(matches, key=lambda item: (item["component"], item["url"], item["message"]))


def atomic_write(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--controller-version-file", required=True, type=Path)
    parser.add_argument("--plugins-file", required=True, type=Path)
    parser.add_argument("--update-center-json", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--max-age-hours", type=int, default=96)
    arguments = parser.parse_args()
    if arguments.max_age_hours < 1 or arguments.max_age_hours > 336:
        fail("max age must be between 1 and 336 hours")
    if arguments.output.exists():
        fail(f"output already exists: {arguments.output}")
    core = read_core_version(arguments.controller_version_file)
    plugins = read_plugins(arguments.plugins_file)
    update_center, generated_at = read_update_center(arguments.update_center_json, arguments.max_age_hours)
    warnings = evaluate(core, plugins, update_center)
    result = {
        "schema_version": 1,
        "source": "https://updates.jenkins.io/current/update-center.actual.json",
        "generated_at": generated_at,
        "checked_core_version": core,
        "checked_plugins": plugins,
        "status": "vulnerable" if warnings else "clean",
        "matched_warnings": warnings,
    }
    atomic_write(arguments.output, result)
    if warnings:
        print(f"ERROR: installed Jenkins components match {len(warnings)} current security warning(s)", file=sys.stderr)
        raise SystemExit(3)
    print("Jenkins security baseline is clean for the current official warning feed")


if __name__ == "__main__":
    main()
