#!/usr/bin/env python3
"""Integration test: declaration comments are exposed as completion documentation."""

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


TEST_SOURCE = """
// hello
// sailor

// hello
// world
hello_world :: () {}

some_code(); // hello
// moon
hello_moon :: () {}

main :: () {
    hello_
}
"""


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

    with tempfile.TemporaryDirectory(prefix="jails-docs-test-") as tmpdir:
        project_dir = Path(tmpdir)
        source_path = project_dir / "main.jai"
        source_path.write_text(TEST_SOURCE, encoding="utf-8")

        (project_dir / "jails.json").write_text(
            json.dumps(
                {
                    "local_modules": [],
                    "roots": ["main.jai"],
                    "build_root": "main.jai",
                    "intermediate_path": "tmp/",
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
        )
        client = JsonRpcClient(process)

        try:
            req_id = 1
            client.send(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "method": "initialize",
                    "params": {
                        "clientInfo": {"name": "docs-test", "version": "1"},
                        "rootPath": None,
                        "rootUri": file_uri(project_dir),
                        "workspaceFolders": [
                            {"uri": file_uri(project_dir), "name": "docs-test"}
                        ],
                    },
                }
            )
            init_response = client.wait_for_response(req_id)
            if "error" in init_response:
                raise RuntimeError(f"Initialize failed: {init_response['error']}")

            client.send({"jsonrpc": "2.0", "method": "initialized", "params": {}})

            client.send(
                {
                    "jsonrpc": "2.0",
                    "method": "textDocument/didOpen",
                    "params": {
                        "textDocument": {
                            "uri": file_uri(source_path),
                            "languageID": "jai",
                            "version": 1,
                            "text": TEST_SOURCE,
                        }
                    },
                }
            )

            completion_line = TEST_SOURCE.splitlines().index("    hello_")
            completion_character = len("    hello_")

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

            completion_response = client.wait_for_response(req_id)
            if "error" in completion_response:
                raise RuntimeError(f"Completion failed: {completion_response['error']}")

            items = completion_response.get("result")
            if not isinstance(items, list):
                raise AssertionError(f"Expected completion list, got: {items!r}")

            # Test hello_world: should only have its contiguous comment block,
            # NOT the "hello/sailor" comments separated by a blank line above.
            world_item = next(
                (item for item in items if item.get("label") == "hello_world"), None
            )
            if world_item is None:
                raise AssertionError(
                    "Completion result does not include label='hello_world'"
                )

            world_docs = world_item.get("documentation", "")
            world_expected = "hello\nworld"
            if world_docs != world_expected:
                raise AssertionError(
                    f"hello_world: unexpected documentation.\n"
                    f"Expected: {world_expected!r}\nGot: {world_docs!r}"
                )
            print("PASS: hello_world docs contain only its own comment block")

            # Test hello_moon: inline comment on previous line should not be included.
            # "some_code(); // hello" is a trailing comment, not a doc comment.
            moon_item = next(
                (item for item in items if item.get("label") == "hello_moon"), None
            )
            if moon_item is None:
                raise AssertionError(
                    "Completion result does not include label='hello_moon'"
                )

            moon_docs = moon_item.get("documentation", "")
            moon_expected = "moon"
            if moon_docs != moon_expected:
                raise AssertionError(
                    f"hello_moon: unexpected documentation.\n"
                    f"Expected: {moon_expected!r}\nGot: {moon_docs!r}"
                )
            print("PASS: hello_moon docs exclude inline comment from previous line")

            req_id = 3
            client.send(
                {"jsonrpc": "2.0", "id": req_id, "method": "shutdown", "params": {}}
            )
            client.wait_for_response(req_id)
            process.wait(timeout=5)
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
                print(stderr_output, file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
