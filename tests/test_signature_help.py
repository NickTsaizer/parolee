#!/usr/bin/env python3
"""Integration test: signature help inside procedure calls."""

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
add :: (a: float, b: float) -> float {
    return a + b;
}

main :: () {
    x := add(1.0, 2.0);
}
"""

CONFIG = {
    "roots": ["main.jai"],
    "build_root": "main.jai",
    "auto_insert_parentheses": False,
}


def main() -> int:
    args = test_args("signature help integration test")
    with tempfile.TemporaryDirectory(prefix="jails-sighelp-test-") as tmpdir:
        project = Path(tmpdir)
        write_project(project, {"main.jai": MAIN_SOURCE}, CONFIG)
        with ServerSession(project, Path(args.jails_bin), args.jai_path) as session:
            session.open("main.jai", MAIN_SOURCE, settle_s=1.0)

            # Cursor after "add(1.0, " (line 5, character 18).
            resp = session.request(
                "textDocument/signatureHelp",
                {
                    "textDocument": {"uri": session.uri("main.jai")},
                    "position": {"line": 5, "character": 18},
                },
            )
            assert "error" not in resp, f"signatureHelp failed: {resp.get('error')}"
            result = resp.get("result")
            assert isinstance(result, dict), f"expected help object, got: {result!r}"

            signatures = result.get("signatures")
            assert isinstance(signatures, list) and len(signatures) > 0, (
                f"expected signatures, got: {result!r}"
            )
            print(f"PASS: signatures returned ({len(signatures)})")

            label = signatures[0].get("label", "")
            assert "add" in label, f"signature label missing proc name: {label!r}"
            print(f"PASS: signature label names procedure ({label!r})")

            params = signatures[0].get("parameters")
            assert isinstance(params, list) and len(params) == 2, (
                f"expected 2 parameters, got: {params!r}"
            )
            print("PASS: both parameters present")

            assert isinstance(result.get("activeSignature"), int), (
                f"missing activeSignature: {result!r}"
            )
            print("PASS: activeSignature present")

    print("\nAll signature help tests passed!")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
