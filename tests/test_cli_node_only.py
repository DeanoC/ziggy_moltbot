#!/usr/bin/env python3
"""Tests for the node-only CLI build profile (-Dcli_operator=false)."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest


OPERATOR_DISABLED_HINT = (
    "This CLI build is node-only and cannot act as operator. "
    "Rebuild with -Dcli_operator=true."
)


def _resolve_node_only_cli_binary() -> Path | None:
    env_path = os.environ.get("ZSC_NODE_ONLY_CLI")
    if env_path:
        candidate = Path(env_path).expanduser()
        if candidate.exists() and candidate.is_file():
            return candidate

    repo_root = Path(__file__).resolve().parents[1]
    is_windows = sys.platform.startswith("win")

    base_candidates = [
        repo_root / "zig-out" / "node-only" / "bin" / "ziggystarclaw-cli",
        repo_root / "zig-out" / "node-only-test" / "bin" / "ziggystarclaw-cli",
        repo_root / "zig-out" / "node-only-rel" / "bin" / "ziggystarclaw-cli",
    ]

    if is_windows:
        base_candidates.extend(
            [
                repo_root / "zig-out" / "node-only" / "bin" / "ziggystarclaw-cli.exe",
                repo_root / "zig-out" / "node-only-test" / "bin" / "ziggystarclaw-cli.exe",
                repo_root / "zig-out" / "node-only-rel" / "bin" / "ziggystarclaw-cli.exe",
            ]
        )

    for candidate in base_candidates:
        if not candidate.exists() or not candidate.is_file():
            continue
        if not is_windows and candidate.suffix.lower() == ".exe":
            continue
        if is_windows or os.access(candidate, os.X_OK):
            return candidate
    return None


ZIGGY_NODE_ONLY_CLI = _resolve_node_only_cli_binary()


@pytest.fixture
def cli() -> Path:
    if ZIGGY_NODE_ONLY_CLI is None:
        pytest.skip(
            "node-only CLI not found (build with: "
            "zig build -Dclient=false -Dcli_operator=false --prefix ./zig-out/node-only)"
        )
    return ZIGGY_NODE_ONLY_CLI


def test_node_only_help_profile(cli: Path):
    result = subprocess.run([str(cli), "--help"], capture_output=True, text=True)
    assert result.returncode == 0
    assert "ZiggyStarClaw CLI (node-only build)" in result.stdout
    assert "Options (node-only build):" in result.stdout
    assert "operator/client commands" in result.stdout.lower()
    assert "message|messages|chat send <message>" not in result.stdout


@pytest.mark.parametrize(
    "args",
    [
        ["sessions", "list"],
        ["message", "send", "hello"],
        ["approvals", "list"],
        ["devices", "list"],
        ["--interactive"],
        ["--operator-mode"],
    ],
)
def test_operator_surface_is_disabled(cli: Path, args: list[str]):
    result = subprocess.run([str(cli), *args], capture_output=True, text=True)
    assert result.returncode != 0
    assert OPERATOR_DISABLED_HINT in result.stderr


def test_node_mode_help_still_available(cli: Path):
    result = subprocess.run([str(cli), "--node-mode-help"], capture_output=True, text=True)
    assert result.returncode == 0
    assert "ZiggyStarClaw Node Mode" in result.stdout


def test_node_only_update_url_maintenance(cli: Path, tmp_path: Path):
    cfg = tmp_path / "node-only-config.json"
    result = subprocess.run(
        [
            str(cli),
            "--config",
            str(cfg),
            "--update-url",
            "https://example.com/update.json",
            "--print-update-url",
        ],
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert "Manifest URL: https://example.com/update.json" in result.stdout
    assert "Normalized URL: https://example.com/update.json" in result.stdout


def test_node_only_save_config_without_operator_chunk(cli: Path, tmp_path: Path):
    cfg = tmp_path / "node-only-save-config.json"
    result = subprocess.run(
        [
            str(cli),
            "--config",
            str(cfg),
            "--url",
            "wss://example.com/ws",
            "--token",
            "test-token",
            "--save-config",
        ],
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert cfg.exists()
    saved = cfg.read_text(encoding="utf-8")
    assert "wss://example.com/ws" in saved
    assert "test-token" in saved
