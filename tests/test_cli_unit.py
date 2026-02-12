#!/usr/bin/env python3
"""
Unit tests for ZiggyStarClaw node - no gateway required

These tests verify the CLI binary works without needing
an OpenClaw gateway connection.
"""

import os
import subprocess
import sys
import pytest
from pathlib import Path


def _resolve_cli_binary() -> Path | None:
    repo_root = Path(__file__).resolve().parents[1]
    is_windows = sys.platform.startswith("win")

    candidates = [
        repo_root / "zig-out" / "bin" / "ziggystarclaw-cli",
        Path.home() / "ZiggyStarClaw" / "zig-out" / "bin" / "ziggystarclaw-cli",
    ]
    if is_windows:
        candidates.extend([
            repo_root / "zig-out" / "bin" / "ziggystarclaw-cli.exe",
            Path.home() / "ZiggyStarClaw" / "zig-out" / "bin" / "ziggystarclaw-cli.exe",
        ])

    for candidate in candidates:
        if not candidate.exists() or not candidate.is_file():
            continue
        if not is_windows and candidate.suffix.lower() == ".exe":
            continue
        if is_windows or os.access(candidate, os.X_OK):
            return candidate
    return None


ZIGGY_CLI = _resolve_cli_binary()


class TestCliHelp:
    """Test CLI help and basic functionality"""
    
    @pytest.fixture
    def cli(self):
        if ZIGGY_CLI is None:
            pytest.skip("CLI not found in zig-out/bin or ~/ZiggyStarClaw/zig-out/bin")
        return ZIGGY_CLI
    
    def test_cli_exists(self, cli):
        """CLI binary exists"""
        assert cli.exists()
        assert cli.stat().st_size > 1000000  # At least 1MB
    
    def test_cli_help(self, cli):
        """CLI shows help"""
        result = subprocess.run(
            [str(cli), "--help"],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0
        assert "ZiggyStarClaw CLI" in result.stdout
        assert "message|messages|chat send <message>" in result.stdout or "chat send <message>" in result.stdout or "--send <message>" in result.stdout
        # Accept either modern command docs or legacy option docs depending on which
        # binary is present on the local machine.
        assert "session|sessions list|use <key>" in result.stdout or "sessions|session list|use <key>" in result.stdout or "session list|use <key>" in result.stdout or "--list-sessions" in result.stdout
        assert "device|devices list|approve <requestId>|reject <requestId>" in result.stdout or "devices|device list|approve <requestId>|reject <requestId>" in result.stdout or "device list|approve <requestId>|reject <requestId>" in result.stdout or "--list-approvals" in result.stdout
        assert "tray startup install|uninstall|start|stop|status" in result.stdout

    def test_node_service_help_prefers_verb_noun(self, cli):
        """Help text promotes node service verb-noun commands"""
        result = subprocess.run(
            [str(cli), "--help"],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0
        assert "node service <action>" in result.stdout
        assert "--node-service-install" not in result.stdout

    def test_removed_node_service_flag_errors(self, cli):
        """Removed legacy node-service flags should hard-fail with guidance"""
        result = subprocess.run(
            [str(cli), "--node-service-status"],
            capture_output=True,
            text=True
        )
        assert result.returncode != 0
        assert "Flag --node-service-status was removed" in result.stderr
        assert "node service status" in result.stderr

    def test_removed_runner_mode_alias_errors(self, cli):
        """Removed --runner-mode alias should hard-fail with guidance"""
        result = subprocess.run(
            [str(cli), "node", "runner", "install", "--runner-mode", "service"],
            capture_output=True,
            text=True
        )
        assert result.returncode != 0
        assert "Flag --runner-mode was removed" in result.stderr
        assert "--mode service|session" in result.stderr

    @pytest.mark.parametrize(
        ("legacy_args", "replacement"),
        [
            (["--send", "hello"], "message send <message>"),
            (["--list-sessions"], "sessions list"),
            (["--list-nodes"], "nodes list"),
            (["--run", "echo hi"], "nodes run <command>"),
            (["--canvas-present"], "nodes canvas present"),
            (["--exec-approvals-get"], "nodes approvals get"),
            (["--list-approvals"], "approvals list"),
        ],
    )
    def test_deprecated_legacy_action_flags_warn(self, cli, legacy_args, replacement):
        """Legacy action flags should warn with noun-verb replacement guidance."""
        result = subprocess.run(
            [str(cli), *legacy_args, "--help"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert "Legacy option" in result.stderr
        assert "is deprecated" in result.stderr
        assert replacement in result.stderr

    @pytest.mark.parametrize(
        "modern_args",
        [
            ["chat", "send", "hello"],
            ["message", "send", "hello"],
            ["messages", "send", "hello"],
            ["session", "list"],
            ["sessions", "list"],
            ["node", "list"],
            ["nodes", "list"],
            ["node", "process", "list"],
            ["nodes", "process", "list"],
            ["node", "canvas", "present"],
            ["nodes", "canvas", "present"],
            ["node", "approvals", "get"],
            ["nodes", "approvals", "get"],
            ["approvals", "list"],
            ["devices", "list"],
        ],
    )
    def test_modern_command_surface_parses_without_deprecation_warning(self, cli, modern_args):
        """Modern noun-verb commands should parse without legacy deprecation warnings."""
        result = subprocess.run(
            [str(cli), *modern_args, "--help"],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert "Legacy option" not in result.stderr

    def test_plural_session_alias_parses_actions(self, cli):
        """`sessions` should behave like `session`"""
        result = subprocess.run(
            [str(cli), "sessions", "nope"],
            capture_output=True,
            text=True
        )
        assert result.returncode != 0
        assert "Unknown session action: nope" in result.stderr

    def test_plural_node_alias_parses_actions(self, cli):
        """`nodes` should behave like `node`"""
        result = subprocess.run(
            [str(cli), "nodes", "nope"],
            capture_output=True,
            text=True
        )
        assert result.returncode != 0
        assert "Unknown subcommand: nodes nope" in result.stderr

    def test_plural_device_alias_parses_actions(self, cli):
        """`devices` should behave like `device`"""
        result = subprocess.run(
            [str(cli), "devices", "nope"],
            capture_output=True,
            text=True
        )
        assert result.returncode != 0
        assert "Unknown device action: nope" in result.stderr

    def test_message_alias_parses_actions(self, cli):
        """`message` should behave like `chat`"""
        result = subprocess.run(
            [str(cli), "message", "nope", "hello"],
            capture_output=True,
            text=True
        )
        assert result.returncode != 0
        assert "Unknown message action: nope" in result.stderr

    @pytest.mark.skipif(sys.platform.startswith("win"), reason="non-Windows parse-path check")
    def test_tray_startup_modern_and_legacy_aliases_parse(self, cli):
        """Both modern and legacy tray startup forms should parse on non-Windows"""
        modern = subprocess.run(
            [str(cli), "tray", "startup", "status"],
            capture_output=True,
            text=True
        )
        assert modern.returncode != 0
        assert "tray startup helpers are only supported on Windows" in modern.stderr

        legacy = subprocess.run(
            [str(cli), "tray", "status"],
            capture_output=True,
            text=True
        )
        assert legacy.returncode != 0
        assert "tray startup helpers are only supported on Windows" in legacy.stderr

    def test_node_mode_help(self, cli):
        """Node mode help is available"""
        result = subprocess.run(
            [str(cli), "--node-mode-help"],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0
        assert "ZiggyStarClaw Node Mode" in result.stdout
        assert "--node-mode" in result.stdout


class TestNodeConfig:
    """Test node configuration"""
    
    @pytest.fixture
    def cli(self):
        if ZIGGY_CLI is None:
            pytest.skip("CLI not found in zig-out/bin or ~/ZiggyStarClaw/zig-out/bin")
        return ZIGGY_CLI
    
    def test_node_mode_without_gateway(self, cli):
        """Node mode fails gracefully without gateway"""
        result = subprocess.run(
            [str(cli), "--node-mode", "--host", "127.0.0.1", "--port", "99999"],
            capture_output=True,
            text=True,
            timeout=10
        )
        # Should fail to connect but not crash
        assert result.returncode != 0 or "error" in result.stderr.lower()


class TestWindowsDuplicateSessionStartupContracts:
    """Regression checks for Windows startup duplicate-session guards."""

    @staticmethod
    def _read_repo_file(*parts: str) -> str:
        repo_root = Path(__file__).resolve().parents[1]
        return (repo_root.joinpath(*parts)).read_text(encoding="utf-8")

    def test_spec_file_exists(self):
        repo_root = Path(__file__).resolve().parents[1]
        spec = repo_root / "docs" / "spec_windows_tray_duplicate_session_startup.md"
        assert spec.exists(), "Expected startup duplicate-session spec file"

    def test_shared_node_owner_mutex_contract(self):
        src = self._read_repo_file("src", "windows", "single_instance.zig")
        assert "Global\\\\ZiggyStarClaw.NodeOwner" in src
        assert "Local\\\\ZiggyStarClaw.NodeOwner" in src
        assert "pub const node_owner_lock_global" in src
        assert "pub const node_owner_lock_local" in src

    def test_runner_and_service_emit_single_instance_diagnostics(self):
        cli_src = self._read_repo_file("src", "main_cli.zig")
        svc_src = self._read_repo_file("src", "windows", "scm_host.zig")

        assert "single_instance_denied_existing_owner mode=runner" in cli_src
        assert "single_instance_owner_released mode=runner" in cli_src
        assert "node supervise blocked: another node owner already holds" in cli_src

        assert "single_instance_denied_existing_owner mode=service" in svc_src
        assert "single_instance_owner_released mode=service" in svc_src


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
