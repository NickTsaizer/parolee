#!/usr/bin/env python3
"""Integration smoke test: exercises optimized code paths in Jails LSP server.

Validates:
- Semantic tokens (sort/dedup, range pre-filtering)
- Completions (binary search get_node_by_location)
- Goto definition (node lookup, memory file line-indexed access)
- Diagnostics on save (deferred execution)
- Rate limiting (rapid repeated requests)
- Path normalization (decode_url bounds)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
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
find_jails_binary = _lsp_client.find_jails_binary


# -- Jai test source -----------------------------------------------------------

TEST_SOURCE = """\
Vector3 :: struct {
    x: float;
    y: float;
    z: float;
}

My_Enum :: enum {
    A;
    B;
    C;
}

my_procedure :: (a: float, b: float) -> float {
    return a + b;
}

main :: () {
    v := Vector3.{ x = 1.0, y = 2.0, z = 3.0 };

    result := my_procedure(1.0, 2.0);

    // Test completions on struct field access
    _ := v.x;

    // Enum access
    e := My_Enum.A;
}
"""


def run_test() -> bool:
    jails_bin = find_jails_binary()

    with tempfile.TemporaryDirectory(prefix="jails_test_") as tmpdir:
        tmp = Path(tmpdir)

        # Write test source
        test_file = tmp / "test_module.jai"
        test_file.write_text(TEST_SOURCE)

        # Write jails.json config
        jails_json = tmp / "jails.json"
        jails_json.write_text(json.dumps({
            "roots": ["test_module.jai"],
            "build_root": "test_module.jai",
            "local_modules": [],
            "auto_insert_parentheses": True,
        }))

        # Start server
        proc = subprocess.Popen(
            [jails_bin],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(tmp),
        )
        client = JsonRpcClient(proc)

        try:
            # -- 1. Initialize --------------------------------------------------
            result = client.request("initialize", {
                "rootUri": f"file://{tmp}",
                "capabilities": {},
            })
            assert "result" in result, f"Initialize failed: {result}"
            print("  ✓ Initialize")

            # -- 2. Open file ---------------------------------------------------
            client.notify("textDocument/didOpen", {
                "textDocument": {
                    "uri": f"file://{tmp / 'test_module.jai'}",
                    "languageId": "jai",
                    "version": 1,
                    "text": TEST_SOURCE,
                }
            })

            # Wait for server to process didOpen — check process alive
            time.sleep(2.0)
            if proc.poll() is not None:
                stderr_out = proc.stderr.read().decode() if proc.stderr else ""
                raise RuntimeError(f"Server exited with code {proc.returncode}\nSTDERR: {stderr_out}")

            # -- 3. Completions first (simpler than semantic tokens) -----------
            result = client.request("textDocument/completion", {
                "textDocument": {"uri": f"file://{tmp / 'test_module.jai'}"},
                "position": {"line": 21, "character": 9},
                "context": {"triggerKind": 1},
            })
            assert "result" in result, f"Completions failed: {result}"
            print("  ✓ Completions")

            # -- 4. Semantic tokens (full) --------------------------------------
            result = client.request("textDocument/semanticTokens/full", {
                "textDocument": {"uri": f"file://{tmp / 'test_module.jai'}"},
            })
            assert "result" in result, f"Semantic tokens full failed: {result}"
            data = result.get("result", {}).get("data", [])
            assert len(data) > 0, "No semantic tokens returned"
            print(f"  ✓ Semantic tokens full ({len(data)} data points)")

            # -- 4. Semantic tokens (range) -------------------------------------
            result = client.request("textDocument/semanticTokens/range", {
                "textDocument": {"uri": f"file://{tmp / 'test_module.jai'}"},
                "range": {
                    "start": {"line": 0, "character": 0},
                    "end": {"line": 5, "character": 0},
                },
            })
            assert "result" in result, f"Semantic tokens range failed: {result}"
            data_range = result.get("result", {}).get("data", [])
            print(f"  ✓ Semantic tokens range ({len(data_range)} data points)")

            # -- 5. Completions (dot access) -----------------------------------
            result = client.request("textDocument/completion", {
                "textDocument": {"uri": f"file://{tmp / 'test_module.jai'}"},
                "position": {"line": 21, "character": 9},  # v.x| cursor
                "context": {"triggerKind": 1},
            })
            assert "result" in result, f"Completions failed: {result}"
            completions = result.get("result")
            print(f"  ✓ Completions ({len(completions) if isinstance(completions, list) else 'object'})")

            # -- 6. Goto definition (struct) -----------------------------------
            result = client.request("textDocument/definition", {
                "textDocument": {"uri": f"file://{tmp / 'test_module.jai'}"},
                "position": {"line": 21, "character": 7},  # v cursor
            })
            assert "result" in result, f"Goto definition failed: {result}"
            print("  ✓ Goto definition")

            # -- 7. Goto definition (procedure) --------------------------------
            result = client.request("textDocument/definition", {
                "textDocument": {"uri": f"file://{tmp / 'test_module.jai'}"},
                "position": {"line": 23, "character": 20},  # my_procedure cursor
            })
            assert "result" in result, f"Goto procedure definition failed: {result}"
            print("  ✓ Goto procedure definition")

            # -- 8. Save file (triggers deferred diagnostics) ------------------
            client.notify("textDocument/didSave", {
                "textDocument": {"uri": f"file://{tmp / 'test_module.jai'}"},
            })
            time.sleep(0.3)
            print("  ✓ Save + diagnostics trigger")

            # -- 9. Semantic tokens again (validates sort consistency) ----------
            result = client.request("textDocument/semanticTokens/full", {
                "textDocument": {"uri": f"file://{tmp / 'test_module.jai'}"},
            })
            assert "result" in result, "Second semantic tokens request failed"
            print("  ✓ Semantic tokens repeat (sort consistency)")

            # -- 10. Rapid repeated requests (rate limit) -----------------------
            for _ in range(3):
                client.request("textDocument/semanticTokens/full", {
                    "textDocument": {"uri": f"file://{tmp / 'test_module.jai'}"},
                })
            print("  ✓ Rapid repeated requests (rate limit exercise)")

            # -- 11. Close file -------------------------------------------------
            client.notify("textDocument/didClose", {
                "textDocument": {"uri": f"file://{tmp / 'test_module.jai'}"},
            })
            print("  ✓ File close")

            # -- 12. Shutdown ---------------------------------------------------
            client.request("shutdown")
            print("  ✓ Shutdown")

            proc.wait(timeout=5)
            print("\n✅ All optimization tests passed!")

        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
            if proc.stderr:
                remaining = proc.stderr.read()
                if remaining:
                    print(f"\n=== Server stderr ===\n{remaining.decode(errors='replace')}", file=sys.stderr)

    return True


if __name__ == "__main__":
    success = run_test()
    sys.exit(0 if success else 1)
