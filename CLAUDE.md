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
- Only paths strictly inside the home folder. Never the home folder, its standard top-level folders, `~/Library` subfolders themselves, the Trash, keychains, iCloud Drive / CloudStorage, Mail, Messages, Safari data, credentials (`.ssh`, `.aws`, `.docker`, `.netrc`, `.config/gh` and the rest of `credentialPaths`), media libraries and catalogs, or anything inside an app bundle or media library.
- A folder that holds a media library is refused as a whole. A folder that holds a git repository may go (an old project is real cleanup), but the confirmation sheet says so. A `.git` folder on its own is never removed.
- A duplicate is removed only while another copy of it, same size, is still on disk and not part of the same removal. The check runs at removal time, so copies removed from another pane or the Finder count.
- After a removal, every pane drops what moved, including items inside removed folders.
- Every removal is logged to `~/Library/Logs/MacCleaner/removals.log` with its Trash location, so it can be put back.
- Tools run in their own process group; Stop and quitting the app kill the whole group.
