#!/usr/bin/env python3
"""Integration test: #import module completions and #load file completions."""

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
#import "";
#load "";
main :: () {}
"""

OTHER_SOURCE = """\
Other_Const :: 42;
"""

ALPHA_SOURCE = """\
Alpha_Foo :: 1;
"""

CONFIG = {
    "local_modules": ["modules"],
    "roots": ["main.jai"],
    "build_root": "main.jai",
    "auto_insert_parentheses": False,
}


def labels_of(resp: dict[str, Any]) -> list[str]:
    assert "error" not in resp, f"completion failed: {resp.get('error')}"
    result = resp.get("result")
    assert isinstance(result, list), f"expected list, got: {result!r}"
    return [item.get("label") for item in result]


def main() -> int:
    args = test_args("import/load completion integration test")
    with tempfile.TemporaryDirectory(prefix="jails-modcomplete-test-") as tmpdir:
        project = Path(tmpdir)
        write_project(
            project,
            {
                "main.jai": MAIN_SOURCE,
                "other.jai": OTHER_SOURCE,
                "modules/Alpha/module.jai": ALPHA_SOURCE,
            },
            CONFIG,
        )
        with ServerSession(project, Path(args.jails_bin), args.jai_path) as session:
            session.open("main.jai", MAIN_SOURCE, settle_s=1.0)

            # Inside #import "" (line 0, between quotes at char 9).
            resp = session.request(
                "textDocument/completion",
                {
                    "textDocument": {"uri": session.uri("main.jai")},
                    "position": {"line": 0, "character": 9},
                },
            )
            labels = labels_of(resp)
            assert "Alpha" in labels, f"local module missing: {labels[:20]}"
            print("PASS: local module in #import completions")

            # Inside #load "" (line 1, between quotes at char 8).
            resp = session.request(
                "textDocument/completion",
                {
                    "textDocument": {"uri": session.uri("main.jai")},
                    "position": {"line": 1, "character": 8},
                },
            )
            labels = labels_of(resp)
            assert "other.jai" in labels, f"sibling file missing: {labels}"
            print(f"PASS: sibling file in #load completions ({labels})")

    print("\nAll module completion tests passed!")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
