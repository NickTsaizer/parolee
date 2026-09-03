#!/usr/bin/env python3
"""Integration test: compiler diagnostics publish on save, clear after fix."""

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


BAD_SOURCE = """\
main :: () {
    x := undefined_symbol_here;
}
"""

GOOD_SOURCE = """\
main :: () {
    x := 1;
}
"""

CONFIG = {
    "roots": ["main.jai"],
    "build_root": "main.jai",
    "auto_insert_parentheses": False,
}


def drain(session: Any) -> None:
    """Drop pending notifications so later polls see fresh diagnostics."""
    assert session.client is not None
    while True:
        try:
            session.client.read_message(timeout_s=0.5)
        except (TimeoutError, RuntimeError, EOFError):
            return


def wait_diagnostics(
    session: Any, uri: str, want_empty: bool, timeout_s: float = 20.0
) -> dict[str, Any]:
    """Poll until a publishDiagnostics notification matches the expectation."""
    assert session.client is not None
    deadline = time.time() + timeout_s
    while True:
        remaining = deadline - time.time()
        assert remaining > 0, "timed out waiting for diagnostics"
        msg = session.client.read_message(remaining)
        if msg.get("method") != "textDocument/publishDiagnostics":
            continue
        params = msg.get("params", {})
        if params.get("uri") != uri:
            continue
        diags = params.get("diagnostics", [])
        if (len(diags) == 0) == want_empty:
            return params


def main() -> int:
    args = test_args("diagnostics integration test")
    with tempfile.TemporaryDirectory(prefix="jails-diag-test-") as tmpdir:
        project = Path(tmpdir)
        write_project(project, {"main.jai": BAD_SOURCE}, CONFIG)
        with ServerSession(project, Path(args.jails_bin), args.jai_path) as session:
            session.open("main.jai", BAD_SOURCE, settle_s=1.0)
            drain(session)

            # Touch content so didSave takes the full diagnose path
            # (identical content is hash-skipped when the project is clean).
            session.notify(
                "textDocument/didChange",
                {
                    "textDocument": {"uri": session.uri("main.jai"), "version": 2},
                    "contentChanges": [
                        {
                            "range": {
                                "start": {"line": 2, "character": 0},
                                "end": {"line": 2, "character": 0},
                            },
                            "text": "// touch\n",
                        }
                    ],
                },
            )
            session.notify(
                "textDocument/didSave",
                {"textDocument": {"uri": session.uri("main.jai")}},
            )
            params = wait_diagnostics(session, session.uri("main.jai"), False)
            diags = params["diagnostics"]
            assert len(diags) > 0
            assert diags[0].get("message"), f"empty message: {diags[0]!r}"
            assert diags[0]["range"]["start"]["line"] == 1, (
                f"wrong error line: {diags[0]!r}"
            )
            print(f"PASS: error published ({diags[0]['message'].strip()[:60]!r})")

            # Fix the bad identifier, save again, diagnostics must clear.
            session.notify(
                "textDocument/didChange",
                {
                    "textDocument": {"uri": session.uri("main.jai"), "version": 3},
                    "contentChanges": [
                        {
                            "range": {
                                "start": {"line": 1, "character": 9},
                                "end": {"line": 1, "character": 30},
                            },
                            "text": "1",
                        }
                    ],
                },
            )
            session.notify(
                "textDocument/didSave",
                {"textDocument": {"uri": session.uri("main.jai")}},
            )
            wait_diagnostics(session, session.uri("main.jai"), True)
            print("PASS: diagnostics cleared after fix")

    print("\nAll diagnostics tests passed!")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
