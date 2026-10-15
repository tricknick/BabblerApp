#!/usr/bin/env python3
"""Extract a deterministic sample of Russian sentences from public web text.

Sources (downloaded into build/corpus/ if missing; that directory is gitignored):
  - Pikabu: IlyaGusev/pikabu shard 00 (posts + comments), zstd-compressed JSONL.
  - Habr:   dim/habr_10k parquet shard (article markdown, language == 'ru').

Output: build/corpus/pikabu.txt and build/corpus/habr.txt, one sentence per line.
Licenses of these corpora are unclear: never copy their text into tracked files.

  python3 scripts/corpus_extract.py
"""

import html
import json
import random
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / "build" / "corpus"

PIKABU_URL = "https://huggingface.co/datasets/IlyaGusev/pikabu/resolve/main/00.jsonl.zst"
PIKABU_FILE = CORPUS / "00.jsonl.zst"
HABR_URL = ("https://huggingface.co/datasets/dim/habr_10k/resolve/main/"
            "data/train-00000-of-00002-ceccf93ed44e54dd.parquet")
HABR_FILE = CORPUS / "habr-00.parquet"

SEED = 20240601
SAMPLE_SIZE = 3000
MIN_WORDS = 3
MAX_WORDS = 30
PIKABU_MAX_POSTS = 30000

CYRILLIC = re.compile(r"[а-яёА-ЯЁ]")
LATIN = re.compile(r"[a-zA-Z]")
URL = re.compile(r"(https?://|www\.)\S+")
MARKUP_IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
MARKUP_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
CODE_BLOCK = re.compile(r"```.*?```", re.S)
HTML_TAG = re.compile(r"<[^>]+>")
MARKUP_CHARS = re.compile(r"[*_`#>|~\\]")
SENTENCE_END = re.compile(r"(?<=[.!?…])\s+|\n+")


def download(url, dest):
    if dest.exists():
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"downloading {url} -> {dest.relative_to(ROOT)}", file=sys.stderr)
    tmp = dest.with_suffix(dest.suffix + ".part")
    urllib.request.urlretrieve(url, tmp)
    tmp.rename(dest)


def clean(text):
    text = CODE_BLOCK.sub(" ", text)
    text = html.unescape(HTML_TAG.sub(" ", text))
    text = MARKUP_IMAGE.sub(" ", text)
    text = MARKUP_LINK.sub(r"\1", text)
    text = URL.sub(" ", text)
    text = MARKUP_CHARS.sub(" ", text)
    return text


def sentences_of(text):
    out = []
    for chunk in SENTENCE_END.split(clean(text)):
        sentence = " ".join(chunk.split()).strip(" -–—\"«»'")
        if not sentence:
            continue
        tokens = sentence.split(" ")
        if not (MIN_WORDS <= len(tokens) <= MAX_WORDS):
            continue
        cyr = len(CYRILLIC.findall(sentence))
        lat = len(LATIN.findall(sentence))
        if cyr == 0 or cyr < lat:
            continue
        out.append(sentence)
    return out


def pikabu_texts():
    proc = subprocess.Popen(["zstd", "-dc", str(PIKABU_FILE)],
                            stdout=subprocess.PIPE, text=True, encoding="utf-8")
    posts = 0
    try:
        for line in proc.stdout:
            if posts >= PIKABU_MAX_POSTS:
                break
            posts += 1
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("text_markdown"):
                yield record["text_markdown"]
            comments = record.get("comments") or {}
            for body in comments.get("text_markdown") or []:
                if body:
                    yield body
    finally:
        proc.terminate()
        proc.wait()


def habr_texts():
    import pyarrow.parquet as pq
    table = pq.read_table(HABR_FILE, columns=["language", "text_markdown"])
    for language, text in zip(table.column("language").to_pylist(),
                              table.column("text_markdown").to_pylist()):
        if language == "ru" and text:
            yield text


def collect(texts):
    seen = set()
    for text in texts:
        for sentence in sentences_of(text):
            seen.add(sentence)
    return sorted(seen)


def write_sample(name, pool):
    rng = random.Random(SEED)
    sample = rng.sample(pool, min(SAMPLE_SIZE, len(pool)))
    out = CORPUS / f"{name}.txt"
    out.write_text("\n".join(sample) + "\n", encoding="utf-8")
    print(f"{name}: pool {len(pool)} sentences, wrote {len(sample)} -> "
          f"{out.relative_to(ROOT)}", file=sys.stderr)


def main():
    download(PIKABU_URL, PIKABU_FILE)
    download(HABR_URL, HABR_FILE)
    write_sample("pikabu", collect(pikabu_texts()))
    write_sample("habr", collect(habr_texts()))


if __name__ == "__main__":
    main()
