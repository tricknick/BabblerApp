#!/usr/bin/env python3
"""Writes the top-N common words per language used by the typo classes.

Ranking matches tests/TypoTests.swift (`frequencyWords` and `ruRank`/`enRank`):
the first whitespace token of each frequency-list line, lowercased, kept only if
it is a pure Cyrillic (а-я, ё) or Latin (a-z) word; a word's rank is its 1-based
position in that accepted sequence, first occurrence winning. The output holds
every word whose rank is at most `--top`, one per line, gzip mtime 0.

Usage: build_common_words.py --cache build/dict-cache --out Babbler/Resources [--top 5000]
"""

import argparse
import gzip
import re
from pathlib import Path

LANGS = {
    "ru": ("ru_freq.txt", re.compile(r"[а-яё]+")),
    "en": ("en_freq.txt", re.compile(r"[a-z]+")),
}


def common_words(freq_path, pattern, top):
    seen = set()
    out = []
    accepted = 0
    with open(freq_path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            fields = line.split()
            if not fields:
                continue
            word = fields[0].lower()
            if not pattern.fullmatch(word):
                continue
            accepted += 1
            if accepted > top:
                break
            if word not in seen:
                seen.add(word)
                out.append(word)
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--top", type=int, default=5000)
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    for lang, (freq_name, pattern) in LANGS.items():
        words = common_words(args.cache / freq_name, pattern, args.top)
        target = args.out / f"common-{lang}.txt.gz"
        with gzip.GzipFile(target, "wb", compresslevel=9, mtime=0) as handle:
            handle.write(("\n".join(words) + "\n").encode("utf-8"))
        print(f"{target.name}: {len(words)} words")


if __name__ == "__main__":
    main()
