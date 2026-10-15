#!/usr/bin/env python3
"""Cluster fuzz findings by (mode, breaker, cause) with a root-cause guess.

Usage: python3 scripts/fuzz_cluster.py [findings.jsonl] [--json out.json]

Rows are deduplicated per cluster by (mode, expected lowercased, punctuation stripped),
so "unique words" counts distinct intended tokens while "rows" counts occurrences.
"""
import argparse
import collections
import json
import string
import sys

PUNCT = string.punctuation + "«»—–…“”„’‘"


def norm(word):
    return word.strip(PUNCT + " ").lower()


def root_cause(row):
    typed, expected = row["typed"], row["expected"]
    breaker, cause = row["breaker"], row["cause"]
    core = norm(expected)
    letters = [c for c in core if c.isalpha()]
    if row["mode"] == "fp":
        if cause == "fp-title-case":
            return "fp: Title-case word read as Latin via exact tier"
        return "fp: " + cause
    if breaker == "double_typo":
        return "generator artefact: double_typo non-word expected"
    if breaker == "short_words":
        return "generator artefact: artificial short function-word density"
    if len(letters) < 3 or cause in ("short", "guillemets-short"):
        return "short-word guard (<3 letters, isEligible)"
    if "-" in expected or "'" in expected:
        return "hyphen/apostrophe token (isEligible/hyphenTier)"
    if typed.isupper() or (typed.upper() == typed and any(c.isalpha() for c in typed)):
        return "ALL-CAPS typed: exact tiers only (isEligible rejects non-lowercase)"
    if expected[:1].isupper() and expected[1:] == expected[1:].lower():
        return "Title-case expected: exact tiers only (titleCaseCandidate)"
    if "not-in-ru" in cause or "not-in-en" in cause:
        return "dictionary gap: expected word absent from layout list"
    if cause.startswith("collision"):
        return "collision: typed form is a real word in current layout"
    if any(c in expected for c in string.punctuation + "«»—"):
        return "punctuation-bearing token (punct not stripped before tiers)"
    return "other / unclassified"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("findings", nargs="?", default="build/fuzz/findings.jsonl")
    ap.add_argument("--json", help="also write cluster summary as JSON to this path")
    ap.add_argument("--markdown", help="also write a Markdown cluster table to this path")
    args = ap.parse_args()

    rows = []
    with open(args.findings, encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                rows.append(json.loads(line))

    clusters = collections.OrderedDict()
    for row in rows:
        key = (row["mode"], row["breaker"], row["cause"], root_cause(row))
        c = clusters.setdefault(key, {"rows": 0, "words": set(), "examples": []})
        c["rows"] += 1
        c["words"].add((row["mode"], norm(row["expected"])))
        if len(c["examples"]) < 5:
            c["examples"].append(row)

    summary = []
    for (mode, breaker, cause, root), c in clusters.items():
        summary.append({
            "mode": mode, "breaker": breaker, "cause": cause, "root_cause": root,
            "rows": c["rows"], "unique_words": len({w for _, w in c["words"]}),
            "examples": [
                {"typed": e["typed"], "expected": e["expected"], "got": e["got"], "context": e["context"]}
                for e in c["examples"]
            ],
        })
    summary.sort(key=lambda s: (-s["unique_words"], -s["rows"]))

    total_unique = len({(r["mode"], norm(r["expected"])) for r in rows})
    print(f"rows={len(rows)} unique_words={total_unique} clusters={len(summary)}")
    print(f"{'mode':<5} {'breaker':<18} {'cause':<22} {'uniq':>5} {'rows':>5}  root_cause")
    for s in summary:
        print(f"{s['mode']:<5} {s['breaker']:<18} {s['cause']:<22} {s['unique_words']:>5} {s['rows']:>5}  {s['root_cause']}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump({"rows": len(rows), "unique_words": total_unique, "clusters": summary},
                      fh, ensure_ascii=False, indent=2)
    if args.markdown:
        write_markdown(args.markdown, summary, rows, total_unique)
    return 0


def _md(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def write_markdown(path, summary, rows, total_unique):
    lines = [
        f"Total: {len(rows)} rows, {total_unique} unique words (mode, expected w/o punctuation), {len(summary)} clusters.",
        "",
        "| # | mode | breaker | cause | uniq words | rows | root-cause guess | examples (typed → expected [context]) |",
        "|--:|------|---------|-------|-----------:|-----:|------------------|---------------------------------------|",
    ]
    for i, s in enumerate(summary, 1):
        ex = "<br>".join(
            f"`{_md(e['typed'])}` → `{_md(e['expected'])}` ({_md(e['context'])})" for e in s["examples"]
        )
        lines.append(
            f"| {i} | {s['mode']} | {s['breaker']} | {s['cause']} | {s['unique_words']} | {s['rows']} | {_md(s['root_cause'])} | {ex} |"
        )
    fps = [r for r in rows if r["mode"] == "fp"]
    lines += ["", f"## All false positives ({len(fps)})", ""]
    if not fps:
        lines.append("None.")
    for r in fps:
        lines.append(
            f"- cell `{r['cell']}`, breaker `{r['breaker']}`, cause `{r['cause']}`, tier `{r['tier']}`: "
            f"typed `{r['typed']}` (expected `{r['expected']}`) got `{r['got']}`; context: {_md(r['context'])}"
        )
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")



if __name__ == "__main__":
    sys.exit(main())
