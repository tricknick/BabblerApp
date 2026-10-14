#!/usr/bin/env python3
"""Trains the character n-gram language models bundled with Babbler.

Two models, Russian over а-я and English over a-z, each an interpolated
Kneser-Ney model of order N over words with boundary markers. They score strings
that no dictionary tier recognises: see "N-gram tier" in docs/DICTIONARY.md.

Training data:
  Russian  every OpenCorpora form (as build_ru_forms.py) + dictionaries/supplement-ru.txt
  English  the raw words_alpha list + dictionaries/supplement-en.txt + the bundled en.txt.gz

`--holdout 0.1` leaves out ~10% of Russian *lemmas* (all their forms) and ~10% of
English words and writes `holdout-ru.txt` / `holdout-en.txt` beside the model, so
an evaluation never scores a word the model has seen. The shipped resources are
trained with `--holdout 0`.

Run through scripts/build_dictionaries.sh, which prepares the virtualenv.
"""

import argparse
import gzip
import re
import sys
import zlib
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ngram_lib as lib  # noqa: E402

CYRILLIC = re.compile(r"^[а-яё]+$")
LATIN = re.compile(r"^[a-z]+$")
DROPPED_TAGS = {"Arch", "Erro"}
MIN_LENGTH = 3


def read_list(path, pattern):
    words = set()
    if path.exists():
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            word = line.split("#")[0].strip().lower()
            if word and pattern.match(word):
                words.add(word)
    return words


def russian_lemma_forms(cache):
    """{lemma: [forms]} for the OpenCorpora dictionary, cached as TSV."""
    path = cache / "ru-lemma-forms.tsv.gz"
    if not path.exists():
        import pymorphy3
        morph = pymorphy3.MorphAnalyzer()
        dictionary = morph.dictionary
        keep_cache = {}
        pairs = set()
        for word, (para_id, index) in dictionary.words.iteritems(""):
            if not CYRILLIC.match(word):
                continue
            key = (para_id, index)
            keep = keep_cache.get(key)
            if keep is None:
                tag = dictionary.build_tag_info(para_id, index)
                keep = keep_cache[key] = not (
                    set(str(tag).replace(" ", ",").split(",")) & DROPPED_TAGS)
            if keep:
                pairs.add((dictionary.build_normal_form(para_id, index, word), word))
        with gzip.open(path, "wt", encoding="utf-8") as handle:
            for lemma, word in sorted(pairs):
                handle.write(f"{word}\t{lemma}\n")
    lemmas = {}
    with gzip.open(path, "rt", encoding="utf-8") as handle:
        for line in handle:
            word, lemma = line.rstrip("\n").split("\t")
            lemmas.setdefault(lemma, []).append(word)
    return lemmas


def russian_data(args):
    """(training forms, holdout forms), ё folded, three letters or more."""
    train, held = set(), set()
    for lemma, forms in russian_lemma_forms(args.cache).items():
        target = held if lib.is_holdout(lemma, args.holdout) else train
        target.update(lib.fold_ru(f) for f in forms if len(f) >= MIN_LENGTH)
    supplement = {lib.fold_ru(w) for w in read_list(args.supplement_ru, CYRILLIC)
                  if len(w) >= MIN_LENGTH}
    train |= supplement
    # A held-out form that another lemma also produces is not held out.
    held -= train
    return sorted(train), sorted(held)


def english_data(args):
    pool = {w for w in read_list(args.english_raw, LATIN) if len(w) >= MIN_LENGTH}
    pool |= {w for w in gzip.open(args.english, "rt", encoding="utf-8").read().split()
             if LATIN.match(w) and len(w) >= MIN_LENGTH}
    held = {w for w in pool if lib.is_holdout(w, args.holdout)}
    supplement = {w for w in read_list(args.supplement_en, LATIN) if len(w) >= MIN_LENGTH}
    train = (pool - held) | supplement
    return sorted(train), sorted(held - train)


MAGIC = b"BNGM"
FORMAT_VERSION = 1
# Quantisation: each cost is -ln(p) in 1/STEP nat, clamped to one byte (15.9 nat).
STEP = 16


def train_model(words, language, order):
    """Dense table of -ln(p) costs, shape (V^order,), as uint8."""
    alphabet = lib.LANGUAGES[language]
    v = len(alphabet)
    counts = lib.count_top_order(words, alphabet, order)
    probabilities = lib.interpolated_probabilities(lib.lower_orders(counts, v), v)
    costs = -np.log(np.maximum(probabilities[order], 1e-12).astype(np.float64))
    return np.clip(np.rint(costs * STEP), 0, 255).astype(np.uint8).reshape(-1)


def serialise(language, order, costs):
    """Header: magic, version, order, alphabet size (with boundary), step, then
    the letters as UTF-16 code units; payload: raw deflate of the cost table."""
    letters = lib.LANGUAGES[language][1:]
    header = MAGIC + bytes([FORMAT_VERSION, order, len(letters) + 1, STEP])
    header += b"".join(ord(c).to_bytes(2, "little") for c in letters)
    deflater = zlib.compressobj(9, zlib.DEFLATED, -15)
    return header + deflater.compress(costs.tobytes()) + deflater.flush()


def main():
    root = Path(__file__).resolve().parent.parent
    cache = root / "build" / "dict-cache"
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--order", type=int, default=4)
    parser.add_argument("--holdout", type=float, default=0.0,
                        help="fraction of lemmas/words to leave out and list (0 = ship)")
    parser.add_argument("--cache", type=Path, default=cache)
    parser.add_argument("--output", type=Path, default=root / "Babbler" / "Resources")
    parser.add_argument("--supplement-ru", type=Path, default=root / "dictionaries" / "supplement-ru.txt")
    parser.add_argument("--supplement-en", type=Path, default=root / "dictionaries" / "supplement-en.txt")
    parser.add_argument("--english-raw", type=Path, default=cache / "en_words.txt")
    parser.add_argument("--english", type=Path, default=root / "Babbler" / "Resources" / "en.txt.gz")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    for language, loader in (("ru", russian_data), ("en", english_data)):
        train, held = loader(args)
        costs = train_model(train, language, args.order)
        blob = serialise(language, args.order, costs)
        (args.output / f"ngram-{language}.bin").write_bytes(blob)
        print(f"{language}: {len(train):,} training words, {len(held):,} held out, "
              f"order {args.order}, {len(blob) / 1024:.0f} KB")
        holdout_path = args.output / f"holdout-{language}.txt"
        if args.holdout > 0:
            holdout_path.write_text("\n".join(held) + "\n", encoding="utf-8")
        elif holdout_path.exists():
            holdout_path.unlink()


if __name__ == "__main__":
    main()
