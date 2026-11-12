# MacCleaner

A Mac app for reviewing and removing large, duplicate and unneeded files. Open-source tools do the scanning; MacCleaner shows what they find and moves what you check to the Trash.

| Pane | Finds | Engine |
| --- | --- | --- |
| Junk | caches, logs, developer leftovers, files from removed apps | [Mole](https://github.com/tw93/Mole) `mo clean --dry-run` |
| Large Files | every file over a size you pick, with when you last opened it | [fd](https://github.com/sharkdp/fd) |
| Duplicates | files with identical contents | [fclones](https://github.com/pkolaczk/fclones) |
| Space | folder sizes, drill down by double-clicking | Mole `mo analyze --json` |

## Install

```bash
brew install mole fd fclones
```

```bash
./scripts/build-app.sh --install
```

That builds `build/MacCleaner.app`, signs it ad hoc and copies it to `/Applications`.

## How removal works

- Check items, then **Move to Trash…**. A sheet lists every item and the total before anything moves.
- Everything goes to the macOS Trash, so it can be put back from the Finder. Space is freed only when you click **Empty…** next to the Trash in the sidebar, which asks first.
- Every removal is logged to `~/Library/Logs/MacCleaner/removals.log` (date, bytes, original path, where it went in the Trash).
- Mole is only ever run in preview mode. Its own deletion commands are never used.

Things MacCleaner refuses to remove, whatever a scanner reports (`Sources/MacCleanerCore/SafetyPolicy.swift`):

- anything outside your home folder, the home folder itself and its standard folders (Desktop, Documents, Downloads, Library and so on)
- `~/Library/<folder>` itself, keychains, iCloud Drive, CloudStorage (Dropbox, Google Drive), Mail, Messages, Safari data
- `.ssh`, `.gnupg`, `.aws`, `.kube`, `.git` folders
- Photos, Music, TV, iMovie, Final Cut and Logic libraries, and anything inside an app bundle
- the last copy of a duplicated file

## Permissions

- **Full Disk Access** (optional): macOS hides the Trash's size from apps without it, and Mole sees a few more caches with it. System Settings > Privacy & Security > Full Disk Access. With an ad-hoc signature the grant has to be redone after each rebuild.
- **Automation > Finder**: asked the first time you empty the Trash, because MacCleaner asks the Finder to do it.

## Development

```bash
swift test
```

The live checks run each engine against this Mac, read-only:

```bash
MACCLEANER_LIVE=1 swift test --filter LiveEngineTests
```

Mole is GPL-3.0 and runs as a separate program; none of its code is in this repository.
