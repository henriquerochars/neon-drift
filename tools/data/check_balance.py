#!/usr/bin/env python3
"""Validate data/balance/*.csv: UTF-8, a header row, unique keys in the first column and
numeric values in every other column. Standard library only. Exit 0 pass, 1 problems."""

from __future__ import annotations

import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BALANCE = ROOT / "data" / "balance"


def check_file(path: Path) -> list[str]:
    problems: list[str] = []
    with path.open(encoding="utf-8", newline="") as handle:
        rows = list(csv.reader(handle))
    if not rows or len(rows[0]) < 2:
        return [f"{path.name}: needs a header with at least two columns"]
    header = rows[0]
    seen: set[str] = set()
    for number, row in enumerate(rows[1:], start=2):
        if not row or (len(row) == 1 and not row[0].strip()):
            continue
        if len(row) != len(header):
            problems.append(f"{path.name}:{number}: expected {len(header)} columns, got {len(row)}")
            continue
        key = row[0].strip()
        if not key or key in seen:
            problems.append(f"{path.name}:{number}: duplicate or empty key {key!r}")
        seen.add(key)
        for column, value in zip(header[1:], row[1:]):
            try:
                float(value)
            except ValueError:
                problems.append(f"{path.name}:{number}: column {column!r} is not numeric: {value!r}")
    return problems


def main() -> int:
    problems: list[str] = []
    for path in sorted(BALANCE.glob("*.csv")) if BALANCE.is_dir() else []:
        problems.extend(check_file(path))
    for problem in problems:
        print(f"balance: {problem}")
    if problems:
        return 1
    print("balance OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
