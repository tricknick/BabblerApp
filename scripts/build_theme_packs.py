#!/usr/bin/env python3
"""Expands the theme-pack lemma lists in scripts/packs/ into inflected forms.

Each scripts/packs/<id>.txt lists one lemma per line ('#' starts a comment).
Forms come from suffix rules for Russian nouns, adjectives and verbs, so no
morphological dictionary is needed. A form is dropped when it is shorter than
two letters, or when its EN-layout keystrokes spell a word in en.txt.gz: such
a form would switch English words the user typed correctly.

Writes Babbler/Resources/pack-<id>.txt.gz: sorted, one form per line, gzip
mtime 0 so the output is reproducible.
"""

import argparse
import gzip
import re
import sys
from pathlib import Path

PACK_IDS = ["it", "business", "gaming", "slang", "mat"]
CYRILLIC = re.compile(r"^[а-я]+$")
VOWELS = "аеёиоуыэюя"
SPELL_I = "гкхжшщчц"  # ы becomes и after these
HUSHING = "жшщчц"  # е/ей endings instead of о/ом, у instead of ю

# Words that do not take endings in the lists, plus interjections.
INDECLINABLE = {
    "ваще", "щас", "щаз", "спс", "пжлст", "норм", "асап", "нах", "нахуй",
    "похуй", "нихуя", "пздц", "хз", "блин", "бля", "лол", "кек", "бро",
}


def read_lemmas(path):
    lemmas = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        word = line.split("#")[0].strip().lower().replace("ё", "е")
        if word:
            lemmas.add(word)
    return lemmas


def english_key_forms(keys_path):
    """Maps a Russian word to the text its keys produce on the EN layout."""
    source = keys_path.read_text(encoding="utf-8")
    table = re.search(r"let enRuDictionary = \[(.*?)\n\]", source, re.S).group(1)
    russian_to_english = {ru: en for en, ru in re.findall(r'"(.)": "(.)"', table)}
    return lambda word: "".join(russian_to_english.get(c, c) for c in word)


# --- nouns -----------------------------------------------------------------

def masc_hard(lemma):
    last = lemma[-1]
    gen_pl = "ей" if last in HUSHING else "ов"
    ins = "ем" if last in HUSHING else "ом"
    nom_pl = "и" if last in SPELL_I else "ы"
    return {
        lemma, lemma + "а", lemma + "у", lemma + ins, lemma + "е",
        lemma + nom_pl, lemma + gen_pl, lemma + "ам", lemma + "ами", lemma + "ах",
    }


def masc_soft_y(lemma):
    """Masculine nouns ending in -й (хуй): stem = lemma without the -й."""
    stem = lemma[:-1]
    return {
        lemma, stem + "я", stem + "ю", stem + "ем", stem + "е", stem + "и",
        stem + "ев", stem + "ям", stem + "ями", stem + "ях",
    }


def fem_soft(lemma):
    """Feminine nouns ending in -ь (блядь, отчетность)."""
    stem = lemma[:-1]
    return {
        lemma, stem + "и", stem + "ью", stem + "и", stem + "и",
        stem + "ей", stem + "ям", stem + "ями", stem + "ях",
    }


def fem_a(lemma):
    stem = lemma[:-1]
    last = stem[-1]
    spell_i = last in SPELL_I
    forms = {
        lemma, stem + ("и" if spell_i else "ы"), stem + "е", stem + "у",
        stem + ("ей" if last in HUSHING else "ой"), stem + "е",
        stem + ("и" if spell_i else "ы"), stem + "ам", stem + "ами", stem + "ах",
    }
    if last in HUSHING:
        forms.add(stem + "ек")
    elif last not in VOWELS and stem[-2] not in VOWELS:
        forms.add(stem[:-1] + "о" + stem[-1])
    return forms


def fem_ya(lemma):
    """Feminine nouns in -я (тусня, хуйня)."""
    stem = lemma[:-1]
    forms = {
        lemma, stem + "и", stem + "е", stem + "ю", stem + "ей", stem + "е",
        stem + "и", stem + "ям", stem + "ями", stem + "ях",
    }
    if stem.endswith("н"):
        forms.add(stem[:-1] + "ень")
    return forms


def fem_ia(lemma):
    """Feminine nouns in -ия (презентация, премия)."""
    stem = lemma[:-2]
    return {
        lemma, stem + "ии", stem + "ию", stem + "ией", stem + "ии",
        stem + "ий", stem + "иям", stem + "иями", stem + "иях",
    }


def neuter_o(lemma):
    stem = lemma[:-1]
    return {lemma, stem + "а", stem + "у", stem + "ом", stem + "е"}


def neuter_ie(lemma):
    stem = lemma[:-2]
    return {
        lemma, stem + "ия", stem + "ию", stem + "ием", stem + "ии",
        stem + "ий", stem + "иям", stem + "иями", stem + "иях",
    }


def inflect_noun(lemma):
    if lemma.endswith("ия"):
        return fem_ia(lemma)
    if lemma.endswith("ие"):
        return neuter_ie(lemma)
    last = lemma[-1]
    if last == "а":
        return fem_a(lemma)
    if last == "я":
        return fem_ya(lemma)
    if last == "о":
        return neuter_o(lemma)
    if last == "ь":
        return fem_soft(lemma)
    if last == "й":
        return masc_soft_y(lemma)
    if last in VOWELS:
        return {lemma}
    return masc_hard(lemma)


def inflect_adjective(lemma):
    stem = lemma[:-2]
    if lemma.endswith("ый"):
        endings = ["ый", "ого", "ому", "ым", "ом", "ая", "ой", "ую", "ое",
                   "ые", "ых", "ым", "ыми"]
    else:
        endings = ["ий", "его", "ему", "им", "ем", "яя", "ей", "юю", "ее",
                   "ие", "их", "им", "ими"]
    return {stem + ending for ending in endings}


# --- verbs -----------------------------------------------------------------

def first_person_stems(stem):
    """Stem variants for 1sg (consonant mutation and labial insertion)."""
    if stem.endswith("ст"):
        return {stem[:-2] + "щ"}
    last = stem[-1]
    if last in "бвмпф":
        return {stem + "л"}
    if last == "т":
        return {stem[:-1] + "ч"}
    if last == "д" or last == "з":
        return {stem[:-1] + "ж"}
    if last == "с":
        return {stem, stem[:-1] + "ш"}
    return {stem}


def verb_it(lemma):
    stem = lemma[:-3]
    forms = {lemma, stem + "ишь", stem + "ит", stem + "им", stem + "ите",
             stem + "ят", stem + "ил", stem + "ила", stem + "ило", stem + "или",
             stem + "и"}
    for first in first_person_stems(stem):
        forms.add(first + ("у" if first[-1] in HUSHING else "ю"))
    return forms


def verb_at(lemma, vowel):
    """-ать / -ять verbs: stem + а/я + personal endings."""
    stem = lemma[:-3]
    v = vowel
    return {
        lemma, stem + v + "ю", stem + v + "ешь", stem + v + "ет", stem + v + "ем",
        stem + v + "ете", stem + v + "ют", stem + v + "й", stem + v + "йте",
        stem + v + "л", stem + v + "ла", stem + v + "ло", stem + v + "ли",
    }


def verb_et(lemma):
    """-еть verbs: only the infinitive and past forms are generated."""
    stem = lemma[:-2]
    return {lemma, stem + "л", stem + "ла", stem + "ло", stem + "ли"}


def verb_nut(lemma):
    """Perfective -нуть verbs (релизнуть): past and imperative."""
    stem = lemma[:-4]
    return {lemma, stem + "нул", stem + "нула", stem + "нуло", stem + "нули",
            stem + "ни", stem + "ните"}


def verb_reflexive(lemma):
    """-ться verbs (созвониться): forms of the base verb plus -ся/-сь."""
    base = lemma[:-4] + "ть"
    forms = {lemma}
    for form in inflect_verb(base) - {base}:
        suffix = "сь" if form[-1] in "юеи" else "ся"
        forms.add(form + suffix)
    return forms


def inflect_verb(lemma):
    if lemma.endswith("ться"):
        return verb_reflexive(lemma)
    if lemma.endswith("ить"):
        return verb_it(lemma)
    if lemma.endswith("ать"):
        return verb_at(lemma, "а")
    if lemma.endswith("ять"):
        return verb_at(lemma, "я")
    if lemma.endswith("еть"):
        return verb_et(lemma)
    if lemma.endswith("нуть"):
        return verb_nut(lemma)
    return None


def inflect(lemma):
    if lemma in INDECLINABLE:
        return {lemma}
    verb_forms = inflect_verb(lemma)
    if verb_forms is not None:
        return verb_forms
    if lemma.endswith(("ый", "ий")):
        return inflect_adjective(lemma) | {lemma}
    return inflect_noun(lemma)


# --- build -----------------------------------------------------------------

def build_pack(lemmas, to_english, english):
    forms = set()
    for lemma in lemmas:
        forms |= inflect(lemma)
    forms = {f.replace("ё", "е") for f in forms}
    kept = set()
    dropped = []
    for form in forms:
        if not CYRILLIC.match(form) or len(form) < 2:
            dropped.append(form)
        elif to_english(form) in english:
            dropped.append(form)
        else:
            kept.add(form)
    return kept, dropped


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lemmas", type=Path, default=root / "scripts" / "packs")
    parser.add_argument("--out-dir", type=Path, default=root / "Babbler" / "Resources")
    parser.add_argument("--english", type=Path, default=root / "Babbler" / "Resources" / "en.txt.gz")
    parser.add_argument("--keys", type=Path, default=root / "Babbler" / "KeyDictionary.swift")
    args = parser.parse_args()

    english = {line.strip().lower() for line in
               gzip.open(args.english, "rt", encoding="utf-8").read().splitlines()
               if line.strip()}
    to_english = english_key_forms(args.keys)
    args.out_dir.mkdir(parents=True, exist_ok=True)

    for pack_id in PACK_IDS:
        lemmas = read_lemmas(args.lemmas / f"{pack_id}.txt")
        kept, dropped = build_pack(lemmas, to_english, english)
        data = ("\n".join(sorted(kept)) + "\n").encode("utf-8")
        (args.out_dir / f"pack-{pack_id}.txt.gz").write_bytes(
            gzip.compress(data, compresslevel=9, mtime=0))
        print(f"pack {pack_id}: {len(lemmas)} lemmas, {len(kept)} forms, "
              f"{len(dropped)} dropped", file=sys.stderr)


if __name__ == "__main__":
    main()
