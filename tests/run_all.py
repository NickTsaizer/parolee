#!/usr/bin/env python3
"""Run the full Jails integration suite. Exit 0 when every test passes."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

TESTS = [
    "test_completion_documentation.py",
    "test_optimization_core.py",
    "test_struct_literal_completions.py",
    "test_using_import_reexport.py",
    "test_goto_definition.py",
    "test_signature_help.py",
    "test_symbols.py",
    "test_semantic_tokens.py",
    "test_completion_modules.py",
    "test_lifecycle.py",
    "test_diagnostics.py",
]

TIMEOUT_S = 180


def main() -> int:
    root = Path(__file__).resolve().parent
    passed, failed = [], []
    for name in TESTS:
        proc = subprocess.run(
            [sys.executable, str(root / name)],
            cwd=str(root.parent),
            capture_output=True,
            text=True,
            timeout=TIMEOUT_S,
        )
        if proc.returncode == 0:
            passed.append(name)
            print(f"PASS {name}")
        else:
            failed.append(name)
            print(f"FAIL {name}")
            print(proc.stdout[-2000:])
            print(proc.stderr[-2000:], file=sys.stderr)
    print(f"\n{len(passed)}/{len(TESTS)} passed")
    if failed:
        print("failed:", " ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
