#!/usr/bin/env python3
"""Source fetchers and deterministic breaker transforms for the fuzz campaign.

  fuzz_gen.py fetch
      Fetch open Russian text sources into build/fuzz/sources/<name>.txt
      (one sentence per line). Records outcome in build/fuzz/sources/manifest.json.

  fuzz_gen.py gen --source S --breaker B --n N --seed K --out PATH
      Sample N sentences from source S, apply breaker B, write TSV rows
      (source, breaker, sentence) to PATH.
"""

import argparse
import json
import os
import random
import time
import urllib.error
import re
import sys
import urllib.parse
import urllib.request

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SRC_DIR = os.path.join(ROOT, "build", "fuzz", "sources")
CORPUS_DIR = os.path.join(ROOT, "build", "corpus")

SOURCE_PATHS = {
    "pikabu": os.path.join(CORPUS_DIR, "pikabu.txt"),
    "habr": os.path.join(CORPUS_DIR, "habr.txt"),
}
for name in ("wiki_ru", "news", "chat", "github_readme_ru", "subtitles"):
    SOURCE_PATHS[name] = os.path.join(SRC_DIR, name + ".txt")

WIKI_API = {
    "wiki_ru": "https://ru.wikipedia.org/w/api.php",
    "news": "https://ru.wikinews.org/w/api.php",
}

CYR = re.compile(r"[а-яёА-ЯЁ]")
LET = re.compile(r"[A-Za-zа-яёА-ЯЁ]")


def split_sentences(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("="):
            continue
        line = re.sub(r"\([^)]*\)", "", line)
        line = re.sub(r"\s+", " ", line).strip()
        for part in re.split(r"(?<=[.!?])\s+(?=[А-ЯЁA-Z«\"])", line):
            part = part.strip()
            if 25 <= len(part) <= 180 and "{" not in part and "|" not in part:
                letters = LET.findall(part)
                if letters and len(CYR.findall(part)) / len(letters) >= 0.6:
                    out.append(part)
    return out


def _get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "BabblerFuzz/1.0 (research; contact vlasov@progress.com)"})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            if exc.code != 429 or attempt == 5:
                raise
            time.sleep(5 * (attempt + 1))


def fetch_wiki(api, calls):
    sentences = []
    for _ in range(calls):
        q = urllib.parse.urlencode({
            "action": "query", "generator": "random", "grnnamespace": 0,
            "grnlimit": 20, "prop": "extracts", "explaintext": 1,
            "exlimit": 20, "exchars": 3000, "format": "json",
        })
        data = _get_json(api + "?" + q)
        time.sleep(1.5)
        for page in data.get("query", {}).get("pages", {}).values():
            sentences.extend(split_sentences(page.get("extract", "")))
    return sentences


def cmd_fetch(_args):
    os.makedirs(SRC_DIR, exist_ok=True)
    manifest = {}
    for name, api in WIKI_API.items():
        try:
            sents = fetch_wiki(api, calls=15)
            seen, uniq = set(), []
            for s in sents:
                if s not in seen:
                    seen.add(s)
                    uniq.append(s)
            with open(SOURCE_PATHS[name], "w", encoding="utf-8") as f:
                f.write("\n".join(uniq) + "\n")
            manifest[name] = {"status": "ok", "sentences": len(uniq)}
        except Exception as exc:  # network or parse failure: skip source
            manifest[name] = {"status": "failed", "error": str(exc)[:200]}
    with open(os.path.join(SRC_DIR, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


# ---------- breakers: each takes (sentence, rng) and returns a string ----------

def words_of(s):
    return s.split(" ")


def b_none(s, r):
    return s


def b_title_case(s, r):
    return " ".join(w[:1].upper() + w[1:] for w in words_of(s))


def b_all_caps(s, r):
    return s.upper()


PUNCT_TAILS = ["?!", "...", "?!?", "!!!", ")))", "?)", "!)", "))", "?!!"]
PUNCT_INNER = ["...", "?!", "))", "!!", "?"]


def b_punct_combo(s, r):
    w = words_of(s)
    if r.random() < 0.4:
        i = r.randrange(len(w))
        w[i] = w[i].rstrip(".!?") + r.choice(PUNCT_INNER)
    return " ".join(w).rstrip(".") + r.choice(PUNCT_TAILS)


def _wrap_span(s, r, left, right):
    w = words_of(s)
    if len(w) < 2:
        return s + " " + left + "ок" + right
    span = r.randint(1, min(3, len(w)))
    i = r.randrange(0, len(w) - span + 1)
    w[i] = left + w[i]
    w[i + span - 1] = w[i + span - 1] + right
    return " ".join(w)


def b_guillemets(s, r):
    return _wrap_span(s, r, "«", "»")


def b_brackets(s, r):
    return _wrap_span(s, r, "(", ")")


EMOJI = ["😂", "🤔", "👍", "🔥", "😅", "❤️", "🙏", "🚀", "🎉", "😊", "👀", "💀"]


def b_emoji(s, r):
    w = words_of(s)
    e = r.choice(EMOJI)
    if r.random() < 0.5:
        return s + " " + e
    i = r.randrange(len(w))
    w.insert(i + 1, e)
    return " ".join(w)


DIGIT_TOKENS = ["2024", "15:30", "12.05.2024", "v2.3.1", "3 раза", "100500", "1-го", "25%",
                "5 лет", "в 9:00", "2017-03-21", "10 000 руб.", "8-800", "iOS 17", "1990-х"]


def _insert_token(s, r, tokens):
    w = words_of(s)
    tok = r.choice(tokens)
    i = r.randrange(0, len(w) + 1)
    w.insert(i, tok)
    return " ".join(w)


def b_digits(s, r):
    return _insert_token(s, r, DIGIT_TOKENS)


TRANSLIT = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo", "ж": "zh",
    "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o",
    "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f", "х": "h", "ц": "ts",
    "ч": "ch", "ш": "sh", "щ": "sch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}
CHAT_SLANG = ["ща", "норм", "спс", "кек", "ок", "хз", "лол", "гг", "ага"]


def translit(word):
    return "".join(TRANSLIT.get(c.lower(), c) for c in word)


def b_slang_translit(s, r):
    w = words_of(s)
    cands = [i for i, x in enumerate(w) if len(x) >= 4 and CYR.search(x)]
    if cands:
        for i in r.sample(cands, min(len(cands), r.randint(1, 2))):
            w[i] = translit(w[i])
    else:
        w.append(r.choice(CHAT_SLANG))
    if r.random() < 0.5:
        w.append(r.choice(CHAT_SLANG))
    return " ".join(w)


NAMES_BRANDS = ["Иван Петров", "Анна Смирнова", "Сбербанк", "Яндекс", "Тинькофф", "Озон",
                "ВКонтакте", "Санкт-Петербург", "Екатеринбург", "Нижний Новгород",
                "Ростов-на-Дону", "МегаФон", "Пятёрочка", "Лада", "Газпром", "Ильич",
                "Юрий Гагарин", "в Новосибирске", "в Казани", "Сергей Лавров"]


def b_names_brands(s, r):
    return _insert_token(s, r, NAMES_BRANDS)


ROWS = ["йцукенгшщзхъ", "фывапролджэ", "ячсмитьбю"]


def _neighbor_typo(word, r):
    idx = [i for i, c in enumerate(word) if c.lower() in "".join(ROWS)]
    if not idx:
        return word
    i = r.choice(idx)
    c = word[i].lower()
    for row in ROWS:
        if c in row:
            p = row.index(c)
            nb = [row[j] for j in (p - 1, p + 1) if 0 <= j < len(row)]
            nc = r.choice(nb)
            return word[:i] + (nc.upper() if word[i].isupper() else nc) + word[i + 1:]
    return word


def b_double_typo(s, r):
    w = words_of(s)
    cands = [i for i, x in enumerate(w) if len(x) >= 4 and CYR.search(x)]
    for i in r.sample(cands, min(len(cands), 2)):
        w[i] = _neighbor_typo(w[i], r)
    return " ".join(w)


EN_TERMS = ["git", "PR", "API", "backend", "frontend", "bug", "deploy", "JSON", "Docker",
            "UI", "TODO", "pull request", "commit", "merge", "hotfix", "Slack", "Jira"]
RU_ENGLISH_VERBS = ["деплоить", "пушнуть", "мержнуть", "запушить", "коммитнуть",
                    "ребейзить", "фиксить", "дебажить", "бэкенд", "фронт"]


def b_en_terms(s, r):
    w = words_of(s)
    for _ in range(r.randint(1, 2)):
        pool = EN_TERMS + RU_ENGLISH_VERBS
        w.insert(r.randrange(0, len(w) + 1), r.choice(pool))
    return " ".join(w)


ABBR = ["РФ", "МВД", "т.е.", "т.к.", "и т.д.", "и т.п.", "напр.", "г.", "ООО", "ФСБ", "ЕС",
        "т. д.", "см.", "ул.", "проф."]


def b_abbreviations(s, r):
    return _insert_token(s, r, ABBR)


HYPHEN_PAIRS = [("кто то", "кто-то"), ("что то", "что-то"), ("из за", "из-за"),
                ("по этому", "поэтому"), ("из под", "из-под"), ("по прежнему", "по-прежнему"),
                ("какой то", "какой-то"), ("по быстрому", "по-быстрому")]
HYPHEN_INSERT = ["кто-то", "из-за", "по-прежнему", "что-то", "какой-нибудь", "пол-часа",
                 "O'Reilly", "Ben's", "d'Artagnan", "rock-n-roll", "Кто-нибудь", "Нью-Йорк"]


def b_hyphen_apostrophe(s, r):
    for a, b in HYPHEN_PAIRS:
        if a in s:
            return s.replace(a, b, 1)
    return _insert_token(s, r, HYPHEN_INSERT)


def b_yo_y(s, r):
    out = []
    for w in words_of(s):
        if r.random() < 0.5:
            w = w.replace("ё", "е").replace("Ё", "Е")
        if r.random() < 0.5:
            w = w.replace("й", "и").replace("Й", "И")
        out.append(w)
    res = " ".join(out)
    if res == s:
        res = _insert_token(s, r, ["елка", "ежик", "все", "ёлка", "йогурт", "мой"])
    return res


SHORT = ["я", "в", "к", "у", "ну", "да", "не", "же", "ли", "бы", "и", "а", "о", "с", "из",
         "на", "по", "то", "ж", "ок", "во", "ни", "он", "мы", "ты"]


def b_short_words(s, r):
    k = r.randint(4, 8)
    phrase = " ".join(r.choice(SHORT) for _ in range(k))
    w = words_of(s)
    i = r.randrange(0, len(w) + 1)
    w[i:i] = phrase.split(" ")
    return " ".join(w)


BREAKERS = {
    "none": b_none,
    "title_case": b_title_case,
    "all_caps": b_all_caps,
    "punct_combo": b_punct_combo,
    "guillemets": b_guillemets,
    "brackets": b_brackets,
    "emoji": b_emoji,
    "digits": b_digits,
    "slang_translit": b_slang_translit,
    "names_brands": b_names_brands,
    "double_typo": b_double_typo,
    "en_terms": b_en_terms,
    "abbreviations": b_abbreviations,
    "hyphen_apostrophe": b_hyphen_apostrophe,
    "yo_y": b_yo_y,
    "short_words": b_short_words,
}


def load_sentences(source):
    path = SOURCE_PATHS[source]
    with open(path, encoding="utf-8") as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    return [ln for ln in lines if 20 <= len(ln) <= 200 and "\t" not in ln]


def cmd_gen(args):
    if args.breaker not in BREAKERS:
        sys.exit(f"unknown breaker {args.breaker}; choose from {', '.join(BREAKERS)}")
    pool = load_sentences(args.source)
    r = random.Random(args.seed)
    picks = r.sample(pool, min(args.n, len(pool)))
    fn = BREAKERS[args.breaker]
    rows = []
    for s in picks:
        t = fn(s, r).replace("\t", " ").replace("\n", " ").strip()
        rows.append(f"{args.source}\t{args.breaker}\t{t}")
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("# source\tbreaker\tsentence (correct intended text)\n")
        f.write("\n".join(rows) + "\n")
    print(f"wrote {len(rows)} rows to {args.out}")


def build_parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("fetch", help="fetch open RU text sources").set_defaults(func=cmd_fetch)
    pg = sub.add_parser("gen", help="generate TSV cases for one cell")
    pg.add_argument("--source", required=True)
    pg.add_argument("--breaker", required=True)
    pg.add_argument("--n", type=int, default=150)
    pg.add_argument("--seed", type=int, default=1)
    pg.add_argument("--out", required=True)
    pg.set_defaults(func=cmd_gen)
    return p


if __name__ == "__main__":
    a = build_parser().parse_args()
    a.func(a)
