#!/usr/bin/env python3
"""Integration test: open/change/save/close lifecycle keeps sync and server alive."""

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


OPEN_SOURCE = """\
main :: () {
}
"""

EDITED_SOURCE = """\
helper :: 1;
main :: () {

}
"""

CONFIG = {
    "roots": ["main.jai"],
    "build_root": "main.jai",
    "auto_insert_parentheses": False,
}


def main() -> int:
    args = test_args("lifecycle integration test")
    with tempfile.TemporaryDirectory(prefix="jails-lifecycle-test-") as tmpdir:
        project = Path(tmpdir)
        write_project(project, {"main.jai": OPEN_SOURCE}, CONFIG)
        with ServerSession(project, Path(args.jails_bin), args.jai_path) as session:
            session.open("main.jai", OPEN_SOURCE, settle_s=1.0)
            assert session.alive(), "server died after open"
            print("PASS: open keeps server alive")

            # Full-document edit inserts a new global; completions must see it.
            session.notify(
                "textDocument/didChange",
                {
                    "textDocument": {"uri": session.uri("main.jai"), "version": 2},
                    "contentChanges": [
                        {
                            "range": {
                                "start": {"line": 0, "character": 0},
                                "end": {"line": 2, "character": 0},
                            },
                            "text": EDITED_SOURCE,
                        }
                    ],
                },
            )
            resp = session.request(
                "textDocument/completion",
                {
                    "textDocument": {"uri": session.uri("main.jai")},
                    "position": {"line": 2, "character": 4},
                },
            )
            assert "error" not in resp, f"completion failed: {resp.get('error')}"
            labels = [i.get("label") for i in resp.get("result", [])]
            assert "helper" in labels, f"edit not reflected: {labels[:20]}"
            print("PASS: didChange content visible to completions")

            session.notify(
                "textDocument/didSave",
                {"textDocument": {"uri": session.uri("main.jai")}},
            )
            time.sleep(0.5)
            assert session.alive(), "server died after save"
            print("PASS: save keeps server alive")

            session.notify(
                "textDocument/didClose",
                {"textDocument": {"uri": session.uri("main.jai")}},
            )
            time.sleep(0.3)
            assert session.alive(), "server died after close"
            print("PASS: close keeps server alive")

    print("\nAll lifecycle tests passed!")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
