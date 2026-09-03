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
def _load_lsp_client():
    """Load sibling lsp_client.py by path (cwd-independent)."""
    import importlib.util

    path = Path(__file__).resolve().parent / "lsp_client.py"
    spec = importlib.util.spec_from_file_location("lsp_client", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_lsp_client = _load_lsp_client()
JsonRpcClient = _lsp_client.JsonRpcClient
detect_jai_root = _lsp_client.detect_jai_root
file_uri = _lsp_client.file_uri


TEST_SOURCE = """
// hello
// sailor

// hello
// world
hello_world :: () {}

some_code(); // hello
// moon
hello_moon :: () {}

hello :: 1;
world :: 2;

main :: () -> s64 {
    hello_
    return hworld;
}
"""


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

            completion_line = TEST_SOURCE.splitlines().index("    return hworld;")
            completion_character = len("    return h")

            req_id = 3
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

            hello_item = next(
                (item for item in items if item.get("label") == "hello"), None
            )
            if hello_item is None:
                labels = [item.get("label") for item in items]
                raise AssertionError(
                    "Completion inside h|world does not include label='hello'. "
                    f"Got labels: {labels!r}"
                )
            print("PASS: completion inside h|world uses prefix left of cursor")

            req_id = 4
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
