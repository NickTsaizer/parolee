#!/usr/bin/env python3
"""Integration test: document symbols and workspace symbols."""

from __future__ import annotations

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
ServerSession = _lsp_client.ServerSession
test_args = _lsp_client.test_args
write_project = _lsp_client.write_project


MAIN_SOURCE = """\
#scope_export

Vec :: struct {
    x: float;
}

Choice :: enum {
    A;
    B;
}

limit :: 100;

compute :: (v: Vec) -> float {
    return v.x;
}
"""

CONFIG = {
    "roots": ["main.jai"],
    "build_root": "main.jai",
    "auto_insert_parentheses": False,
}

# SymbolKind values mirrored from the server.
KIND_FUNCTION = 12
KIND_CONSTANT = 14
KIND_FIELD = 8
KIND_ENUM = 10
KIND_ENUM_MEMBER = 22
KIND_STRUCT = 23


def by_name(symbols: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {s["name"]: s for s in symbols}


def main() -> int:
    args = test_args("document/workspace symbol integration test")
    with tempfile.TemporaryDirectory(prefix="jails-symbols-test-") as tmpdir:
        project = Path(tmpdir)
        write_project(project, {"main.jai": MAIN_SOURCE}, CONFIG)
        with ServerSession(project, Path(args.jails_bin), args.jai_path) as session:
            session.open("main.jai", MAIN_SOURCE, settle_s=1.0)

            resp = session.request(
                "textDocument/documentSymbol",
                {"textDocument": {"uri": session.uri("main.jai")}},
            )
            assert "error" not in resp, f"documentSymbol failed: {resp.get('error')}"
            symbols = resp.get("result")
            assert isinstance(symbols, list), f"expected list, got: {symbols!r}"
            table = by_name(symbols)

            for name in ("Vec", "Choice", "limit", "compute"):
                assert name in table, f"{name} missing: {sorted(table)}"
            print("PASS: all top-level symbols present")

            assert table["Vec"]["kind"] == KIND_STRUCT, table["Vec"]
            assert table["Choice"]["kind"] == KIND_ENUM, table["Choice"]
            assert table["compute"]["kind"] == KIND_FUNCTION, table["compute"]
            assert table["limit"]["kind"] == KIND_CONSTANT, table["limit"]
            print("PASS: symbol kinds correct")

            vec_children = by_name(table["Vec"].get("children", []))
            assert "x" in vec_children, f"Vec field missing: {sorted(vec_children)}"
            assert vec_children["x"]["kind"] == KIND_FIELD, vec_children["x"]
            print("PASS: struct field child present")

            choice_children = by_name(table["Choice"].get("children", []))
            assert {"A", "B"} <= set(choice_children), (
                f"enum members missing: {sorted(choice_children)}"
            )
            assert choice_children["A"]["kind"] == KIND_ENUM_MEMBER
            print("PASS: enum member children present")

            resp = session.request("workspace/symbol", {"query": "vec"})
            assert "error" not in resp, f"workspace/symbol failed: {resp.get('error')}"
            found = resp.get("result")
            assert isinstance(found, list), f"expected list, got: {found!r}"
            names = [s["name"] for s in found]
            assert any("Vec" in n for n in names), f"Vec missing: {names}"
            print(f"PASS: workspace search finds Vec ({names})")

    print("\nAll symbol tests passed!")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
