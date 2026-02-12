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
        # Accept either modern command docs or legacy option docs depending on which
        # binary is present on the local machine.
        assert "session list|use <key>" in result.stdout or "--list-sessions" in result.stdout
        assert "device list|approve <requestId>|reject <requestId>" in result.stdout or "--list-approvals" in result.stdout

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


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
