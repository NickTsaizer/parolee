#!/usr/bin/env python3
"""Integration test: goto definition across identifier, dot, struct literal,
named argument, #load and #import targets."""

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
#load "other.jai";
Util :: #import "Util";

Vec :: struct {
    x: float;
    y: float;
}

make_vec :: (x: float, y: float) -> Vec {
    v: Vec;
    v.x = x;
    v.y = y;
    return v;
}

main :: () {
    v := make_vec(1.0, 2.0);
    w := v.x;
    u := make_vec(x=3.0, y=4.0);
}
"""

OTHER_SOURCE = """\
Other_Const :: 42;
"""

UTIL_SOURCE = """\
Util_Foo :: 1;
"""

CONFIG = {
    "local_modules": ["modules"],
    "roots": ["main.jai"],
    "build_root": "main.jai",
    "auto_insert_parentheses": False,
}


def target_of(result: Any) -> tuple[str, int]:
    """Normalize definition response (Location | Location[] | LocationLink)
    to (uri, start line)."""
    assert result is not None, "definition returned null"
    if isinstance(result, list):
        assert len(result) > 0, "definition returned empty list"
        result = result[0]
    assert isinstance(result, dict), f"unexpected definition shape: {result!r}"
    uri = result.get("targetUri", result.get("uri"))
    assert isinstance(uri, str), f"no uri in definition: {result!r}"
    if "targetSelectionRange" in result:
        line = result["targetSelectionRange"]["start"]["line"]
    else:
        line = result["range"]["start"]["line"]
    return uri, line


def check(session: Any, line: int, character: int, want_suffix: str, want_line: int) -> None:
    resp = session.request(
        "textDocument/definition",
        {
            "textDocument": {"uri": session.uri("main.jai")},
            "position": {"line": line, "character": character},
        },
    )
    assert "error" not in resp, f"definition failed: {resp.get('error')}"
    uri, got_line = target_of(resp.get("result"))
    assert uri.endswith(want_suffix), f"want *{want_suffix}, got {uri}"
    assert got_line == want_line, f"want line {want_line}, got {got_line}"


def main() -> int:
    args = test_args("goto definition integration test")
    with tempfile.TemporaryDirectory(prefix="jails-goto-test-") as tmpdir:
        project = Path(tmpdir)
        write_project(
            project,
            {
                "main.jai": MAIN_SOURCE,
                "other.jai": OTHER_SOURCE,
                "modules/Util/module.jai": UTIL_SOURCE,
            },
            CONFIG,
        )
        with ServerSession(project, Path(args.jails_bin), args.jai_path) as session:
            session.open("main.jai", MAIN_SOURCE, settle_s=1.0)

            # Procedure call -> procedure declaration (line 8).
            check(session, 16, 9, "main.jai", 8)
            print("PASS: goto procedure call")

            # Local variable through dot -> its declaration (line 16).
            check(session, 17, 9, "main.jai", 16)
            print("PASS: goto variable through dot")

            # Struct field through dot -> field declaration (line 4).
            check(session, 17, 11, "main.jai", 4)
            print("PASS: goto struct field")

            # Named argument -> procedure parameter (line 8).
            check(session, 18, 17, "main.jai", 8)
            print("PASS: goto named argument")

            # #load string -> loaded file.
            check(session, 0, 2, "other.jai", 0)
            print("PASS: goto #load target")

            # #import keyword -> module file.
            check(session, 1, 9, "modules/Util/module.jai", 0)
            print("PASS: goto #import target")

    print("\nAll goto tests passed!")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
