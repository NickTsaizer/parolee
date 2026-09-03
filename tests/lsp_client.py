#!/usr/bin/env python3
"""Shared harness for Jails LSP integration tests.

Canonical client + server lifecycle helpers. All tests in this directory
must use this module instead of copying JSON-RPC boilerplate.

Usage:
    from lsp_client import ServerSession, write_project, file_uri

    with ServerSession(project_dir, jai_path=...) as session:
        session.open("main.jai", MAIN_SOURCE)
        resp = session.request("textDocument/completion", {...})
"""

from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import sys
import time
from pathlib import Path
from types import TracebackType
from typing import Any


# -- JSON-RPC client -----------------------------------------------------------


class JsonRpcClient:
    """Length-prefixed JSON-RPC client over stdio pipes.

    Reads use select() so interleaved server->client notifications
    (window/logMessage) never wedge the reader.
    """

    def __init__(self, process: subprocess.Popen[bytes]) -> None:
        self.process = process
        self._next_id = 1

    def send(self, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        assert self.process.stdin is not None
        self.process.stdin.write(header + body)
        self.process.stdin.flush()

    def _read_exact(self, n: int, timeout_s: float) -> bytes:
        assert self.process.stdout is not None
        fd = self.process.stdout.fileno()
        data = bytearray()
        deadline = time.time() + timeout_s
        while len(data) < n:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError(f"Timed out waiting for {n} bytes")
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                continue
            chunk = os.read(fd, n - len(data))
            if not chunk:
                raise RuntimeError("LSP process closed stdout unexpectedly")
            data.extend(chunk)
        return bytes(data)

    def read_message(self, timeout_s: float = 10.0) -> dict[str, Any]:
        header_bytes = bytearray()
        while b"\r\n\r\n" not in header_bytes:
            header_bytes.extend(self._read_exact(1, timeout_s))

        header_blob, _, _ = bytes(header_bytes).partition(b"\r\n\r\n")
        content_length = None
        for line in header_blob.decode("ascii").split("\r\n"):
            if not line:
                continue
            key, _, value = line.partition(":")
            if key.lower() == "content-length":
                content_length = int(value.strip())
                break

        if content_length is None:
            raise RuntimeError(f"No Content-Length in header: {header_blob!r}")

        body = self._read_exact(content_length, timeout_s)
        return json.loads(body.decode("utf-8"))

    def wait_for_response(
        self, request_id: int, timeout_s: float = 10.0
    ) -> dict[str, Any]:
        deadline = time.time() + timeout_s
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise TimeoutError(f"Timed out waiting for response id={request_id}")
            message = self.read_message(remaining)
            if message.get("id") == request_id:
                return message

    def request(
        self, method: str, params: dict[str, Any] | None = None, timeout_s: float = 10.0
    ) -> dict[str, Any]:
        """Send a request with auto id, skip interleaved notifications."""
        rid = self._next_id
        self._next_id += 1
        msg: dict[str, Any] = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        self.send(msg)
        return self.wait_for_response(rid, timeout_s)

    def notify(self, method: str, params: dict[str, Any]) -> None:
        self.send({"jsonrpc": "2.0", "method": method, "params": params})


# -- Helpers -------------------------------------------------------------------


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def find_jails_binary() -> Path:
    binary = repo_root() / "bin" / "jails"
    if not binary.exists():
        binary = repo_root() / "bin" / "jails.exe"
    if not binary.exists():
        raise FileNotFoundError(f"Jails binary not found at {binary}")
    return binary


def detect_jai_root() -> str | None:
    for exe_name in ("jai-linux", "jai", "jai-macos", "jai.exe"):
        path = shutil.which(exe_name)
        if not path:
            continue
        resolved = Path(path).resolve()
        if resolved.parent.name == "bin":
            return str(resolved.parent.parent)
    return None


def file_uri(path: Path) -> str:
    return path.resolve().as_uri()


def test_args(description: str):
    """Standard --jails-bin/--jai-path CLI for test scripts."""
    import argparse

    ap = argparse.ArgumentParser(description=description)
    ap.add_argument(
        "--jails-bin",
        default=str(repo_root() / "bin" / "jails"),
        help="Path to jails executable",
    )
    ap.add_argument(
        "--jai-path",
        default=detect_jai_root(),
        help="Path to Jai root (contains bin/)",
    )
    return ap.parse_args()


def write_project(
    project_dir: Path, files: dict[str, str], config: dict[str, Any] | None = None
) -> None:
    for rel, text in files.items():
        target = project_dir / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    if config is not None:
        (project_dir / "jails.json").write_text(json.dumps(config), encoding="utf-8")


# -- Server session ------------------------------------------------------------


class ServerSession:
    """Spawned jails server bound to a project dir. Use as context manager.

    On enter: spawn + initialize + initialized. On exit: shutdown + wait,
    dump stderr when the server dies loudly.
    """

    def __init__(
        self,
        project_dir: Path,
        jails_bin: Path | None = None,
        jai_path: str | None = None,
    ) -> None:
        self.project_dir = project_dir
        self.jails_bin = jails_bin or find_jails_binary()
        self.jai_path = jai_path
        self.process: subprocess.Popen[bytes] | None = None
        self.client: JsonRpcClient | None = None

    def __enter__(self) -> "ServerSession":
        if not self.jails_bin.exists():
            raise FileNotFoundError(f"Missing jails binary: {self.jails_bin}")
        args = [str(self.jails_bin)]
        if self.jai_path:
            args += ["-jai_path", self.jai_path]
        self.process = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(self.project_dir),
        )
        self.client = JsonRpcClient(self.process)
        assert self.client is not None
        resp = self.client.request(
            "initialize",
            {
                "clientInfo": {"name": "jails-test", "version": "1"},
                "rootPath": None,
                "rootUri": file_uri(self.project_dir),
                "workspaceFolders": [
                    {"uri": file_uri(self.project_dir), "name": "jails-test"}
                ],
                "capabilities": {},
            },
        )
        if "error" in resp:
            raise RuntimeError(f"Initialize failed: {resp['error']}")
        self.client.notify("initialized", {})
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        assert self.process is not None and self.client is not None
        try:
            if self.process.poll() is None:
                self.client.request("shutdown", {})
                self.process.wait(timeout=5)
        finally:
            if self.process.poll() is None:
                self.process.kill()
            stderr_output = ""
            if self.process.stderr:
                try:
                    stderr_output = self.process.stderr.read().decode(
                        "utf-8", errors="replace"
                    )
                except Exception:
                    pass
            if stderr_output.strip():
                print(
                    "--- LSP server stderr ---",
                    stderr_output,
                    "--- end stderr ---",
                    sep="\n",
                    file=sys.stderr,
                )

    def open(self, rel: str, text: str, settle_s: float = 0.5) -> None:
        assert self.client is not None
        self.client.notify(
            "textDocument/didOpen",
            {
                "textDocument": {
                    "uri": file_uri(self.project_dir / rel),
                    "languageId": "jai",
                    "version": 1,
                    "text": text,
                }
            },
        )
        time.sleep(settle_s)

    def request(
        self, method: str, params: dict[str, Any] | None = None, timeout_s: float = 10.0
    ) -> dict[str, Any]:
        assert self.client is not None
        return self.client.request(method, params, timeout_s)

    def notify(self, method: str, params: dict[str, Any]) -> None:
        assert self.client is not None
        self.client.notify(method, params)

    def uri(self, rel: str) -> str:
        return file_uri(self.project_dir / rel)

    def alive(self) -> bool:
        return self.process is not None and self.process.poll() is None
