# Dictionaries

The auto-switch engine decides using word lists bundled in the app:

| Resource | Content | Size |
| --- | --- | --- |
| `Babbler/Resources/en.txt.gz` | 137,354 English words | 0.37 MB gzipped |
| `Babbler/Resources/ru-forms.bin` | 3,145,518 Russian word forms, hashed | 11.1 MB |
| `Babbler/Resources/ru-typo.bin` | 205,087 core Russian forms, hashed (typo tier only) | 0.8 MB |

Resident cost of everything loaded: about 26 MB, loaded in about 60 ms
(measured, see "Memory and load time").

## Russian: full morphology

The Russian list contains **every inflected form** (cases, numbers, genders,
conjugations, participles, short forms, comparatives) of the OpenCorpora
dictionary, not a frequency-ranked sample. `бизнесменами`, `закоммитил`,
`зарелизили`, `отрефакторенный`, `созвонимся`, `переиспользовать`,
`считающихся` all resolve.

**Source.** [OpenCorpora](https://opencorpora.org) 0.92 (revision 417150),
used through the `pymorphy3-dicts-ru` 2.4.417150.4580142 PyPI package, which is
the same dictionary pre-compiled to a form index. Chosen over Hunspell `ru_RU`
because it carries full lemma paradigms (including participles, short
adjectives and comparatives), is available as a pre-compiled form index with no
`unmunch` or affix-expansion step, and gives a pinned, reproducible build. The opcorpora.org
download itself was unreachable when this was built, which is the other reason
for the PyPI mirror.

**License.** OpenCorpora is licensed
[CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/). Attribution:
"OpenCorpora.org (http://opencorpora.org), CC BY-SA 3.0". `ru-forms.bin` is a
derived work (hashes of forms from that dictionary) and is therefore itself
distributed under CC BY-SA 3.0; the code remains under the project's licence.

**What is filtered out.**

- Forms tagged `Arch` (archaic) or `Erro` (erroneous), and anything that is not
  purely `[а-яё]`.
- One- and two-letter forms come only from `dictionaries/short-ru.txt`, and
  three-letter forms only if they were already in the old frequency-ranked core
  list. OpenCorpora is full of rare short forms that collide with English
  keystrokes.
- 6 forms whose English-layout key sequence spells an English word that is in
  the raw `words_alpha` list but not in `en.txt.gz` (`bkpt`↔`илзе`,
  `faba`↔`афиф` and so on). Only forms outside the old core list are eligible.
  Forms whose key sequence is in `en.txt.gz` are **never** dropped: a Russian
  word typed correctly would then be missing and its keys would look like
  English.

**Top-English collisions.** Non-core forms (not core, short or inflected) whose
English-layout key sequence spells one of the top 20,000 English words
(`en_freq.txt`) are dropped from `ru-forms.bin`, so typing that English word on
the Russian layout is not switched to the Russian form. The dropped forms are
written sorted to `build/dict-cache/ru_dropped_forms.txt`.

**ё.** The engine does not fold ё and е (they are different keys: `§` and
`e`), so the list holds both spellings of every form containing ё
(`пошёл`/`пошел`, `отрефакторённый`/`отрефакторенный`).

**Curated lemmas are inflected.** Every noun, infinitive and adjective in
`dictionaries/supplement-ru.txt` of four letters or more is passed through the
pymorphy3 predictor (the top two parses are used), so adding the lemma
`зарелизить` yields `зарелизили`, `зарелизил`, `зарелизим` and so on. Forms of
other lemmas, and any lemma the predictor gets wrong, can still be listed
explicitly; the supplement keeps working as a plain list of words.

### Storage format

A `Set<String>` of three million words costs about 430 MB resident and 2.6 s to
build, so the list is stored as hashes instead:

- Each form is hashed to 48 bits (FNV-1a over the UTF-8 bytes, then a 64-bit
  mixer, top 48 bits). There were 0 collisions among the 3.1 M forms; the
  chance that an arbitrary other string matches a stored hash is about
  3×10⁻⁸.
- The hashes are sorted and the gaps between them are Rice-coded (k = 25), which
  brings 3.1 M hashes to 11.1 MB. File layout: 16-byte header (`BBLH`, version,
  hash bits, k, count), the bit stream (per gap: `q` zero bits, a one bit, `k`
  remainder bits, LSB first), 16 bytes of padding.
- At load time `HashedWordSet` in `LayoutDictionary.swift` decodes the stream
  into 65,536 buckets selected by the top 16 bits, each a sorted run of 32-bit
  lows (12.6 MB for the lows plus a 262 KB bucket table), and looks words up by
  binary search. The hash function in Swift and in `scripts/build_ru_forms.py`
  must stay identical.

The public `LayoutDictionary` API (`contains`, `hasWordOneInsertionAway`, …) is
unchanged. English is still a gzipped word list loaded into a `Set<String>`.

### Typo tier uses a smaller list

`hasWordOneInsertionAway` probes about 224 candidate insertions per call. With
the complete form list that finds a "real word" for far too many non-words:
correctly typed English words made wrongly switchable rose from 0.0115% to
0.0693% (6×). So the typo tier probes `ru-typo.bin`, which holds only the old
frequency-ranked core, the short words and the inflected supplement (205,087
forms). Exact matches use the full list. The English-side typo tier is
unchanged.

## How the English list and the Russian core are built

`scripts/build_dictionaries.sh` regenerates all three resources. It first builds
the English list and the Russian core by intersecting a spellcheck word list
with an OpenSubtitles frequency list, keeping the top N by frequency, then
merging the curated additions in `dictionaries/`. Then `scripts/build_ru_forms.py`
expands the OpenCorpora forms, merges the core and the inflected supplement,
filters, and writes the two `.bin` files.

| | English | Russian core |
| --- | --- | --- |
| Word list | [`dwyl/english-words`](https://github.com/dwyl/english-words) | [`danakt/russian-words`](https://github.com/danakt/russian-words) |
| Frequency | [`hermitdave/FrequencyWords`](https://github.com/hermitdave/FrequencyWords) 2018 en | same, ru |
| Kept | 140,000 | 200,000 |

Downloads and the Python virtualenv (pinned `pymorphy3==2.0.6`,
`pymorphy3-dicts-ru==2.4.417150.4580142`) live in `build/dict-cache/`, which is
gitignored; only the three compact resources are tracked. The cache also gets
`ru-forms.txt.gz` (the full plain-text form list, used by the test sweeps) and
`ru-core.txt`. A rebuild takes about a minute and is deterministic. `REFRESH=1`
re-downloads the sources.

The raw Russian word list is not used directly because it is unordered; the
frequency ranking makes its cut principled. It now only supplies the core that
feeds the typo tier and the short-word policy.

## Full morphology: before and after

`./tests/run.sh`, old 200,189-form list vs the 3,145,518-form list.

| Check | Before | After |
| --- | --- | --- |
| EN words falsely recognised as RU-on-wrong-layout | 0 / 137,354 | 0 / 137,354 |
| RU words falsely recognised | 0 / 200,189 | 0 / 3,145,518 |
| Phrases, Russian typed on EN layout | 47/47 | 47/47 |
| Phrases, English typed on RU layout | 34/34 | 34/34 |
| Typo tier, correct EN words made switchable | 15 / 129,879 = 0.0115% | 13 / 129,879 = 0.0100% |
| Typo tier, correct RU words made switchable | 33 / 193,955 = 0.0170% | 5 / 195,817 = 0.0026% (every 16th form; `BABBLER_FULL_SWEEP=1` for all) |
| Out-of-vocabulary English typed correctly, misfires | 32 / 232,480 = 0.0138% | 32 / 232,480 = 0.0138% |
| 19 inflected forms converting from the EN-typed form | 11 / 19 | 19 / 19 |

The inflected-form test (`tests/AutoSwitchTests.swift`) covers the examples
above plus `компаниями`, `написанного`, `сделаешь`, `красивейших`, `пошёл` and
`пошел`; each is checked for the switch, the convert-back and being kept when
typed in Russian. `BABBLER_RU_LIST=path.txt.gz` runs the suite against an
alternative plain word list for comparisons.

## Audit results

Measured against the shipped lists.

### What a gap actually costs

A missing word is **not** a correctness bug. The engine acts only when a word is
absent from the current layout *and* present in the other. So:

- A missing word **typed correctly** is left alone — verified across all 42 gap
  words found in the first audit: **zero** were corrupted.
- A missing word **typed in the wrong layout** simply is not fixed. A missed
  correction, not damage.

This asymmetry is the whole reason the engine is safe to ship.

### Coverage by category

The first audit (before the curated supplements) found core language coverage
was already excellent and the gaps were entirely modern vocabulary:

| Category | Before | After |
| --- | --- | --- |
| RU verbs and inflections | 100% | 100% |
| RU everyday nouns | 90% | 100% |
| RU names and places | 100% | 100% |
| RU slang / internet | 50% | 100% |
| RU business / tech | 33% | 100% |
| RU profanity | 80% | 100% |
| EN UK spellings (colour, organise, centre…) | 100% | 100% |
| EN US spellings (color, organize, center…) | 100% | 100% |
| EN UK-only vocab (lorry, quid, chuffed…) | 95% | 100% |
| EN US-only vocab (truck, bucks, sidewalk…) | 100% | 100% |
| EN slang / internet | 70% | 100% |
| EN profanity | 100% | 100% |
| EN tech | 45% | 100% |

Both UK and US spellings are present in full — the source list is not
regionalised, so `colour`/`color` and `organise`/`organize` all resolve. English
profanity was fully covered from the start; Russian profanity needed only the
softer euphemisms (`задолбал`, `охренеть`) added.

The subtitle-derived frequency lists are the reason tech and internet vocabulary
was weak: film dialogue from before 2018 contains very little `kubernetes` or
`бэклог`. That is exactly what `dictionaries/supplement-*.txt` fixes.

### Accuracy

Numbers from the first audit, with the old 200 k Russian list. Current numbers
are in "Full morphology: before and after" below.

| Metric | Result |
| --- | --- |
| False positives, 338,925 in-dictionary words | **0** |
| False positives, 231,351 out-of-vocabulary English words | **12 (0.005%)** |
| Recall, Russian typed on EN layout (top 20 k) | **99.7%** |
| Recall, English typed on RU layout (top 20 k) | **99.6%** |

The 12 out-of-vocabulary misfires are obscure three-letter entries (`bde`,
`jnd`, `pfg`). Realistic non-words — `kubernetes`, `nginx`, `qwerty`, `asdf`,
`github`, `recieve`, `teh` — are all left alone.

### Short words and phrase correction

A word of one or two characters is never judged on its own. That is measured,
not cautious:

| Word length | Share of words in one layout that are also a valid word in the other |
| --- | --- |
| 2 | **46%** |
| 3 | **6%** |

But refusing to touch them is not acceptable either — `я не могу` is `z yt vjue`
and fixing only `могу` is barely worth having. So short words are corrected
**with context instead of in isolation**: once a word of three characters or
more switches confidently, that correction sweeps backwards over the words
immediately before it, rewriting any that clearly belong to the other layout.
The sweep stops at the first word that is already valid where it stands, so a
genuinely mixed-language phrase is left alone.

Measured on whole phrases, typing the entire phrase on the wrong layout:

| | Before phrase correction | After |
| --- | --- | --- |
| Russian typed on the EN layout | 80% | **100%** |
| English typed on the RU layout | 90% | **100%** |

### The tokenizer is not the engine

`AutoSwitchEngine` decides whether a *word* should switch. Something else has to
decide where words begin and end, and that split lives in `AppDelegate`. The two
are easy to confuse and were the source of the worst bug so far.

Only layout-independent keys — space, tab, enter, return — end a word.
Punctuation must never be treated as a terminator, because on the English layout
those keys carry Russian letters:

| Key | Russian letter |
| --- | --- |
| `,` | б |
| `.` | ю |
| `;` | ж |
| `'` | э |
| `[` `]` | х ъ |

While `. , ; :` were terminators, `,bpytc` (бизнес) was cut at the leading comma
into `""` + `bpytc` → `изнес`, which matches nothing. The same broke every word
containing б, ю or ж anywhere: `hf,jnftn` → `ра` + `отает`, `vj;yj` → `мо` + `но`.
**26.3% of the Russian dictionary — 52,576 of 200,189 words — could never be
corrected.**

Nothing is lost by waiting for the space. A word followed by real punctuation is
judged when the space arrives, and the trailing-punctuation rule tells `it.`
from `ndj.` at that point.

Every test written before this bug called `AutoSwitchEngine.evaluate` directly
with whole words, so the tokenizer had no coverage at all. `tests/run.sh` now
drives the split as well as the decision; run it after any change to word
boundaries or character classes.

### Known limitation: a trailing Russian full stop

A Russian sentence ending in a full stop, typed on the English layout, produces
`ghbdtn/` — the Russian period lives on the `/` key. `/` signals paths and URLs
and is rejected, so the word is left alone. Fixing it means correcting only part
of a keystroke run, which is a larger change than it appears.

### Why the short end of the dictionary is hand-written

Words of one and two letters come exclusively from `dictionaries/short-en.txt`
and `short-ru.txt`. Generated lists contribute nothing below three letters, and
generated three-letter words must rank inside the top 30,000 by frequency.

This is not tidiness. A bogus short entry does real damage:

- `at.` was rewritten as `фею` because the subtitle corpus lists `dc`, `lf`,
  `bk`, `cb` and `ct` as English words, which broke the "is this punctuation or
  a Russian letter?" test.
- `где` stayed broken because `ult` — an obscure abbreviation ranked 214,770 —
  looked like a real English word, which stopped the backward sweep dead and
  left the whole phrase uncorrected.

Both were found in real use, not in theory.

## Typo tolerance

`ghdtn` converts to `првет` — Russian by any reading, but not a word, so exact
matching does nothing. Every typo used to silently disable the feature for that
word.

### Why naive fuzzy matching was rejected

Allowing any edit of distance one raises the false-positive rate from 0.025% to
**4.01% — 160× worse**. `learn` matched `дукат`, `rate` matched `кафе`, `tuff`
matched `бега`. It would corrupt correctly typed English constantly.

Modelling how people actually mistype, rather than allowing arbitrary edits,
behaves completely differently. Measured over 40,000 correctly typed English
words:

| Rule | Extra false positives | Typo recall |
| --- | --- | --- |
| Any edit of distance 1 | 4.01% | — |
| omit + transpose + double | 0.033% | 7/7 |
| omit + transpose | 0.022% | 7/7 |
| **omit only** | **0.010%** | **7/7** |
| transpose only | 0.013% | 4/7 |

A dropped keystroke carries essentially all the benefit. Transposition adds no
recall, and the doubled-letter rule is actively harmful because English is full
of `ff`, `ee` and `ll` — `cuffy`, `beele`, `heels` and `ettle` were all false
positives under it.

Full-dictionary sweep with omission only:

| Metric | Result |
| --- | --- |
| Correct EN words made wrongly switchable | 15 / 129,879 = **0.0115%** |
| Correct RU words made wrongly switchable | 33 / 193,955 = **0.0170%** |
| RU recall, one dropped key | **100%** |
| EN recall, one dropped key | **100%** |

Two extra guards, both measured: a minimum length of five characters, and the
reconstructed word must start with the same character the user typed. Typos
essentially never hit the first key, and requiring it lowered false positives.

### Common-word lists for vowel, doubled-letter and swap typos

Three extra typo classes are checked against two shipped lists,
`common-en.txt.gz` and `common-ru.txt.gz`: the top 5000 words of each frequency
list, built by `scripts/build_common_words.py` from the same ranking the typo
tests use. A converted word matches when one vowel substitution (RU о↔а, е↔и,
е↔я, и↔ы; EN a/e/i/o/u pairs), one doubled letter removed, or one adjacent
transposition yields a word in the list. Guards: vowel substitution needs length
≥4, doubled letter length ≥4, transposition length ≥5. Measured false positives
on the EN and RU top-20k lists, proper nouns and EN collisions: 0 with these
guards.

### The spelling is never corrected

The typo match decides *whether* to switch. It never builds the replacement.

Type `ghdtn` and you get `првет` — the layout is fixed, the typo is yours to
fix. Correcting the layout repairs an encoding error; correcting the spelling
would silently rewrite what you wrote, which is a different and much riskier
product decision. Punto Switcher draws the line in the same place.

This also removes a whole class of problem. 13.6% of typos have more than one
candidate word, but since we only ask "is at least one real word one keystroke
away?" and never "which one?", ambiguity costs nothing. No frequency data, no
ranking, no tie-breaking.

For the same reason a typo match may not anchor a backward phrase sweep. It is a
weaker signal, and letting it drag neighbouring words in would multiply an error
instead of containing it.

### No index, no extra memory

A deletion index over the dictionary would hold roughly 1.6M entries. It is
unnecessary: `w` is a word of which `q` is a one-character deletion exactly when
some single-character insertion into `q` equals `w`. So the insertions of the
query are generated and probed against the set that already exists — about 224
hash lookups.

Measured on the real decision path: **0.19 ms** in the worst case (a long
non-word, every tier runs and the typo search explores its whole space) and
**0.001 ms** typically (a real word, decided immediately). This runs once per
space keystroke.

## Learning from rejected corrections

A word rejected three times is never corrected again. What counts as a rejection
is the whole design problem.

### Which gestures count

| Gesture | Meaning | Counts |
| --- | --- | --- |
| Action key straight after a correction | An explicit undo | **Yes**, immediately |
| Layout switched back, text left alone | The text was right as typed; we were wrong | **Yes** |
| Layout switched back **and the text edited** | The user is fixing their own mistake | **No** |

The third row is the important one. If the user reverts the layout and then
reworks the text, that is evidence about *their* typing, not about our decision.
Counting it would let a user's own typos accumulate against words we handle
correctly.

Because the edit can arrive either before or after the revert, **a revert cannot
be counted when it happens**. It arms a suspicion for three seconds, and a
Delete arriving in that window cancels it. An edit that arrives before the
revert marks the correction as already reworked, so a later revert cannot
resurrect it.

Delete is the marker because text cannot be retyped without first removing what
is there. Typing the next word is not an edit.

### Why it did not work before

The mechanism existed but was effectively dead:

- **Counts lived only in memory**, so they reset on every restart. Real
  rejections are spread across days, which made any threshold unreachable. This
  was the main failure.
- **Only the action key counted.** A manual layout revert was ignored.
- **The list was invisible and permanent.** A `"it."` entry from a bug fixed back
  in v1.3 was still blocking that word long after the engine stopped needing it.

That last point is why the learned list is now shown in Settings with a Forget
button, and why entries expire after 90 days without reinforcement. Learned
state that outlives the bug it was learned from is worse than no learning.

### Storage

`autoSwitchRejections` maps each word to a count and the date it was last
reinforced. The legacy `autoSwitchIgnoredWords` list is migrated once into the
new format as entries already at the threshold, and is deliberately left in place
so downgrading does not lose it. The store is capped at 500 entries, evicting the
least recently seen.

The unit is the **anchor word as typed**, not the phrase. A phrase correction
only ever begins at an anchor — the backward sweep over short words runs after
the anchor fires — so blocking the anchor blocks the phrase too. That is both
more precise and more compact than storing phrases.

### Testing

The state machine lives in `AutoSwitchMemory`, deliberately free of AppKit,
timers and clocks: every input is an explicit event with an explicit timestamp.
This is a direct response to the v1.4 bug, which happened because logic of
exactly this kind sat in `AppDelegate` where no test could reach it. `tests/run.sh`
drives ten scenarios against an in-memory store, and they were verified to fail
when the rules are deliberately broken.

## Extending the dictionaries

Four routes, cheapest first.

### 1. Your own words — no rebuild

Drop a plain text file, one lowercase word per line, `#` for comments:

```
~/Library/Application Support/Babbler/custom-en.txt
~/Library/Application Support/Babbler/custom-ru.txt
```

They are merged into the bundled lists at load time. Restart Babbler to pick up
changes. Best for names, company jargon, project codenames — anything personal
that does not belong in the repo.

### 2. Curated supplements — shipped to everyone

Edit `dictionaries/supplement-en.txt` or `supplement-ru.txt` (for Russian, list
lemmas: the forms are generated), then:

```sh
./scripts/build_dictionaries.sh
./scripts/install.sh
```

This is where the tech and internet vocabulary above came from. Use it for
anything a typical user would benefit from.

### 3. Raise the frequency budget

```sh
EN_LIMIT=200000 ./scripts/build_dictionaries.sh
```

English only: the Russian budget now sizes the core used by the typo tier, and
the exact tier already holds every form. Every word added to English slightly
raises the out-of-vocabulary misfire rate; re-run `./tests/run.sh`.

### 4. Better sources

- **Wiktionary dumps** for both languages, useful for neologisms and slang that
  the 2018 subtitle corpus predates.
- **Hunspell English** with affix expansion, if English ever needs the same
  full-morphology treatment. `HashedWordSet` can store it unchanged.
- **Regional lists** if UK/US divergence ever matters more than it does today —
  currently both are fully covered, so this is not worth doing.

## Theme packs

Five optional Russian vocabularies bundled as `Babbler/Resources/pack-<id>.txt.gz`:
`it` (IT slang), `business`, `gaming`, `slang`, `mat`. A pack hit counts as an
exact Russian match. Toggled in Settings → «Тематические словари» (shown when auto-switch is on); stored under `enabledThemePacks` (array of ids, absent = all on).

Lemma sources are `scripts/packs/<id>.txt` (one lemma per line, `#` comments).
Forms are generated by a rule-based inflector in `scripts/build_theme_packs.py`
and filtered: forms whose EN-layout keystrokes are an English word, and forms
shorter than 2 letters, are dropped. Rebuild with:

```sh
./scripts/build_dictionaries.sh
./tests/packs_test.sh
```

## User lexicon

Separate from the rejection memory above: instead of learning *not to switch* a
specific word, the user lexicon learns that a word is a real word in whatever
layout the user keeps typing it in — useful for names, jargon and code identifiers
that will never make it into the shared dictionaries.

A word is **kept** once auto-switch looks at it and leaves it alone (it did not
qualify for a switch), or once a switch is undone (the original layout was
right). After the same word is kept twice (`promoteThreshold`), it is promoted
into the learned set and from then on:

- a lexicon hit in the layout the user is **currently** typing in behaves like an
  existing dictionary word — auto-switch leaves it alone;
- a lexicon hit in the **other** layout is treated as an exact match, the same
  tier as a theme-pack or dictionary hit, and also qualifies for the backward
  phrase sweep.

Only words of 2+ letters with no digits or punctuation are considered, and
words already present in the built-in EN/RU dictionaries are never stored —
there is no point learning what the engine already knows. The learned set is
capped at 5000 entries, oldest evicted first, and persisted under
`userLexiconKeeps`/`userLexiconLearned`.

At startup, `~/Library/Spelling/LocalDictionary` (macOS's own per-user spelling
additions) is imported once: Cyrillic-only entries are learned as Russian,
Latin-only entries as English. Toggle in Settings → «Запоминать мои слова»
(shown when auto-switch is on), with a learned-word count and a reset button;
the preference key is `userLexiconEnabled` (default on).

The engine never references `UserLexicon` directly — like theme packs, it
only holds a closure (`AutoSwitchEngine.userLexiconContains`) so that
`AutoSwitchEngine.swift` compiles standalone without the lexicon present.

### Learning from manual swaps

The opposite signal: a word the user manually swaps with the action key twice
(`noteManualSwap`, promoted at the same `promoteThreshold`) is **forced** —
from then on, typing it in the layout it was swapped out of is always treated
as an exact match for the other layout, overriding even a word that is
correctly spelled where it stands. A keep and a force contradict each other,
so noting one cancels any pending or learned entry for the other signal on
the same word and layout. Undoing the auto-switch that a forced word then
causes removes the force (`dropForcedSwitch`), so the same mistake does not
keep re-forcing itself. Persisted under `userLexiconForcedPending`/
`userLexiconForced`, capped and evicted the same way as the keep set, and
wired into the engine through a second closure,
`AutoSwitchEngine.userLexiconForces`. Settings shows the count alongside the
learned-word count, and Reset clears both.

## Character n-gram language model (last tier)

A lookup can never judge a word it has not seen: derived, colloquial and nonce
words (`жопецкий`, `бизнесяка`, `кринжовый`) and brand names (`kubernetes`) are
in no list. So the engine's last tier is a character n-gram model per language,
used only when the exact and typo tiers both found nothing.

**Design.**

- Order 4 over letters plus a word-boundary symbol; interpolated Kneser-Ney with
  one Ney-Essen discount per order. RU alphabet is `а`-`я` (`ё` folded to `е`),
  EN is `a`-`z`.
- Training data: RU = every OpenCorpora form (3,015,710 words incl.
  `supplement-ru`), EN = `words_alpha` + `en.txt.gz` + `supplement-en` (369,728).
- Format (`BNGM`): header + raw-deflate dense table of `V^4` bytes, each
  `round(-ln p * 16)` clamped to 255. Sizes: `ngram-ru.bin` 952,727 B,
  `ngram-en.bin` 323,681 B (1.25 MB total). Load 8-33 ms, +0.1 MB resident,
  scoring about 3.6 µs per word.
- Decision for a token typed in layout A whose conversion is in layout B, after
  the usual eligibility checks and `looksLikeCodeOrAddress`:
  `plausibility = logP_B(converted)/(len+1)`,
  `margin = plausibility - logP_A(typed)/(len+1)`.
  Switch iff the converted word has at least 4 letters, `margin >= threshold(len)`
  and `plausibility >= floor(B)`.
  - thresholds by length: 4 → 2.5, 5 → 2.0, 6-7 → 1.5, 8+ → 1.25
  - floors: -4.5 when B is Russian, -3.5 when B is English
  - the A model scores the typed string as is; punctuation keys inside or at
    the start of an English-typed token are out-of-alphabet (12 nat penalty),
    trailing `, . ; '` is stripped first.
- A language-model match never counts as an exact match, so it cannot anchor
  the short-word phrase sweep, and learned rejections (`AutoSwitchMemory`)
  apply as for every other tier.

**Results** (`./tests/run.sh`):

| Check | Result |
| --- | --- |
| Colloquial RU typed on EN (115 words, none in dictionary) | 104/115 = 90.4% (honest, held-out models) |
| Same words typed correctly | 0/115 switched |
| Held-out RU forms (296,176, never trained on): recall / FP | 98.97% / 0 |
| Held-out EN words (36,315): recall / FP | 98.46% / 0 |
| English words outside the shipped list typed correctly (231,286) | 0 FP |
| 233 brand/tech names typed correctly | 0 FP |
| Brands outside the dictionary typed on RU layout (141) | 78.0% |
| Frequent RU / EN unknowns typed correctly | 0.074% / 0.009% FP |

Threshold shift trade-off (added to every threshold; 0 is shipped):

| Shift | Colloq. recall | Held-out RU | Held-out EN | Brands | FP held-out RU / EN | FP unknown RU / EN |
| --- | --- | --- | --- | --- | --- | --- |
| -1.0 | 93.9% | 99.7% | 99.0% | 76.6% | 0.0030% / 0.0055% | 0.167% / 0.044% |
| -0.5 | 93.0% | 99.5% | 98.8% | 76.6% | 0.0007% / 0 | 0.093% / 0.023% |
| 0 | 89.6% | 99.0% | 98.5% | 75.2% | 0 / 0 | 0.060% / 0.009% |
| +0.5 | 83.5% | 97.9% | 97.7% | 73.8% | 0 / 0 | 0.046% / 0.003% |
| +1.0 | 76.5% | 95.2% | 95.9% | 71.6% | 0 / 0 | 0.014% / 0.002% |
| +1.5 | 59.1% | 89.4% | 92.2% | 60.3% | 0 / 0 | 0 / 0 |

(Table figures use the held-out models; shipped models score slightly higher
on words they trained on.) Most frequent-unknown "false positives" are OCR-like
junk in the frequency list (`куинн`, `лнфер`).

**Retraining.** `./scripts/build_dictionaries.sh` trains both pairs (needs
`numpy`, installed in `build/dict-cache/venv`). By hand:

```
build/dict-cache/venv/bin/python scripts/build_ngram_models.py            # shipped, to Babbler/Resources
build/dict-cache/venv/bin/python scripts/build_ngram_models.py --holdout 0.1 \
  --output build/dict-cache/ngram-holdout                                  # honest-evaluation models
```

The holdout leaves out 10% of RU lemmas and 10% of EN words (by hash); the
test run scores them with models that never saw them. Colloquial and brand test
lists live in `tests/data/`.

## System spell checker (fallback tier, veto-only)

A dictionary and the n-gram model both still miss recent loanwords, proper
nouns and brand names no list has caught up with. `Babbler/SpellOracle.swift`
wraps `NSSpellChecker` (the same local, in-process/XPC service every Cocoa text
view already uses — no new entitlement or permission) as a `SpellOracle`
protocol, injected into `AutoSwitchEngine` so tests can substitute a
deterministic fake. It sits right before the n-gram tier, in two independent
halves:

- **Veto** (always on once an oracle is wired): if the typed word is already
  known to the system speller where it stands, the n-gram tier below is
  suppressed — a word the speller recognises is not the n-gram model's to
  second-guess.
- **Confirm** (`AutoSwitchEngine.spellCheckerConfirmEnabled`, gated separately):
  if the typed word is *not* known to the speller, is >= 4 letters, and its
  conversion *is* known to the speller in the target language, switch through
  the new `.spellChecker` tier.

**Measured trade-off** (`BABBLER_SPELL_ORACLE=1` wires the real speller into
`tests/run.sh`, `en_back_test.sh`, `corpus_probe.sh`, `en_probe.sh`; `=veto`
wires it with the confirm half disabled):

| Suite | Baseline (off) | Veto only | Confirm + veto |
| --- | --- | --- | --- |
| 231,286 out-of-vocabulary EN words, FP | 0 | 0 | 7 (0.0030%: `yelm`, `lysogens`, `multiperforate`, ...) |
| Colloquial RU recall (115 words) | 104/115 | 104/115 | 107/115 |
| Brands typed on RU layout (141 words) | 110/141 | 110/141 | 112/141 |
| Pikabu corpus: correct / FP | 98.3% / 3 | 98.3% / 3 | 98.4% / 3 |
| Habr corpus: correct / FP | 96.9% / 0 | 96.9% / 0 | 96.9% / 0 |

The 7 confirm-tier false positives are genuine rare English words (`otaria`,
`nonreimbursement`...) that `NSSpellChecker`'s own English dictionary does not
know, whose layout-converted Cyrillic gibberish its Russian dictionary
*does* recognise as a valid inflected form — a structural risk of trusting a
third-party dictionary as a confirm signal, not a bug in the gating logic. The
veto half never introduces a new switch, so it cannot cause this kind of
regression; it measured zero FP change on every suite.

**Shipped behaviour:** `AppDelegate.finishApplicationSetup()` wires the real
oracle but sets `spellCheckerConfirmEnabled = false`, so the app ships
veto-only. The confirm half (`.spellChecker` tier) stays fully implemented and
covered by `tests/SpellTests.swift` / `tests/spell_test.sh` with a fake oracle,
available behind the flag for future revisiting, but is off by default because
its measured recall gain did not clear its FP cost.

## Memory and load time

Loading happens once, on a background queue, on first use. Until it completes
every lookup returns `false`, so the engine declines to act rather than guess.

Measured on the development Mac (Apple Silicon, `-O`, English list included):

| Design | Load | Resident growth |
| --- | --- | --- |
| Old: `Set<String>` of the 200 k core + English | 135-174 ms | +44 MB |
| New: `ru-forms.bin` + `ru-typo.bin` + English | 57-58 ms | +26 MB |
| For comparison: `Set<String>` of all 3.1 M forms + English | 2,644 ms | +428 MB |

The new design is both faster and smaller than the old one despite holding 15×
as many words, because the old path inflated gzipped text and built strings for
every word. Lookups are a bucket index plus a binary search.
