# Installing Babbler

## Quick install (build from source)

```sh
./scripts/install.sh
```

Builds Release with ad-hoc signing, replaces `/Applications/Babbler.app`, and
relaunches.

## Build and distribute a DMG

To create a distributable DMG for another Mac:

```sh
./scripts/make_dmg.sh [VERSION]
```

This produces `dist/Babbler-<VERSION>.dmg` containing:
- `Babbler.app` (ad-hoc signed, ready to drag)
- `Applications/` symlink
- `README.txt` (installation instructions in English & Russian)

Share the DMG, and the recipient unpacks by dragging `Babbler.app` into their
`Applications` folder. The included README.txt walks through permissions and
the Gatekeeper workaround.

## Install a prebuilt archive on another Mac

```sh
unzip Babbler-v1.0-stable.zip
xattr -dr com.apple.quarantine Babbler.app     # ad-hoc signed, not notarised
cp -R Babbler.app /Applications/
open /Applications/Babbler.app
```

### Установка на другой Mac через DMG

Получите DMG от создателя (см. выше), затем:

1. Откройте DMG двойным щелчком
2. Перетащите `Babbler.app` в папку `Applications`
3. Закройте окно DMG и выньте его (правый клик → Eject)
4. Откройте `System Settings` → `Privacy & Security`
5. Добавьте Babbler в `Accessibility` и `Input Monitoring` (см. ниже)
6. Запустите `/Applications/Babbler.app`

## Permissions — both are required

Babbler needs **two separate** grants in
System Settings → Privacy & Security. Granting only one leaves the app in a
confusing half-working state.

| Permission | Needed for | Symptom if missing |
| --- | --- | --- |
| **Input Monitoring** | Seeing which keys you type (`NSEvent` global `.keyDown` monitor) | Action key flips the layout, and swapping *selected* text works, but the last typed **word** is never swapped |
| **Accessibility** | Posting the synthetic keystrokes that rewrite the text | Nothing is replaced at all |

The app prompts for whichever is missing on launch.

### After every rebuild — re-grant both

The project is signed **ad hoc** (`CODE_SIGN_IDENTITY="-"`), because the
original team certificate `S6G53UGWX8` is not available. Every build produces a
different code signature, and macOS ties TCC grants to the signature. An
existing grant therefore goes stale and silently stops working even though the
checkbox still looks ticked.

After each reinstall, in **both** Input Monitoring and Accessibility:

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
