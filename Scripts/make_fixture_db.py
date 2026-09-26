#!/usr/bin/env python3
"""Regenerate PumpStore's frozen schema-v1 fixture with a logical freeze guard."""
from __future__ import annotations

import argparse
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURE = REPO_ROOT / "Packages/PumpStore/Tests/PumpStoreTests/Fixtures/v1.sqlite"


def logical_dump(path: Path) -> str:
    connection = sqlite3.connect(path)
    try:
        return "\n".join(connection.iterdump())
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("scratch_dir", type=Path, help="directory containing the fixture-seed binary")
    parser.add_argument("--out", type=Path, default=FIXTURE)
    args = parser.parse_args()

    seed = next(args.scratch_dir.rglob("fixture-seed"), None)
    if seed is None:
        print(f"fixture-seed binary not found under {args.scratch_dir}", file=sys.stderr)
        return 1

    staging = Path(__file__).resolve().parent / f".fixture-{FIXTURE.name}"
    staging.unlink(missing_ok=True)
    subprocess.run([str(seed), str(staging)], check=True)

    if args.out.exists() and logical_dump(args.out) != logical_dump(staging):
        print("Generated fixture differs logically from the committed fixture; schema v1 is frozen", file=sys.stderr)
        staging.unlink(missing_ok=True)
        return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(staging, args.out)
    print(f"Wrote {args.out} ({args.out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
