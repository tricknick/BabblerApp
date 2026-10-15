#!/bin/zsh
#
# Rebuilds Babbler/Resources/{en.txt.gz,ru-forms.bin,ru-typo.bin,ngram-ru.bin,ngram-en.bin,
# common-ru.txt.gz,common-en.txt.gz} from public word lists.
#
# English is the intersection of a spellcheck word list with an OpenSubtitles
# frequency list, cut to a size that keeps the app's memory footprint
# reasonable, plus the curated files in dictionaries/.
#
# Russian is every inflected form of the OpenCorpora dictionary (compiled by
# pymorphy3-dicts-ru), plus the frequency-ranked core built the same way as the
# English list, plus the curated files with their forms generated. It is stored
# as sorted hashes: see scripts/build_ru_forms.py and docs/DICTIONARY.md.
#
# Downloads and intermediates go to build/dict-cache (gitignored) and are
# reused between runs; set REFRESH=1 to fetch everything again.
#
# Run this after editing anything in dictionaries/, then rebuild the app.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/Babbler/Resources"
SUPP_DIR="$ROOT_DIR/dictionaries"
CACHE_DIR="$ROOT_DIR/build/dict-cache"
mkdir -p "$CACHE_DIR" "$OUT_DIR"

# Word forms kept per language in the frequency-ranked lists. Russian needs far
# more because it is heavily inflected: one lemma expands to dozens of surface
# forms. The Russian list is only the core now: the full set of forms comes from
# OpenCorpora.
EN_LIMIT="${EN_LIMIT:-140000}"
RU_LIMIT="${RU_LIMIT:-200000}"
# Frequency-rank cutoff for generated three-letter words (see the note in the
# Python block). Curated words in dictionaries/ are never subject to it.
SHORT_RANK_LIMIT="${SHORT_RANK_LIMIT:-30000}"

# Pinned: the form list has to be reproducible. This is OpenCorpora 0.92,
# revision 417150 (CC BY-SA 3.0).
PYMORPHY_PACKAGES=(pymorphy3==2.0.6 pymorphy3-dicts-ru==2.4.417150.4580142)

EN_WORDS_URL="https://raw.githubusercontent.com/dwyl/english-words/master/words_alpha.txt"
RU_WORDS_URL="https://raw.githubusercontent.com/danakt/russian-words/master/russian.txt"
EN_FREQ_URL="https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_full.txt"
RU_FREQ_URL="https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_full.txt"

fetch() {
  local url="$1" target="$2"
  if [[ "${REFRESH:-0}" == "1" || ! -s "$target" ]]; then
    curl -fsSL --max-time 300 -o "$target.part" "$url"
    mv "$target.part" "$target"
  fi
}

echo "==> Downloading source lists..."
fetch "$EN_WORDS_URL" "$CACHE_DIR/en_words.txt"
fetch "$RU_WORDS_URL" "$CACHE_DIR/ru_words.raw"
fetch "$EN_FREQ_URL"  "$CACHE_DIR/en_freq.txt"
fetch "$RU_FREQ_URL"  "$CACHE_DIR/ru_freq.txt"

# Everything below is done in Python on purpose. This pipeline is all about
# character counts and case folding on Cyrillic, and the BSD shell tools get
# both wrong: `awk`'s length() counts bytes, so every two-letter Cyrillic word
# measures 4 and slips past a "3 or more" filter, and `tr 'А-ЯЁ' 'а-яё'` expands
# its ranges bytewise and mangles multi-byte input. Both failures are silent.
echo "==> Building the English list and the Russian core..."
python3 - "$CACHE_DIR" "$SUPP_DIR" "$OUT_DIR" "$EN_LIMIT" "$RU_LIMIT" "$SHORT_RANK_LIMIT" <<'PY'
import gzip, re, sys
from pathlib import Path

work, supp, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
EN_LIMIT = int(sys.argv[4])
RU_LIMIT = int(sys.argv[5])
limits = {"en": EN_LIMIT, "ru": RU_LIMIT}
# Three-letter words are the last high-collision zone: short enough that a
# layout flip lands on another real word, long enough to clear the length floor.
# The tail of the frequency list is full of junk at that length ("ult" ranks
# 214770, "abb", "abt", "aby"), and one such entry blocks a whole phrase - "где"
# stayed broken because "ult" looked like a word. Generated three-letter words
# therefore have to be reasonably common; curated ones bypass this.
SHORT_RANK_LIMIT = int(sys.argv[6])
out.mkdir(parents=True, exist_ok=True)

WORD_RE = {"en": re.compile(r"^[a-z]+$"), "ru": re.compile(r"^[а-яё]+$")}


def read_lines(path, encoding="utf-8"):
    with open(path, encoding=encoding, errors="replace") as handle:
        for line in handle:
            yield line.strip()


def valid_words(path, lang, encoding="utf-8"):
    """Spellcheck-valid forms: lowercase, alphabetic, at least two characters."""
    pattern = WORD_RE[lang]
    return {w for w in (l.lower() for l in read_lines(path, encoding))
            if len(w) >= 2 and pattern.match(w)}


def ranked(freq_path, valid, lang, limit):
    """Valid forms ordered by corpus frequency, capped at `limit`.

    Only words of three characters or more: one- and two-letter entries come
    from the hand-checked whitelist instead. The frequency lists are full of
    short subtitle noise ("dc", "lf", "цу", "ше"), and a bogus short word is
    unusually harmful - it decides whether "at." is punctuation or the Russian
    "фею", and short words are what retroactive phrase correction walks back
    over.
    """
    pattern, seen, kept = WORD_RE[lang], set(), []
    for index, line in enumerate(read_lines(freq_path)):
        word = line.split(" ")[0].lower()
        if len(word) < 3 or word in seen or word not in valid:
            continue
        if not pattern.match(word):
            continue
        if len(word) == 3 and index >= SHORT_RANK_LIMIT:
            continue
        seen.add(word)
        kept.append(word)
        if len(kept) >= limit:
            break
    return kept


def curated(path, lang, min_len, max_len):
    if not path.exists():
        return set()
    pattern = WORD_RE[lang]
    words = set()
    for line in read_lines(path):
        word = line.split("#")[0].strip().lower()
        if word and min_len <= len(word) <= max_len and pattern.match(word):
            words.add(word)
    return words


sources = {
    "en": (work / "en_words.txt", work / "en_freq.txt", "utf-8"),
    "ru": (work / "ru_words.raw", work / "ru_freq.txt", "cp1251"),
}

for lang, (words_path, freq_path, encoding) in sources.items():
    valid = valid_words(words_path, lang, encoding)
    final = set(ranked(freq_path, valid, lang, limits[lang]))
    final |= curated(supp / f"supplement-{lang}.txt", lang, 3, 64)
    final |= curated(supp / f"short-{lang}.txt", lang, 1, 2)

    payload = ("\n".join(sorted(final)) + "\n").encode("utf-8")
    if lang == "en":
        target = out / "en.txt.gz"
        with gzip.GzipFile(target, "wb", compresslevel=9, mtime=0) as handle:
            handle.write(payload)
    else:
        # Not bundled: the input of the Russian morphology step below. The
        # supplement is merged there too, with its forms generated.
        target = work / "ru-core.txt"
        target.write_bytes(payload)

    short = sum(1 for w in final if len(w) <= 2)
    print(f"    {lang}: {len(final)} words ({short} of 1-2 letters), "
          f"{target.stat().st_size // 1024} KB")
PY

echo "==> Building the Russian forms (OpenCorpora)..."
VENV="$CACHE_DIR/venv"
if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
fi
if ! "$VENV/bin/python" -c "import pymorphy3, numpy" 2>/dev/null; then
  "$VENV/bin/pip" install --quiet "${PYMORPHY_PACKAGES[@]}" numpy
fi

"$VENV/bin/python" "$ROOT_DIR/scripts/build_ru_forms.py" \
  --en-freq "$CACHE_DIR/en_freq.txt" \
  --core "$CACHE_DIR/ru-core.txt" \
  --supplement "$SUPP_DIR/supplement-ru.txt" \
  --short "$SUPP_DIR/short-ru.txt" \
  --english "$OUT_DIR/en.txt.gz" \
  --english-raw "$CACHE_DIR/en_words.txt" \
  --keys "$ROOT_DIR/Babbler/KeyDictionary.swift" \
  --out-dir "$OUT_DIR" \
  --cache "$CACHE_DIR"

# Theme packs: inflected forms of the lemma lists in scripts/packs/.
echo "==> Building the theme packs..."
"$VENV/bin/python" "$ROOT_DIR/scripts/build_theme_packs.py" \
  --lemmas "$ROOT_DIR/scripts/packs" \
  --out-dir "$OUT_DIR" \
  --english "$OUT_DIR/en.txt.gz" \
  --keys "$ROOT_DIR/Babbler/KeyDictionary.swift"

# The character n-gram models trained on every word, which ship; and a second
# pair trained without 10% of the words, which tests/run.sh scores honestly.
echo "==> Training the character n-gram models..."
"$VENV/bin/python" "$ROOT_DIR/scripts/build_ngram_models.py" --cache "$CACHE_DIR" --output "$OUT_DIR"
"$VENV/bin/python" "$ROOT_DIR/scripts/build_ngram_models.py" --cache "$CACHE_DIR" \
  --holdout 0.1 --output "$CACHE_DIR/ngram-holdout"

# The top 5000 words per language, used by the one-typo tiers in LayoutDictionary.
echo "==> Writing the common-word lists..."
python3 "$ROOT_DIR/scripts/build_common_words.py" --cache "$CACHE_DIR" --out "$OUT_DIR" --top 5000

rm -f "$OUT_DIR/ru.txt.gz"
echo "==> Done. Rebuild the app to pick them up: ./scripts/install.sh"
