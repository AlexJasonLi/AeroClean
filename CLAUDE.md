# MacCleaner project rules

## What the app is (set by Ali, 2026-11-11)

- MacCleaner is a file cleaner and only removes. It never renames, moves elsewhere, compresses or edits files. Review features (Quick Look, Reveal in Finder, copy path) are read-only.
- Removal always goes to the macOS Trash first. Space is freed only by the separate Empty Trash action, which asks for confirmation and shows what it will free.
- Native SwiftUI Mac app, source in `~/MacCleaner`.

## Engines

- Public open-source tools do the scanning: Mole (`mo`, GPL-3.0) for the junk preview and folder sizes, fclones (MIT) for duplicates, fd (MIT/Apache-2.0) for large files. All three come from Homebrew.
- They run as separate processes. Do not copy Mole source into this repo; that would put the app under the GPL.
- Mole's own deletion commands (`mo clean` without `--dry-run`, `mo purge`, `mo installer`) are never run. Mole decides what is safe; MacCleaner moves the chosen items to the Trash itself.

## Removal invariants

- Every removal goes through `Trasher`, which checks `SafetyPolicy` first. No other code calls `trashItem` or `removeItem` on user files.
- Only paths strictly inside the home folder. Never the home folder, its standard top-level folders, `~/Library` subfolders themselves, the Trash, keychains, iCloud Drive / CloudStorage, Mail, Messages, credentials folders, `.git` data, media libraries, or anything inside an app bundle or media library.
- A duplicate group always keeps at least one copy.
- Every removal is logged to `~/Library/Logs/MacCleaner/removals.log` with its Trash location, so it can be put back.
