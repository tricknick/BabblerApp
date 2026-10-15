#!/usr/bin/env python3
"""Ledger of fuzz-probe cells (source x breaker) stored at build/fuzz/ledger.json."""

import argparse
import json
import os
import sys
import tempfile

LEDGER = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "build", "fuzz", "ledger.json"
)
LEDGER = os.path.normpath(LEDGER)


def load():
    if not os.path.exists(LEDGER):
        sys.exit(f"no ledger at {LEDGER}; run 'init' first")
    with open(LEDGER, encoding="utf-8") as f:
        return json.load(f)


def save(data):
    os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(LEDGER), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, LEDGER)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def split_list(value):
    return [v.strip() for v in value.split(",") if v.strip()]


def cmd_init(args):
    sources = split_list(args.sources)
    breakers = split_list(args.breakers)
    if not sources or not breakers:
        sys.exit("--sources and --breakers must each contain at least one name")
    data = load() if os.path.exists(LEDGER) else {"cells": {}}
    for s in sources:
        for b in breakers:
            name = f"{s}×{b}"
            data["cells"].setdefault(
                name,
                {
                    "source": s,
                    "breaker": b,
                    "status": "pending",
                    "sentences": 0,
                    "miss": 0,
                    "fp": 0,
                },
            )
    save(data)
    print(f"ledger has {len(data['cells'])} cells at {LEDGER}")


def cmd_next(_args):
    data = load()
    for name, cell in data["cells"].items():
        if cell["status"] == "pending":
            print(name)
            return
    sys.exit("no untried cells left")


def cmd_mark(args):
    data = load()
    if args.cell not in data["cells"]:
        sys.exit(f"unknown cell: {args.cell}")
    cell = data["cells"][args.cell]
    cell.update(
        status=args.status,
        sentences=args.sentences,
        miss=args.miss,
        fp=args.fp,
    )
    save(data)
    print(f"marked {args.cell} {args.status}")


def cmd_show(_args):
    data = load()
    rows = [("cell", "status", "sentences", "miss", "fp")]
    for name, c in data["cells"].items():
        rows.append((name, c["status"], str(c["sentences"]), str(c["miss"]), str(c["fp"])))
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    for r in rows:
        print("  ".join(v.ljust(w) for v, w in zip(r, widths)).rstrip())


def build_parser():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)

    pi = sub.add_parser("init", help="create or merge the source x breaker grid")
    pi.add_argument("--sources", required=True, help="comma-separated source names")
    pi.add_argument("--breakers", required=True, help="comma-separated breaker names")
    pi.set_defaults(func=cmd_init)

    pn = sub.add_parser("next", help="print the next untried cell")
    pn.set_defaults(func=cmd_next)

    pm = sub.add_parser("mark", help="record results for a cell")
    pm.add_argument("cell")
    pm.add_argument("--sentences", type=int, required=True)
    pm.add_argument("--miss", type=int, required=True)
    pm.add_argument("--fp", type=int, required=True)
    pm.add_argument("--status", choices=("done", "empty", "failed"), required=True)
    pm.set_defaults(func=cmd_mark)

    ps = sub.add_parser("show", help="print the ledger as a table")
    ps.set_defaults(func=cmd_show)
    return p


def main():
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
