#!/usr/bin/env python3
"""Integration test: `using` on `#import` re-exports symbols to importers.

Given a module "Core" that does `using MyMath :: #import "MyMath";`,
a file that does `#import "Core"` should see MyMath's exported symbols
(e.g. `normalize`, `Vector3`) in completions without qualification.
"""

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


# -- Module sources ----------------------------------------------------------

MYMATH_MODULE = """\
#scope_export

Vector3 :: struct {
    x: float;
    y: float;
    z: float;
}

normalize :: (v: Vector3) -> Vector3 {
    return v;
}

dot_product :: (a: Vector3, b: Vector3) -> float {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

#scope_module

internal_helper :: () {}
"""

CORE_MODULE = """\
using MyMath :: #import "MyMath";

Core_Info :: struct {
    name: string;
}
"""

MAIN_SOURCE = """\
#import "Core";

main :: () {
    norma
}
"""

# Completion cursor is at the end of "    norma" in MAIN_SOURCE.
# We expect to see `normalize` from MyMath (re-exported through Core).


# -- JSON-RPC client (copied from existing test) -----------------------------


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

    with tempfile.TemporaryDirectory(prefix="jails-reexport-test-") as tmpdir:
        project_dir = Path(tmpdir)

        # Create local module directories
        mymath_dir = project_dir / "modules" / "MyMath"
        mymath_dir.mkdir(parents=True)
        (mymath_dir / "module.jai").write_text(MYMATH_MODULE, encoding="utf-8")

        core_dir = project_dir / "modules" / "Core"
        core_dir.mkdir(parents=True)
        (core_dir / "module.jai").write_text(CORE_MODULE, encoding="utf-8")

        # Create main source
        source_path = project_dir / "main.jai"
        source_path.write_text(MAIN_SOURCE, encoding="utf-8")

        # Create jails.json
        (project_dir / "jails.json").write_text(
            json.dumps(
                {
                    "local_modules": ["modules"],
                    "roots": ["main.jai"],
                    "build_root": "main.jai",
                    "auto_insert_parentheses": False,
                    "use_symbols_from_local_modules": True,
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
                        "clientInfo": {"name": "reexport-test", "version": "1"},
                        "rootPath": None,
                        "rootUri": file_uri(project_dir),
                        "workspaceFolders": [
                            {
                                "uri": file_uri(project_dir),
                                "name": "reexport-test",
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

            # Give the server a moment to parse all files
            time.sleep(0.5)

            # ---- Test 1: Completion for re-exported symbol ----
            # Cursor at end of "    norma" (line 3, character 9)
            completion_line = 3
            completion_character = 9

            req_id = 2
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "method": "textDocument/completion",
                    "params": {
                        "textDocument": {"uri": file_uri(source_path)},
                        "position": {
                            "line": completion_line,
                            "character": completion_character,
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

            # 1a) `normalize` from MyMath should be visible (re-exported via using)
            if "normalize" in labels:
                print("PASS: 'normalize' from MyMath is visible through Core re-export")
            else:
                print(
                    f"FAIL: 'normalize' NOT found in completions.\n"
                    f"  Available labels: {labels}",
                    file=sys.stderr,
                )
                return 1

            # 1b) `Vector3` from MyMath should also be visible
            if "Vector3" in labels:
                print("PASS: 'Vector3' from MyMath is visible through Core re-export")
            else:
                print(
                    f"FAIL: 'Vector3' NOT found in completions.\n"
                    f"  Available labels: {labels}",
                    file=sys.stderr,
                )
                return 1

            # 1c) `dot_product` from MyMath should also be visible
            if "dot_product" in labels:
                print(
                    "PASS: 'dot_product' from MyMath is visible through Core re-export"
                )
            else:
                print(
                    f"FAIL: 'dot_product' NOT found in completions.\n"
                    f"  Available labels: {labels}",
                    file=sys.stderr,
                )
                return 1

            # 1d) `Core_Info` from Core itself should still be visible
            if "Core_Info" in labels:
                print("PASS: 'Core_Info' from Core is still visible")
            else:
                print(
                    f"FAIL: 'Core_Info' NOT found in completions.\n"
                    f"  Available labels: {labels}",
                    file=sys.stderr,
                )
                return 1

            # 1e) `internal_helper` from MyMath (#scope_module) should NOT be visible
            if "internal_helper" not in labels:
                print("PASS: 'internal_helper' (#scope_module) is correctly hidden")
            else:
                print(
                    "FAIL: 'internal_helper' (#scope_module) should NOT be visible "
                    "through re-export",
                    file=sys.stderr,
                )
                return 1

            # 1f) `MyMath` declaration itself should be visible (the named import)
            if "MyMath" in labels:
                print("PASS: 'MyMath' named import is visible as a declaration")
            else:
                # This is not critical for the re-export feature, just informational
                print(
                    "INFO: 'MyMath' named import not found in completions "
                    "(non-critical)"
                )

            # ---- Shutdown ----
            req_id = 3
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
