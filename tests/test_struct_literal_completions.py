#!/usr/bin/env python3
"""Integration test: struct literal member completions — explicit type and dotless inference."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any


MAIN_SOURCE = """\
Vector3 :: struct {
    x: float;
    y: float;
    z: float;
}

main :: () {
    // Test 1: explicit type struct literal (Vector3.{ ... })
    v := Vector3.{
        x = 1.0,
        
    }

    // Test 2: dotless struct literal with type inference (e: My_Struct = .{ ... })
    w: Vector3 = .{
        
    };
}
"""

# Cursor for test 1: empty line inside Vector3.{ ... } between x = 1.0 and }
CURSOR1_LINE = 9
CURSOR1_CHAR = 8

# Cursor for test 2: empty line inside dotless .{ ... }
CURSOR2_LINE = 15
CURSOR2_CHAR = 8


# -- JSON-RPC client ----------------------------------------------------------


class JsonRpcClient:
    def __init__(self, process: subprocess.Popen[bytes]) -> None:
        self.process = process

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


# -- Helpers ------------------------------------------------------------------


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


# -- Test body ----------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--jails-bin",
        default=str(Path(__file__).resolve().parents[1] / "bin" / "jails"),
        help="Path to jails executable",
    )
    parser.add_argument(
        "--jai-path",
        default=detect_jai_root(),
        help="Path to Jai root (contains bin/)",
    )
    args = parser.parse_args()

    jails_bin = Path(args.jails_bin).resolve()
    if not jails_bin.exists():
        print(f"Missing jails binary: {jails_bin}", file=sys.stderr)
        return 1

    if not args.jai_path:
        print(
            "Unable to detect Jai path. Pass --jai-path /path/to/jai", file=sys.stderr
        )
        return 1

    with tempfile.TemporaryDirectory(prefix="jails-struct-literal-test-") as tmpdir:
        project_dir = Path(tmpdir)

        source_path = project_dir / "main.jai"
        source_path.write_text(MAIN_SOURCE, encoding="utf-8")

        (project_dir / "jails.json").write_text(
            json.dumps(
                {
                    "roots": ["main.jai"],
                    "build_root": "main.jai",
                    "auto_insert_parentheses": False,
                }
            ),
            encoding="utf-8",
        )

        process = subprocess.Popen(
            [str(jails_bin), "-jai_path", args.jai_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(project_dir),
        )
        client = JsonRpcClient(process)

        try:
            # ---- Initialize ----
            req_id = 1
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "method": "initialize",
                    "params": {
                        "clientInfo": {"name": "struct-literal-test", "version": "1"},
                        "rootPath": None,
                        "rootUri": file_uri(project_dir),
                        "workspaceFolders": [
                            {
                                "uri": file_uri(project_dir),
                                "name": "struct-literal-test",
                            }
                        ],
                    },
                }
            )
            init_response = client.wait_for_response(req_id)
            if "error" in init_response:
                raise RuntimeError(f"Initialize failed: {init_response['error']}")

            client.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

            # ---- Open main.jai ----
            client.send(
                {
                    "jsonrpc": "2.0",
                    "method": "textDocument/didOpen",
                    "params": {
                        "textDocument": {
                            "uri": file_uri(source_path),
                            "languageId": "jai",
                            "version": 1,
                            "text": MAIN_SOURCE,
                        }
                    },
                }
            )

            # Give the server a moment to parse
            time.sleep(0.5)

            # ---- Test 1: explicit type struct literal (Vector3.{ ... }) ----
            req_id = 2
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "method": "textDocument/completion",
                    "params": {
                        "textDocument": {"uri": file_uri(source_path)},
                        "position": {
                            "line": CURSOR1_LINE,
                            "character": CURSOR1_CHAR,
                        },
                    },
                }
            )

            completion_response = client.wait_for_response(req_id, timeout_s=15)
            if "error" in completion_response:
                raise RuntimeError(f"Completion failed: {completion_response['error']}")

            items = completion_response.get("result")
            if not isinstance(items, list):
                raise AssertionError(f"Expected completion list, got: {items!r}")

            labels = [item.get("label") for item in items]

            # 1a) `y` should be suggested (unassigned struct field)
            if "y" in labels:
                print("PASS [explicit]: 'y' suggested as unassigned struct field")
            else:
                print(
                    f"FAIL [explicit]: 'y' NOT found in struct literal completions.\n"
                    f"  Available labels: {labels}",
                    file=sys.stderr,
                )
                return 1

            # 1b) `z` should be suggested (unassigned struct field)
            if "z" in labels:
                print("PASS [explicit]: 'z' suggested as unassigned struct field")
            else:
                print(
                    f"FAIL [explicit]: 'z' NOT found in struct literal completions.\n"
                    f"  Available labels: {labels}",
                    file=sys.stderr,
                )
                return 1

            # 1c) `x` should NOT be suggested (already assigned)
            if "x" not in labels:
                print("PASS [explicit]: 'x' correctly excluded (already assigned)")
            else:
                print(
                    f"FAIL [explicit]: 'x' should NOT be suggested since it was "
                    f"already assigned in the struct literal.",
                    file=sys.stderr,
                )
                return 1

            # ---- Test 2: dotless struct literal (e: My_Struct = .{ ... }) ----
            req_id = 3
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "method": "textDocument/completion",
                    "params": {
                        "textDocument": {"uri": file_uri(source_path)},
                        "position": {
                            "line": CURSOR2_LINE,
                            "character": CURSOR2_CHAR,
                        },
                    },
                }
            )

            completion_response2 = client.wait_for_response(req_id, timeout_s=15)
            if "error" in completion_response2:
                raise RuntimeError(
                    f"Dotless completion failed: {completion_response2['error']}"
                )

            items2 = completion_response2.get("result")
            if not isinstance(items2, list):
                raise AssertionError(f"Expected completion list, got: {items2!r}")

            labels2 = [item.get("label") for item in items2]

            # 2a) All 3 fields should be suggested (none assigned yet)
            for field in ("x", "y", "z"):
                if field in labels2:
                    print(f"PASS [dotless]: '{field}' suggested from inferred type")
                else:
                    print(
                        f"FAIL [dotless]: '{field}' NOT found in dotless struct literal "
                        f"completions.\n  Available labels: {labels2}",
                        file=sys.stderr,
                    )
                    return 1

            # ---- Shutdown ----
            req_id = 4
            client.send(
                {"jsonrpc": "2.0", "id": req_id, "method": "shutdown", "params": {}}
            )
            client.wait_for_response(req_id)
            process.wait(timeout=5)

            print("\nAll tests passed!")
            return 0

        finally:
            if process.poll() is None:
                process.kill()
            stderr_output = (
                process.stderr.read().decode("utf-8", errors="replace")
                if process.stderr
                else ""
            )
            if stderr_output.strip():
                print(
                    "--- LSP server stderr ---",
                    stderr_output,
                    "--- end stderr ---",
                    sep="\n",
                    file=sys.stderr,
                )


if __name__ == "__main__":
    raise SystemExit(main())
