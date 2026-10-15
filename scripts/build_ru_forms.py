#!/usr/bin/env python3
"""Builds the Russian full-morphology word set bundled with Babbler.

Every inflected form of every OpenCorpora lexeme (via the pymorphy3 compilation
of the OpenCorpora dictionary), plus the frequency-ranked core list and the
curated supplements, is reduced to a sorted array of 48-bit hashes and stored
Rice-coded in Babbler/Resources/ru-forms.bin. A much smaller ru-typo.bin holds
the forms the typo probe may search. See docs/DICTIONARY.md.

Run through scripts/build_dictionaries.sh, which prepares the virtualenv.
"""

import argparse
import gzip
import math
import re
import struct
import sys
from multiprocessing import Pool
from pathlib import Path

import pymorphy3

HASH_BITS = 48
MASK64 = (1 << 64) - 1
FORMAT_VERSION = 1
MAGIC = b"BBLH"

CYRILLIC = re.compile(r"^[а-яё]+$")
ENGLISH_WORD = re.compile(r"^[a-z]+$")

# Tags that only add noise: archaic spellings and forms OpenCorpora itself
# marks as erroneous.
DROPPED_TAGS = {"Arch", "Erro"}


def hash48(word):
    """FNV-1a over UTF-8 followed by a murmur3 finalizer step, top 48 bits.

    Must match HashedWordSet.hash(_:) in Babbler/LayoutDictionary.swift.
    """
    h = 0xCBF29CE484222325
    for byte in word.encode("utf-8"):
        h = ((h ^ byte) * 0x100000001B3) & MASK64
    h ^= h >> 33
    h = (h * 0xFF51AFD7ED558CCD) & MASK64
    h ^= h >> 33
    return h >> (64 - HASH_BITS)


def hash_chunk(words):
    return [hash48(word) for word in words]


def hash_all(words):
    words = list(words)
    size = 50_000
    chunks = [words[i:i + size] for i in range(0, len(words), size)]
    with Pool() as pool:
        results = pool.map(hash_chunk, chunks)
    return [h for chunk in results for h in chunk]


def write_hash_set(path, hashes):
    """Sorted unique hashes -> header + Rice-coded gaps, LSB-first bit order."""
    values = sorted(set(hashes))
    count = len(values)
    mean_gap = (1 << HASH_BITS) / count
    k = max(1, int(math.log2(mean_gap * math.log(2))))

    out = bytearray(struct.pack("<4sBBBBII", MAGIC, FORMAT_VERSION, HASH_BITS, k, 0, count, 0))
    acc = 0
    bits = 0
    previous = 0
    mask_k = (1 << k) - 1
    for value in values:
        gap = value - previous
        previous = value
        q = gap >> k
        acc |= ((1 << q) | ((gap & mask_k) << (q + 1))) << bits
        bits += q + 1 + k
        while bits >= 64:
            out += (acc & MASK64).to_bytes(8, "little")
            acc >>= 64
            bits -= 64
    while bits > 0:
        out.append(acc & 0xFF)
        acc >>= 8
        bits -= 8
    # The reader loads 8 bytes at a time from any bit offset.
    out += bytes(16)
    path.write_bytes(out)
    return count, k


def normalize(word):
    return word.replace("ё", "е")


def lexicon_forms(morph, drop_tags):
    """All surface forms of the OpenCorpora dictionary that pass the filters."""
    dictionary = morph.dictionary
    cache = {}
    forms = set()
    for word, (para_id, index) in dictionary.words.iteritems(""):
        key = (para_id, index)
        keep = cache.get(key)
        if keep is None:
            tag = dictionary.build_tag_info(para_id, index)
            keep = cache[key] = not (set(str(tag).replace(" ", ",").split(",")) & drop_tags)
        if keep and CYRILLIC.match(word):
            forms.add(word)
    return forms


def read_words(path, min_len=1, max_len=64):
    words = set()
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            word = line.split("#")[0].strip().lower()
            if word and min_len <= len(word) <= max_len and CYRILLIC.match(word):
                words.add(word)
    return words


INFLECTED_POS = {"NOUN", "INFN", "ADJF"}


def inflect_supplement(morph, words):
    """Full paradigms for supplement entries that are lemmas.

    pymorphy3 guesses a paradigm for unknown words from their ending (and for
    prefixed verbs such as закоммитить from the stem). An entry is expanded only
    when the guess says it is itself a dictionary form; entries that are already
    inflected ("дашборда") are kept verbatim.
    """
    forms = set()
    for word in words:
        forms.add(word)
        if len(word) < 4:
            continue
        for parse in morph.parse(word)[:2]:
            if parse.tag.POS not in INFLECTED_POS:
                continue
            if normalize(parse.normal_form) != word:
                continue
            for form in parse.lexeme:
                if CYRILLIC.match(form.word):
                    forms.add(form.word)
    return forms


def english_key_forms(keys_path):
    """Function mapping a Russian word to what its keys spell on the EN layout."""
    source = keys_path.read_text(encoding="utf-8")
    table = re.search(r"let enRuDictionary = \[(.*?)\n\]", source, re.S).group(1)
    russian_to_english = {ru: en for en, ru in re.findall(r'"(.)": "(.)"', table)}
    return lambda word: "".join(russian_to_english.get(c, c) for c in word)


def english_collisions(forms, protected, to_english, english, english_raw):
    """Forms whose EN-layout keys spell an English word the bundled list lacks.

    A correctly typed English word is protected by being in en.txt.gz. One that
    is not (an obscure word from the raw list) is only as safe as the Russian
    list is free of the string its keys produce. Dropping such a form costs
    nothing in the other direction either: typed correctly in Russian it is
    kept because its EN-keys are not an English dictionary word.
    """
    unprotected = english_raw - english
    return {w for w in forms
            if w not in protected and len(w) >= 3 and to_english(w) in unprotected}


def frequent_english(freq_path, limit=20000):
    """The most frequent all-lowercase Latin words of the frequency list."""
    words = []
    for line in freq_path.read_text(encoding="utf-8", errors="replace").split("\n"):
        first = line.split(" ")[0]
        if ENGLISH_WORD.match(first):
            words.append(first)
            if len(words) == limit:
                break
    return set(words)


def english_frequent_collisions(forms, protected, to_english, english_common):
    # Rule: drop non-core forms whose EN-layout keys spell a top-20k English word;
    # protected (core/short/inflected) forms are never dropped.
    """Return the non-core forms whose EN-layout keys spell a top English word."""
    return {w for w in forms
            if w not in protected and to_english(w) in english_common}


def with_yo_variants(words):
    """Add the ё-less spelling: people type "пошел" far more than "пошёл"."""
    extra = {normalize(word) for word in words if "ё" in word}
    return words | extra


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--core", type=Path, required=True,
                        help="frequency-ranked core list (one word per line)")
    parser.add_argument("--supplement", type=Path, required=True)
    parser.add_argument("--short", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--english", type=Path, required=True,
                        help="bundled en.txt.gz")
    parser.add_argument("--english-raw", type=Path, required=True,
                        help="unfiltered English word list")
    parser.add_argument("--keys", type=Path, required=True,
                        help="Babbler/KeyDictionary.swift, the layout key map")
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--en-freq", type=Path, required=True,
                        help="English frequency list (word count per line)")
    parser.add_argument("--drop-tags", default=",".join(sorted(DROPPED_TAGS)),
                        help="comma-separated OpenCorpora grammemes to exclude")
    args = parser.parse_args()

    morph = pymorphy3.MorphAnalyzer()
    meta = morph.dictionary.meta
    print(f"    OpenCorpora {meta['source_version']} r{meta['source_revision']}, "
          f"{meta['words_dawg_length']} raw forms")

    drop_tags = {tag for tag in args.drop_tags.split(",") if tag}
    core = read_words(args.core, 1, 64)
    short = read_words(args.short, 1, 2)
    supplement = read_words(args.supplement, 3, 64)

    lexicon = lexicon_forms(morph, drop_tags)
    # One- and two-letter words are hand-written only, and a three-letter word
    # has to be in the frequency-ranked core: junk entries that short break
    # phrase correction (see docs/DICTIONARY.md).
    lexicon = {w for w in lexicon
               if len(w) >= 4 or (len(w) == 3 and w in core)}

    inflected = inflect_supplement(morph, supplement)
    forms = with_yo_variants(lexicon | core | short | inflected)

    english = set(gzip.open(args.english, "rt", encoding="utf-8").read().split())
    english_raw = {w.strip().lower() for w in args.english_raw.read_text().splitlines()}
    protected = with_yo_variants(core | short | inflected)
    to_english = english_key_forms(args.keys)
    dropped = english_collisions(forms, protected, to_english, english, english_raw)
    dropped |= english_frequent_collisions(
        forms, protected, to_english, frequent_english(args.en_freq))
    forms -= dropped
    print(f"    lexicon {len(lexicon)}, core {len(core)}, supplement "
          f"{len(supplement)} -> {len(inflected)} forms; "
          f"dropped {len(dropped)} colliding with English words; total {len(forms)}")

    args.cache.mkdir(parents=True, exist_ok=True)
    (args.cache / "ru_dropped_forms.txt").write_text(
        "".join(f"{w}\n" for w in sorted(dropped)), encoding="utf-8")
    listing = args.cache / "ru-forms.txt.gz"
    with gzip.GzipFile(listing, "wb", compresslevel=6, mtime=0) as handle:
        handle.write(("\n".join(sorted(forms)) + "\n").encode("utf-8"))

    args.out_dir.mkdir(parents=True, exist_ok=True)
    target = args.out_dir / "ru-forms.bin"
    count, k = write_hash_set(target, hash_all(forms))
    print(f"    {target.name}: {count} hashes ({len(forms) - count} collisions), "
          f"rice k={k}, {target.stat().st_size / 1e6:.1f} MB")

    # The typo probe makes ~200 lookups per word, so every extra form raises
    # its false-positive rate. It only sees the frequency-ranked core and the
    # supplement; exact matches use the full set above.
    typo_forms = with_yo_variants(core | short | inflected)
    typo_target = args.out_dir / "ru-typo.bin"
    count, k = write_hash_set(typo_target, hash_all(typo_forms))
    print(f"    {typo_target.name}: {count} hashes, {typo_target.stat().st_size / 1e6:.2f} MB")


if __name__ == "__main__":
    sys.exit(main())
