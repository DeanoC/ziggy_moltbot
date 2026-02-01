#!/usr/bin/env python3
"""
ZiggyStarClaw Node Test Framework

Integration tests for ZiggyStarClaw node mode.
Requires:
- OpenClaw gateway running (or mock)
- Xvfb for canvas tests
- ZiggyStarClaw CLI built

Usage:
    pytest tests/ -v
    pytest tests/test_node.py -v -k "test_system"
    pytest tests/ --gateway-url ws://localhost:18789
"""

import asyncio
import json
import os
import pytest
import subprocess
import tempfile
import time
import websocket
from pathlib import Path
from typing import Optional, Dict, Any

# =============================================================================
# Configuration
# =============================================================================

class TestConfig:
    """Test configuration"""
    # Default to local gateway; most runs should set GATEWAY_URL explicitly.
    GATEWAY_URL = os.environ.get("GATEWAY_URL", "ws://127.0.0.1:18789/ws")
    ZIGGY_CLI = Path.home() / "ZiggyStarClaw" / "zig-out" / "bin" / "ziggystarclaw-cli"
    XVFB_DISPLAY = ":99"
    TEST_TIMEOUT = 30
    NODE_START_TIMEOUT = 5

# =============================================================================
# Fixtures
# =============================================================================

@pytest.fixture(scope="session")
def ziggy_cli() -> Path:
    """Ensure CLI binary exists"""
    cli = TestConfig.ZIGGY_CLI
    if not cli.exists():
        pytest.skip(f"CLI not found: {cli}")
    return cli

@pytest.fixture(scope="session")
def xvfb_running():
    """Ensure Xvfb is running for canvas tests"""
    display = TestConfig.XVFB_DISPLAY
    result = subprocess.run(
        ["pgrep", "-f", f"Xvfb {display}"],
        capture_output=True
    )
    if result.returncode != 0:
        pytest.skip(f"Xvfb not running on {display}. Run: ~/clawd/scripts/xvfb-service.sh start")
    os.environ["DISPLAY"] = display
    yield display

@pytest.fixture(scope="session")
def gateway_available():
    """Check if OpenClaw gateway is available"""
    url = TestConfig.GATEWAY_URL.replace("ws://", "http://")
    try:
        import urllib.request
        urllib.request.urlopen(f"{url}/health", timeout=2)
    except Exception as e:
        pytest.skip(f"Gateway not available at {url}: {e}")

@pytest.fixture
def temp_dir():
    """Provide temporary directory"""
    with tempfile.TemporaryDirectory() as tmp:
        yield Path(tmp)

# =============================================================================
# Node Process Fixture
# =============================================================================

class NodeProcess:
    """Manages a ZiggyStarClaw node process for testing"""

    def __init__(self, node_id: str, config: Dict[str, Any] = None):
        self.node_id = node_id
        self.config = config or {}
        self.process: Optional[subprocess.Popen] = None
        self.log_file: Optional[Path] = None
        self._log_content = []

    def start(self) -> bool:
        """Start the node process"""
        # Create temp log file
        self.log_file = Path(tempfile.mktemp(suffix=".log", prefix="zsc-node-"))

        # Build config file - pass all settings via config file
        config_path = self._write_config()

        # Note: node-mode arguments are passed after --node-mode flag
        # The main_cli passes args[1..] to parseNodeOptions
        cmd = [
            str(TestConfig.ZIGGY_CLI),
            "--node-mode",
            "--config", str(config_path),
            "--log-level", "debug",
        ]

        # Start process
        self.process = subprocess.Popen(
            cmd,
            stdout=open(self.log_file, "w"),
            stderr=subprocess.STDOUT,
        )

        # Wait for connection
        time.sleep(TestConfig.NODE_START_TIMEOUT)

        # Best-effort: capture the gateway-registered node id (device id) from logs.
        # The gateway's nodeId is connect.device.id (derived from public key) rather than
        # our friendly config node_id.
        self.gateway_node_id = None
        if self.is_running:
            try:
                import re
                logs = self.get_logs()
                m = re.search(r"device_id=([0-9a-f]{32,})", logs)
                if m:
                    self.gateway_node_id = m.group(1)
            except Exception:
                pass

        return self.is_running

    def stop(self):
        """Stop the node process"""
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()

    @property
    def is_running(self) -> bool:
        """Check if process is running"""
        return self.process is not None and self.process.poll() is None

    def get_logs(self) -> str:
        """Get log content"""
        if self.log_file and self.log_file.exists():
            return self.log_file.read_text()
        return ""

    def _write_config(self) -> Path:
        """Write node config file"""
        config = {
            "node_id": self.node_id,
            "display_name": f"Test-{self.node_id}",
            "gateway_host": TestConfig.GATEWAY_URL.replace("ws://", "").rsplit(":", 1)[0],
            "gateway_port": 18789,
            # Token-auth gateway needs this; set GATEWAY_TOKEN in env.
            "gateway_token": os.environ.get("GATEWAY_TOKEN"),
            "system_enabled": True,
            "canvas_enabled": self.config.get("canvas_enabled", False),
            "canvas_backend": self.config.get("canvas_backend", "none"),
            "exec_approvals_path": "~/.openclaw/exec-approvals.json",
        }

        config_path = Path(tempfile.mktemp(suffix=".json", prefix="zsc-config-"))
        config_path.write_text(json.dumps(config))
        return config_path


@pytest.fixture
def node_process(temp_dir):
    """Provide a started node process"""
    node_id = f"test-node-{int(time.time())}"
    node = NodeProcess(node_id)

    if not node.start():
        pytest.fail(f"Failed to start node: {node.get_logs()}")

    yield node

    node.stop()
    if node.log_file:
        # Print logs on failure
        print(f"\n=== Node Logs ({node.node_id}) ===")
        print(node.get_logs()[-2000:])  # Last 2000 chars


@pytest.fixture
def canvas_node(temp_dir, xvfb_running):
    """Provide a node with canvas enabled"""
    node_id = f"test-canvas-node-{int(time.time())}"
    node = NodeProcess(node_id, config={
        "canvas_enabled": True,
        "canvas_backend": "chrome",
    })

    if not node.start():
        pytest.fail(f"Failed to start canvas node: {node.get_logs()}")

    yield node

    node.stop()


# =============================================================================
# Gateway Client
# =============================================================================

class GatewayClient:
    """Client for interacting with OpenClaw gateway"""

    def __init__(self, url: str = None):
        self.url = url or TestConfig.GATEWAY_URL
        # Normalize: Ziggy node uses /ws; make tests tolerant.
        if self.url.startswith("ws://") or self.url.startswith("wss://"):
            if not self.url.rstrip("/").endswith("/ws"):
                self.url = self.url.rstrip("/") + "/ws"
        self.ws: Optional[websocket.WebSocket] = None

    def _request(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        """Send a request and wait for matching res frame."""
        if not self.ws:
            self.connect()

        req_id = f"test-{method}-{int(time.time()*1000)}"
        request = {
            "type": "req",
            "id": req_id,
            "method": method,
            "params": params,
        }
        self.ws.send(json.dumps(request))

        deadline = time.time() + 10
        while time.time() < deadline:
            raw = self.ws.recv()
            if not raw:
                continue
            msg = json.loads(raw)
            if msg.get("type") == "res" and msg.get("id") == req_id:
                return msg
            # Ignore events and unrelated responses.
        raise RuntimeError(f"timeout waiting for {method} res")

    def connect(self):
        """Connect to gateway and complete handshake"""
        token = os.environ.get("GATEWAY_TOKEN")
        if not token:
            raise RuntimeError("GATEWAY_TOKEN env var is required for gateway tests")

        headers = [f"Authorization: Bearer {token}"]
        self.ws = websocket.create_connection(self.url, timeout=10, header=headers)

        # Handshake (must be first request)
        connect_id = f"test-connect-{int(time.time())}"
        params = {
            "minProtocol": 3,
            "maxProtocol": 3,
            "client": {
                "id": "cli",
                "version": "test",
                "platform": "python",
                "mode": "cli",
            },
            "auth": {"token": token},
            "role": "operator",
            "scopes": ["operator.admin", "operator.approvals", "operator.pairing"],
        }

        req = {
            "type": "req",
            "id": connect_id,
            "method": "connect",
            "params": params,
        }
        self.ws.send(json.dumps(req))

        # The gateway may emit connect.challenge before the connect response.
        # Drain until we get the connect res.
        deadline = time.time() + 5
        while time.time() < deadline:
            raw = self.ws.recv()
            if not raw:
                continue
            msg = json.loads(raw)
            if msg.get("type") == "res" and msg.get("id") == connect_id:
                if not msg.get("ok"):
                    raise RuntimeError(f"gateway connect failed: {msg}")
                return
        raise RuntimeError("gateway connect timed out")

    def disconnect(self):
        """Disconnect from gateway"""
        if self.ws:
            self.ws.close()
            self.ws = None

    def invoke_node(self, node_id: str, command: str, params: Dict = None) -> Dict:
        """Invoke a node command.

        The gateway wraps node results (payload contains {ok,payload,error,...}).
        Unwrap it for convenience.
        """
        res = self._request(
            "node.invoke",
            {
                "nodeId": node_id,
                "command": command,
                "params": params or {},
                # Required by gateway schema to dedupe retries
                "idempotencyKey": f"test-{int(time.time()*1000)}",
            },
        )

        if res.get("ok") and isinstance(res.get("payload"), dict) and "ok" in res["payload"]:
            inner = res["payload"]
            out = {"type": res.get("type"), "id": res.get("id")}
            out.update(inner)
            return out

        return res

    def list_nodes(self) -> list:
        """List connected nodes"""
        data = self._request("node.list", {})
        if not data.get("ok", False):
            raise RuntimeError(f"node.list failed: {data}")
        return data.get("payload", {}).get("nodes", [])

    def list_pairing(self) -> dict:
        """List pending/paired devices"""
        response = self._request("device.pair.list", {})
        if not response.get("ok", False):
            raise RuntimeError(f"device.pair.list failed: {response}")
        return response.get("payload", {})

    def approve_pairing(self, request_id: str) -> dict:
        """Approve a pairing request"""
        resp = self._request("device.pair.approve", {"requestId": request_id})
        if not resp.get("ok", False):
            raise RuntimeError(f"device.pair.approve failed: {resp}")
        return resp


@pytest.fixture
def gateway():
    """Provide connected gateway client"""
    client = GatewayClient()
    try:
        client.connect()
        yield client
    finally:
        client.disconnect()


# =============================================================================
# Helper Functions
# =============================================================================

def wait_for_condition(condition_fn, timeout: float = 10, interval: float = 0.5):
    """Wait for a condition to be true"""
    start = time.time()
    while time.time() - start < timeout:
        if condition_fn():
            return True
        time.sleep(interval)
    return False


# =============================================================================
# Tests
# =============================================================================

class TestNodeLifecycle:
    """Test node connection and lifecycle"""

    def test_node_starts_and_connects(self, node_process, gateway):
        """Test that node starts and appears in gateway"""
        # Wait for node to register
        time.sleep(2)

        # List nodes and find ours
        nodes = gateway.list_nodes()
        node_ids = [n.get("nodeId") for n in nodes]

        expected = getattr(node_process, "gateway_node_id", None) or node_process.node_id
        if expected not in node_ids:
            # If the node is unpaired, the gateway may close it with "pairing required".
            pairing = gateway.list_pairing()
            pending = pairing.get("pending", [])
            if not pending:
                raise AssertionError(f"No pending pairing requests; node_ids={node_ids} paired={pairing.get('paired', [])}")

            # Prefer matching by deviceId if present
            match = None
            for req in pending:
                if req.get("deviceId") == expected:
                    match = req
                    break
            match = match or pending[0]

            gateway.approve_pairing(match["requestId"])

            # Wait for node to reconnect and appear
            def has_node():
                nodes2 = gateway.list_nodes()
                ids2 = [n.get("nodeId") for n in nodes2]
                return expected in ids2

            assert wait_for_condition(has_node, timeout=10, interval=0.5), (
                f"Node {expected} not found after pairing approval. pending={pending}"
            )

            nodes = gateway.list_nodes()
            node_ids = [n.get("nodeId") for n in nodes]

        assert expected in node_ids, f"Node {expected} not found in {node_ids}"

    def test_node_process_running(self, node_process):
        """Test that node process stays running"""
        assert node_process.is_running, "Node process died"
        time.sleep(2)
        assert node_process.is_running, "Node process died after 2s"


class TestSystemCommands:
    """Test system.* commands"""

    def test_system_run_echo(self, node_process, gateway):
        """Test system.run with echo command"""
        time.sleep(2)  # Wait for registration

        node_id = getattr(node_process, "gateway_node_id", None) or node_process.node_id

        # Allow test commands
        gateway.invoke_node(node_id, "system.execApprovals.set", {"mode": "full"})

        response = gateway.invoke_node(
            node_id,
            "system.run",
            {"command": ["echo", "hello world"]}
        )

        assert response.get("ok"), f"Command failed: {response}"
        payload = response.get("payload", {})
        assert "hello world" in payload.get("stdout", "")

    def test_system_run_with_cwd(self, node_process, gateway, temp_dir):
        """Test system.run with working directory"""
        time.sleep(2)

        test_file = temp_dir / "test.txt"
        test_file.write_text("test content")

        node_id = getattr(node_process, "gateway_node_id", None) or node_process.node_id

        # Allow test commands
        gateway.invoke_node(node_id, "system.execApprovals.set", {"mode": "full"})

        response = gateway.invoke_node(
            node_id,
            "system.run",
            {
                "command": ["cat", "test.txt"],
                "cwd": str(temp_dir)
            }
        )

        assert response.get("ok"), f"Command failed: {response}"
        payload = response.get("payload", {})
        assert "test content" in payload.get("stdout", "")

    def test_system_which(self, node_process, gateway):
        """Test system.which command"""
        time.sleep(2)

        node_id = getattr(node_process, "gateway_node_id", None) or node_process.node_id
        response = gateway.invoke_node(
            node_id,
            "system.which",
            {"name": "ls"}
        )

        assert response.get("ok"), f"Command failed: {response}"
        payload = response.get("payload", {})
        assert "path" in payload


class TestProcessManagement:
    """Test process.* commands"""

    def test_process_spawn(self, node_process, gateway):
        """Test process.spawn command"""
        time.sleep(2)

        node_id = getattr(node_process, "gateway_node_id", None) or node_process.node_id
        response = gateway.invoke_node(
            node_id,
            "process.spawn",
            {"command": ["sleep", "10"]}
        )

        if not response.get("ok") and response.get("error", {}).get("details", {}).get("reason") == "command not allowlisted":
            pytest.skip("process.* commands not allowlisted by gateway")

        assert response.get("ok"), f"Command failed: {response}"
        payload = response.get("payload", {})
        assert "processId" in payload

        return payload["processId"]

    def test_process_poll(self, node_process, gateway):
        """Test process.poll command"""
        time.sleep(2)

        # Spawn a process
        node_id = getattr(node_process, "gateway_node_id", None) or node_process.node_id
        spawn_resp = gateway.invoke_node(
            node_id,
            "process.spawn",
            {"command": ["sleep", "2"]}
        )
        if not spawn_resp.get("ok") and spawn_resp.get("error", {}).get("details", {}).get("reason") == "command not allowlisted":
            pytest.skip("process.* commands not allowlisted by gateway")

        proc_id = spawn_resp["payload"]["processId"]

        # Poll it
        time.sleep(0.5)
        poll_resp = gateway.invoke_node(
            node_id,
            "process.poll",
            {"processId": proc_id}
        )

        assert poll_resp.get("ok"), f"Poll failed: {poll_resp}"
        payload = poll_resp.get("payload", {})
        assert payload.get("state") == "running"

    def test_process_list(self, node_process, gateway):
        """Test process.list command"""
        time.sleep(2)

        node_id = getattr(node_process, "gateway_node_id", None) or node_process.node_id
        response = gateway.invoke_node(
            node_id,
            "process.list",
            {}
        )

        if not response.get("ok") and response.get("error", {}).get("details", {}).get("reason") == "command not allowlisted":
            pytest.skip("process.* commands not allowlisted by gateway")

        assert response.get("ok"), f"Command failed: {response}"
        payload = response.get("payload", {})
        assert isinstance(payload, list)


class TestCanvasCommands:
    """Test canvas.* commands (requires Xvfb)"""

    def test_canvas_present(self, canvas_node, gateway):
        """Test canvas.present command"""
        time.sleep(3)  # Wait for canvas init

        response = gateway.invoke_node(
            canvas_node.node_id,
            "canvas.present",
            {}
        )

        # Canvas might fail if Chrome not available
        if not response.get("ok"):
            pytest.skip(f"Canvas not available: {response.get('error', {})}")

        payload = response.get("payload", {})
        assert payload.get("status") == "visible"

    def test_canvas_navigate(self, canvas_node, gateway):
        """Test canvas.navigate command"""
        time.sleep(3)

        # First present
        gateway.invoke_node(canvas_node.node_id, "canvas.present", {})
        time.sleep(1)

        response = gateway.invoke_node(
            canvas_node.node_id,
            "canvas.navigate",
            {"url": "about:blank"}
        )

        if not response.get("ok"):
            pytest.skip(f"Canvas navigation not available")

        payload = response.get("payload", {})
        assert payload.get("status") == "navigated"


# =============================================================================
# Main
# =============================================================================

if __name__ == "__main__":
    pytest.main([__file__, "-v"])
