#!/usr/bin/env python3
"""Integration test: semantic token content, delta validity, range clipping."""

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
main :: () {
    v := 42;
    s := "hi";
    // note
    return v;
}
"""

CONFIG = {
    "roots": ["main.jai"],
    "build_root": "main.jai",
    "auto_insert_parentheses": False,
}

# Token type indices mirrored from the server legend.
TYPE_FUNCTION = 11
TYPE_KEYWORD = 14
TYPE_COMMENT = 16
TYPE_STRING = 17
TYPE_NUMBER = 18
TYPE_COUNT = 21


def decode(data: list[int]) -> list[tuple[int, int, int, int, int]]:
    """Decode LSP delta encoding to (line, char, length, type, modifiers)."""
    assert len(data) % 5 == 0, f"data length not multiple of 5: {len(data)}"
    out: list[tuple[int, int, int, int, int]] = []
    line, char = 0, 0
    for i in range(0, len(data), 5):
        dline, dchar, length, ttype, mod = data[i : i + 5]
        if dline == 0:
            char += dchar
        else:
            line += dline
            char = dchar
        out.append((line, char, length, ttype, mod))
    return out


def main() -> int:
    args = test_args("semantic tokens integration test")
    with tempfile.TemporaryDirectory(prefix="jails-semtok-test-") as tmpdir:
        project = Path(tmpdir)
        write_project(project, {"main.jai": MAIN_SOURCE}, CONFIG)
        with ServerSession(project, Path(args.jails_bin), args.jai_path) as session:
            session.open("main.jai", MAIN_SOURCE, settle_s=1.0)

            resp = session.request(
                "textDocument/semanticTokens/full",
                {"textDocument": {"uri": session.uri("main.jai")}},
            )
            assert "error" not in resp, f"semtok full failed: {resp.get('error')}"
            data = resp.get("result", {}).get("data", [])
            assert isinstance(data, list) and len(data) > 0, "no tokens returned"
            tokens = decode(data)

            # Delta order: lines non-decreasing, spans sane, types in legend.
            for (line, char, length, ttype, _), nxt in zip(tokens, tokens[1:]):
                assert nxt[0] >= line, f"lines go backwards: {tokens}"
                assert length > 0, f"empty token: {(line, char, length, ttype)}"
                assert 0 <= ttype < TYPE_COUNT, f"type out of legend: {ttype}"
            print(f"PASS: {len(tokens)} tokens, delta encoding valid")

            kinds = {t[3] for t in tokens}
            for want, name in (
                (TYPE_FUNCTION, "function"),
                (TYPE_KEYWORD, "keyword"),
                (TYPE_COMMENT, "comment"),
                (TYPE_STRING, "string"),
                (TYPE_NUMBER, "number"),
            ):
                assert want in kinds, f"no {name} token in {sorted(kinds)}"
            print("PASS: function/keyword/comment/string/number all classified")

            # String token sits on the "hi" line (line 2).
            strings = [t for t in tokens if t[3] == TYPE_STRING]
            assert any(t[0] == 2 for t in strings), f"string not on line 2: {strings}"
            print("PASS: string token on expected line")

            # Range request over lines 2-3 clips everything outside.
            resp = session.request(
                "textDocument/semanticTokens/range",
                {
                    "textDocument": {"uri": session.uri("main.jai")},
                    "range": {
                        "start": {"line": 2, "character": 0},
                        "end": {"line": 4, "character": 0},
                    },
                },
            )
            assert "error" not in resp, f"semtok range failed: {resp.get('error')}"
            rdata = resp.get("result", {}).get("data", [])
            rtokens = decode(rdata)
            assert len(rtokens) > 0, "range returned no tokens"
            assert all(2 <= t[0] < 4 for t in rtokens), (
                f"range leak: {rtokens}"
            )
            print(f"PASS: range clips to bounds ({len(rtokens)} tokens)")

    print("\nAll semantic token tests passed!")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
