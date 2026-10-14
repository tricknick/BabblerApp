# Installing Babbler

## Quick install (build from source)

```sh
./scripts/install.sh
```

Builds Release, signs it with the local signing identity, replaces
`/Applications/Babbler.app`, and relaunches.

### One-time signing setup

```sh
./scripts/setup_signing.sh
```

Creates a self-signed code-signing identity, "Babbler Local Signing", in the login
keychain. Run it once per Mac; re-running is harmless. Without it, builds fall back
to ad-hoc signing and macOS drops Accessibility / Input Monitoring grants on every
update. With it, grants persist across updates because the signature stays the same.
On a new Mac, the first install still needs the permissions granted once.

## Build and distribute a DMG

To create a distributable DMG for another Mac:

```sh
./scripts/make_dmg.sh [VERSION]
```

This produces `dist/Babbler-<VERSION>.dmg` containing:
- `Babbler.app` (signed with the local signing identity; see above)
- `Install Babbler.command` — installer for first install **and** updates over an existing copy
- `Applications/` symlink
- `README.txt` (instructions, Russian + English)

`Install Babbler.command` (source: `scripts/dmg_install.command`) quits the running
Babbler, replaces `/Applications/Babbler.app`, clears quarantine, unregisters the
DMG copy from LaunchServices, and launches the new app. It resets the Accessibility /
Input Monitoring grants (`tccutil reset … eugene.Babbler`) only when the code signature
changed (for example, the first update from an ad-hoc build). Updates signed by the same
identity keep their grants. The user then only enables Babbler in both lists and relaunches it.

## Install a prebuilt archive on another Mac

```sh
unzip Babbler-v1.0-stable.zip
xattr -dr com.apple.quarantine Babbler.app     # ad-hoc signed, not notarised
cp -R Babbler.app /Applications/
open /Applications/Babbler.app
```

### Установка / обновление через DMG

1. Откройте DMG.
2. Правый клик по `Install Babbler.command` → Открыть → Открыть
   (macOS 15+: при блокировке — Конфиденциальность и безопасность → «Всё равно открыть»).
3. Скрипт сам закроет старый Babbler, заменит его в `/Applications`, снимет карантин
   и сбросит устаревшие разрешения.
4. Включите Babbler в `Accessibility` и `Input Monitoring`, перезапустите его.

Не запускайте Babbler прямо из DMG или из `build/`: разрешения выдаются копии в
`/Applications`, у других копий своя подпись, и приложение будет бесконечно просить доступ.

## Permissions — both are required

Babbler needs **two separate** grants in
System Settings → Privacy & Security. Granting only one leaves the app in a
confusing half-working state.

| Permission | Needed for | Symptom if missing |
| --- | --- | --- |
| **Input Monitoring** | Seeing which keys you type (`NSEvent` global `.keyDown` monitor) | Action key flips the layout, and swapping *selected* text works, but the last typed **word** is never swapped |
| **Accessibility** | Posting the synthetic keystrokes that rewrite the text | Nothing is replaced at all |

The app prompts for whichever is missing on launch.

### Without the signing identity — re-grant after every rebuild

Builds are signed with the local "Babbler Local Signing" identity (run
`./scripts/setup_signing.sh` once; see above). macOS ties TCC grants to the
code's designated requirement, so grants survive updates signed by the same
identity. If the identity is missing, builds fall back to ad-hoc signing, and
grants must be re-added after each reinstall:

1. Select Babbler
2. Click **–** to remove it
3. Click **+** and add `/Applications/Babbler.app`

Merely unticking and re-ticking is not enough — remove and re-add.

## Verifying it works

1. Switch to the English layout
2. Type `ghbdtn`
3. Press Option

You should get `привет`, with the system layout switched to Russian.
Shift+Option does the same for the whole line.

## Troubleshooting

- **Nothing happens on Option** — check Input Monitoring first; that is the most
  common cause.
- **Only selected text is swapped** — Input Monitoring is missing or stale.
- **App disappears after sleep** — check `~/Library/Application Support/Babbler/Crashes/`.
- **Duplicate icons in Launchpad** — stale Launch Services entries:
  ```sh
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u /path/to/stale/Babbler.app
  ```
