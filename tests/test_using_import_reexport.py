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

# Completion cursor is at the end of the `main :: () {` line in MAIN_SOURCE.
# Empty prefix there disables server-side prefix filtering, so every visible
# global is returned and all re-export asserts below are meaningful.
# (Requesting at the end of `norma` would prefix-filter everything except
# `normalize`.)


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
            # Cursor at end of `main :: () {` line (line 2, character 11).
            completion_line = 2
            completion_character = 11

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
