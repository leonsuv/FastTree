# Changelog

## 0.2.0 — 2026-09-29

- Rebuilt the shipped AppKit interface around a native toolbar, translucent sidebar, clickable path navigation, and an adjustable explorer/map split.
- Fixed the fixed-width layout that left much of the window unused and clipped table columns.
- Replaced outlined cards with a compact storage summary and proportional color breakdown. Folder totals update as you navigate.
- Added squarified treemap layout, stable colors, immediate hover inspection, linked selection, and double-click navigation.
- Added sortable columns, localized percentages and counts, a Largest Files view, debounced search, keyboard navigation, and context actions.
- Added System, Light, and Dark appearance options and a native app icon.
- Improved multi-selection in Finder and Trash confirmation sheets, including error reporting. A stopped or failed scan retains the last good loaded index.
- Pinned both app and scanner builds to Apple silicon / macOS 13, so release compatibility matches the documented minimum.
- Added reproducible native-window snapshots and a macOS UI smoke check; updated screenshots and documentation.

## 0.1.0 — 2026-09-29

Initial native macOS disk analyzer with parallel APFS scanning, a persistent filesystem index, file exploration, and a treemap.
