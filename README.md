# MacCleaner

A Mac app for finding and removing large, duplicate and unneeded files, and for seeing what macOS calls "System Data". Everything you remove goes to the Trash first.

| Pane | Shows | Engine |
| --- | --- | --- |
| Junk | caches, logs, developer leftovers, files from removed apps | [Mole](https://github.com/tw93/Mole) `mo clean --dry-run` |
| Large | every file over a size you pick | disk index |
| Copies | files with identical contents | disk index + [fclones](https://github.com/pkolaczk/fclones) |
| Space | folder sizes, double-click to go inside | disk index |
| System | swap, startup volumes, app data, caches, temporary files, simulators, hidden folders | disk index + diskutil |

## What counts as junk

Mole proposes candidates; MacCleaner keeps only what its own rules (`Sources/MacCleanerCore/JunkRules.swift`) can vouch for, grouped by why it is safe:

| Group | Why removing it changes nothing |
| --- | --- |
| App caches | apps rebuild them on their own (`~/Library/Caches`, cache folders inside apps) |
| Download caches | package managers and updaters fetch them again only if needed |
| Logs and crash reports | nothing reads them to run |
| Build caches | rebuilt on the next build (`__pycache__`, `.next/cache`, Xcode DerivedData) |
| Temporary files | scratch files in apps' `tmp` folders |
| Leftovers | saved state of apps no longer installed |
| Old extensions | versions Cursor marked obsolete or replaced |

Anything else Mole lists is left out and shown read-only with the reason, for example a simulator's own system assets or Chrome's website data. When you move junk to the Trash, each item is checked again: it must still match a rule, its app must not be running, and it must not have changed in the last five minutes.

## The disk index

One scan sizes every folder in your home folder plus `/Library`, your `/var/folders` temp folders, `/private/var/log` and `/System/Library/AssetsV2`, and lists every file over 1 MB. All panes except Junk read it, so moving between them is instant. The last index is saved in `~/Library/Caches/local.maccleaner/` and shown at launch while a fresh scan runs.

The scanner calls `getattrlistbulk` from 16 threads: one system call returns a whole batch of entries with their sizes. This is the approach of [healeycodes/dumac](https://github.com/healeycodes/dumac); that repository has no license, so the code here is written from the system call's documentation. Measured on a home folder of 2.58 million files and 230 GB, with a warm disk cache:

| Tool | Time |
| --- | --- |
| MacCleaner index | 11-12 s |
| gdu, totals only | 23.9 s |
| gdu, full JSON | 49.4 s |
| du -sk | 70 s |
| pdu | 133 s |
| dust | 232 s |
| dua | 235 s |

Copies hands fclones only files whose length matches another file's, so it hashes a few dozen files instead of walking the disk.

## Install

```bash
brew install mole fclones
```

```bash
./scripts/build-app.sh --install
```

## How removal works

- Check items, then **Move**. A sheet lists every item and the total before anything moves.
- Everything goes to the macOS Trash. Space is freed only when you click **Empty**, which asks first.
- Every removal is logged to `~/Library/Logs/MacCleaner/removals.log` (date, bytes, original path, where it went in the Trash).
- Items that belong to an app that is running are refused with "Quit <app> first".
- Mole is only ever run in preview mode.

MacCleaner refuses, whatever a scanner reports (`Sources/MacCleanerCore/SafetyPolicy.swift`):

- anything outside your home folder and your own `/var/folders` temp folders (T and X); the home folder itself and its standard folders
- `~/Library/<folder>` itself, keychains, iCloud Drive, CloudStorage, Mail, Messages, Safari data
- credentials (`.ssh`, `.gnupg`, `.aws`, `.docker`, `.netrc`, `.config/gh` and others) and `.git` folders (a whole project folder can go; the sheet says when it holds git history)
- Photos, Music, TV, iMovie, Final Cut, Logic, GarageBand, Lightroom and Capture One libraries, folders that hold one, and anything inside an app bundle
- the last copy of a duplicated file, checked again at removal time

System items MacCleaner cannot remove (swap, startup and recovery volumes, simulator runtimes, downloaded updates) are listed with how to free them.

## Design

Each pane opens onto its own animated pixel scene: a dandelion hill, a summer ridge, a still pond, valley fields and a dusk meadow. They are drawn in code (`Sources/MacCleanerUI/Pixel`) at a few hundred pixels across with ordered dithering and shown with hard pixel edges. Click a scene to scatter petals. Type is [Departure Mono](https://github.com/rektdeckard/departure-mono) (SIL Open Font License, bundled).

## Permissions

- **Full Disk Access** (optional): lets MacCleaner show the Trash's size and read a few protected folders.
- **Automation > Finder**: asked the first time you empty the Trash.

## Development

```bash
swift test
```

```bash
MACCLEANER_LIVE=1 swift test --filter LiveEngineTests
```

```bash
swift run -c release Snapshots screens /tmp/maccleaner-screens
```

The last command renders every pane with this Mac's data to PNG files, without opening a window.

Mole is GPL-3.0 and runs as a separate program; none of its code is in this repository.
