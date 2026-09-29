# Native UI validation — v0.2.0

Validated on an Apple silicon Mac running macOS 27.0, using Swift 6.4. The app and scanner are compiled with an explicit macOS 13 deployment target. Runtime testing on macOS 13 was not performed locally; the GitHub workflow additionally builds against its macOS runner's SDK.

## Automated render check

Run `./build-appkit.sh`, then `./scripts/check-ui.sh`.

The check scans an isolated fixture containing four files across three folders, opens the real resulting index, and renders the production AppKit window. It checks:

- Light and dark appearances at a 1080 × 660 window size.
- Empty state at the same minimum size, with no prior index loaded.
- Three root rows for the fixture and zero rows in the empty state.
- At least 420 points for the explorer and 280 for the map; the two panels fill the available content width.
- Valid PNG snapshots and no conflicting Auto Layout constraints in the application output.

Result: all three render cases passed. Wide-window captures were also inspected visually in both appearances.

## Live application checks

Performed against the native app, including a small disposable scan fixture:

- Folder picker and successful scan: four files, three folders, and correct size ordering.
- Rescan via ⌘R and index replacement without a crash.
- Scan progress, enabled Stop action, and cancellation preserving the previously loaded index.
- Double-click and Return navigation; clickable path components and ⌘↑ return to the enclosing folder.
- Name sorting, global search via ⌘F, and Largest Files results.
- Treemap click selects and scrolls to the corresponding explorer row; row selection updates the inspector and map highlight.
- Trash opens a confirmation sheet. Cancel leaves the fixture untouched. Actual deletion was not exercised.
- Appearance switching between light and dark.

## Screenshots

The README images are direct renders of the shipped AppKit window with a real volume index, using only top-level system folder names. They contain no mocked UI or generated metrics. Snapshot mode does not replace the last scanned location.

```sh
dist/FastTree.app/Contents/MacOS/FastTree \
  --snapshot /tmp/FastTree-dark.png \
  --snapshot-root /path/to/scanned/folder \
  --snapshot-index /path/to/index.ftidx \
  --snapshot-appearance dark \
  --snapshot-width 1360 --snapshot-height 880
```
