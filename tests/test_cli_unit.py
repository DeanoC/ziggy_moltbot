#!/usr/bin/env python3
"""
Unit tests for ZiggyStarClaw node - no gateway required

These tests verify the CLI binary works without needing
an OpenClaw gateway connection.
"""

import subprocess
import pytest
from pathlib import Path


def _resolve_cli_binary() -> Path | None:
    repo_root = Path(__file__).resolve().parents[1]
    candidates = [
        repo_root / "zig-out" / "bin" / "ziggystarclaw-cli",
        repo_root / "zig-out" / "bin" / "ziggystarclaw-cli.exe",
        Path.home() / "ZiggyStarClaw" / "zig-out" / "bin" / "ziggystarclaw-cli",
        Path.home() / "ZiggyStarClaw" / "zig-out" / "bin" / "ziggystarclaw-cli.exe",
    ]
    for candidate in candidates:
        if candidate.exists():
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

    def test_legacy_node_service_flag_warns(self, cli):
        """Legacy node-service action flags remain compatible but warn"""
        result = subprocess.run(
            [str(cli), "--node-service-status", "--version"],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0
        assert "Deprecated CLI flag --node-service-status" in result.stderr
        assert "node service status" in result.stderr

    def test_legacy_runner_mode_alias_warns(self, cli):
        """Legacy --runner-mode alias remains compatible but warn"""
        result = subprocess.run(
            [str(cli), "node", "runner", "install", "--runner-mode", "service", "--version"],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0
        assert "Deprecated CLI flag --runner-mode" in result.stderr
        assert "--mode" in result.stderr
    
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
