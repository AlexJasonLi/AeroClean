# MacCleaner project rules

## What the app is (set by Ali, 2026-11-11)

- MacCleaner is a file cleaner and only removes. It never renames, moves elsewhere, compresses or edits files. Review features (Quick Look, Reveal in Finder, copy path) are read-only.
- Removal always goes to the macOS Trash first. Space is freed only by the separate Empty Trash action, which asks for confirmation and shows what it will free.
- Native SwiftUI Mac app, source in `~/MacCleaner`.

## Junk must be junk (set by Ali, 2026-11-12)

- Everything in the Junk pane must be removable without affecting anything: rebuilt automatically, downloaded again only if needed, or never read. If MacCleaner cannot vouch for an item, it is not junk.
- `JunkRules` decides; Mole only proposes. Unknown patterns are doubts, never junk. Doubts are shown read-only under "left out" with the reason.
- At removal every junk item is classified again and refused if it no longer matches, if its app is running (`AppOwners` plus bundle id or name), or if it changed in the last five minutes.
- Never junk: simulator system assets, website data (Service Worker), window state of installed apps, histories, credentials, anything outside the home folder.

## Design direction (set by Ali, 2026-11-12)

- Exceptionally clean, old-school, pure design. No text where it is not needed; every feature easy to find and understand.
- Neo Frutiger Aero, pixelized: glossy glass panels and aqua bubbles over animated pixel nature scenes (flower meadows, hills, ponds, skies).
- Scenes evoke the feel of Studio Ghibli backdrops and locations, drawn in a pixel-animation style. Never the Ghibli art style, characters or any recreation of their scenes.
- Reference: Ann Nguyen's interactive pixel portfolio (designeer.xyz/finds/ann-nnng-2114717745443127698): dithered pixel scenes with ragged edges on a calm white card, one-line captions, small interactions.
- Scans must be very fast, and the app must explain macOS "System Data".

## Engines

- The disk index (`FastScanner`, getattrlistbulk on 16 threads) feeds Large, Copies, Space and System. Keep it the only walker of the disk; panes read it, they do not scan.
- Public tools where they win: Mole (`mo`, GPL-3.0) for the junk preview, fclones (MIT) to hash duplicate candidates the index found. Both from Homebrew. gdu, du, dua, pdu, dust and fd were measured and are slower than the index (README has the numbers).
- Tools run as separate processes. Do not copy Mole source into this repo; that would put the app under the GPL.
- Mole's own deletion commands (`mo clean` without `--dry-run`, `mo purge`, `mo installer`) are never run. Mole decides what is safe; MacCleaner moves the chosen items to the Trash itself.
- Design changes are reviewed with `swift run -c release Snapshots screens <folder>`, which renders every pane with real data without a window.

## Removal invariants

- Every removal goes through `Trasher`, which checks `SafetyPolicy` first. No other code calls `trashItem` or `removeItem` on user files.
- Only paths strictly inside the home folder, or inside this user's /var/folders T and X folders. Never the home folder, its standard top-level folders, `~/Library` subfolders themselves, the Trash, keychains, iCloud Drive / CloudStorage, Mail, Messages, Safari data, credentials (`.ssh`, `.aws`, `.docker`, `.netrc`, `.config/gh` and the rest of `credentialPaths`), media libraries and catalogs, or anything inside an app bundle or media library.
- A folder that holds a media library is refused as a whole. A folder that holds a git repository may go (an old project is real cleanup), but the confirmation sheet says so. A `.git` folder on its own is never removed.
- A duplicate is removed only while another copy of it, same size, is still on disk and not part of the same removal. The check runs at removal time, so copies removed from another pane or the Finder count.
- After a removal, every pane drops what moved, including items inside removed folders.
- Every removal is logged to `~/Library/Logs/MacCleaner/removals.log` with its Trash location, so it can be put back.
- Tools run in their own process group; Stop and quitting the app kill the whole group.
- Items under a running app's bundle id or name in app data are refused until the app quits.
