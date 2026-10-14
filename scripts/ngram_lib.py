"""Character n-gram language model: training data, interpolated Kneser-Ney
estimation and scoring. Shared by build_ngram_models.py and the evaluation tools.

Everything is dense numpy: an order-N model over V symbols is an array of
V^(N-1) contexts by V next symbols, so training is a few bincount calls and the
interpolated probabilities for unseen n-grams are filled in by the back-off
itself. See docs/DICTIONARY.md.
"""

import hashlib

import numpy as np

BOUNDARY = "#"
RU_LETTERS = "абвгдежзийклмнопрстуфхцчшщъыьэюя"
EN_LETTERS = "abcdefghijklmnopqrstuvwxyz"

LANGUAGES = {
    "ru": BOUNDARY + RU_LETTERS,
    "en": BOUNDARY + EN_LETTERS,
}

# Natural-log penalty for each character a model cannot represent at all.
OUT_OF_ALPHABET = -12.0


def fold_ru(word):
    """The model has no ё: it is a different key, and people type е for it."""
    return word.replace("ё", "е")


def is_holdout(key, fraction):
    """Stable assignment of a lemma or word to the evaluation holdout."""
    if fraction <= 0:
        return False
    digest = hashlib.sha1(("holdout:" + key).encode("utf-8")).digest()
    return int.from_bytes(digest[:4], "little") / 2**32 < fraction


def encode(words, alphabet, order):
    """Words -> flat symbol array, a mask of the predicted positions (a letter
    or the closing boundary, never a leading pad), the word index of every
    position and the number of out-of-alphabet characters per word.

    Each word carries order-1 leading boundaries, so any window ending on a
    predicted position lies inside its own word's block. Characters outside the
    alphabet are scored as a boundary and counted separately.
    """
    table = np.full(0x110000, -1, dtype=np.int16)
    for i, c in enumerate(alphabet):
        table[ord(c)] = i
    count = len(words)
    lengths = np.fromiter((len(w) for w in words), dtype=np.int64, count=count)
    codepoints = np.frombuffer("".join(words).encode("utf-32-le"), dtype=np.uint32)
    symbols = table[codepoints]

    block = lengths + order
    starts = np.cumsum(block) - block
    letter_owner = np.repeat(np.arange(count), lengths)
    within = np.arange(len(codepoints)) - np.repeat(np.cumsum(lengths) - lengths, lengths)
    positions = starts[letter_owner] + (order - 1) + within

    total = int(block.sum())
    flat = np.zeros(total, dtype=np.int64)
    mask = np.zeros(total, dtype=bool)
    flat[positions] = np.maximum(symbols, 0)
    mask[positions] = True
    mask[starts + (order - 1) + lengths] = True
    owner = np.repeat(np.arange(count), block)
    unknown = np.bincount(letter_owner[symbols < 0], minlength=count)
    return flat, mask, owner, unknown


def window_codes(flat, order, v):
    """Index of the order-gram ending at every position (positions that cannot
    hold a full window get 0; callers mask them)."""
    n = len(flat)
    code = np.zeros(n, dtype=np.int64)
    for k in range(order):
        shifted = np.zeros(n, dtype=np.int64)
        shifted[order - 1 - k:] = flat[:n - (order - 1 - k)]
        code = code * v + shifted
    return code


def count_top_order(words, alphabet, order):
    """Raw counts of every order-gram as a (V^(order-1), V) array."""
    v = len(alphabet)
    flat, mask, _, _ = encode(words, alphabet, order)
    codes = window_codes(flat, order, v)[mask]
    counts = np.bincount(codes, minlength=v ** order)
    return counts.astype(np.int64).reshape(v ** (order - 1), v)


def lower_orders(top, v):
    """Kneser-Ney continuation counts for every order below the top.

    The count of an n-gram is the number of distinct symbols that precede it in
    the next order up, except for n-grams that start at the word start, whose
    left context is always the boundary and which keep their raw count.
    """
    order = int(round(np.log(top.size) / np.log(v)))
    tables = {order: top}
    current = top
    for n in range(order - 1, 0, -1):
        higher = current.reshape(v, v ** n)
        lower = (higher > 0).sum(axis=0).astype(np.int64)
        starts = v ** (n - 1)
        lower[:starts] = higher[0, :starts]
        current = lower.reshape(v ** (n - 1), v)
        tables[n] = current
    return tables


def discount(counts):
    """Ney-Essen discount from the counts of counts."""
    n1 = int((counts == 1).sum())
    n2 = int((counts == 2).sum())
    return n1 / (n1 + 2 * n2) if n1 + 2 * n2 > 0 else 0.5


def interpolated_probabilities(tables, v):
    """Interpolated Kneser-Ney conditional probabilities for every order.

    Returns {n: float32 array (V^(n-1), V)}; each is a complete conditional
    distribution for every context, with unseen n-grams filled in from the
    lower orders.
    """
    order = max(tables)
    probabilities = {}
    lower = np.full((1, v), 1.0 / v, dtype=np.float64)
    for n in range(1, order + 1):
        counts = tables[n].astype(np.float64)
        d = discount(tables[n])
        total = counts.sum(axis=1, keepdims=True)
        distinct = (counts > 0).sum(axis=1, keepdims=True)
        safe = np.where(total > 0, total, 1.0)
        if n == 1:
            backoff = lower
        else:
            backoff = np.broadcast_to(
                lower.reshape(1, v ** (n - 2), v), (v, v ** (n - 2), v)).reshape(v ** (n - 1), v)
        weight = np.where(total > 0, d * distinct / safe, 1.0)
        p = np.maximum(counts - d, 0.0) / safe + weight * backoff
        probabilities[n] = p.astype(np.float32)
        lower = p
    return probabilities


def score_words(words, alphabet, log_table, order):
    """Total natural-log probability of each word under a dense order-N table
    of log probabilities (flat, indexed by window code).

    Characters outside the alphabet each cost OUT_OF_ALPHABET.
    """
    v = len(alphabet)
    flat, mask, owner, unknown = encode(words, alphabet, order)
    codes = window_codes(flat, order, v)
    contributions = np.where(mask, log_table[codes], 0.0)
    totals = np.bincount(owner, weights=contributions, minlength=len(words))
    return totals + unknown * OUT_OF_ALPHABET
