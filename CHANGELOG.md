# Changelog

All notable changes to Copy Tracker are documented here.

## [1.3.0]

### Added
- Pin entries (☆/★ button, or `p` on the selected entry) to keep them at the
  top of the list, exempt from "Clear All" and the 1000-entry cap
- Thumbnail previews for image entries in the history list
- Copying something already in the history now bumps it to the top instead
  of adding a duplicate row

### Fixed
- Deleting an entry (individually, via Clear All, or by aging out past the
  1000-entry cap) now also removes its backing image file, instead of
  leaving it behind permanently
- Clipboard content that's actually HTML (e.g. copied from Google Docs) no
  longer risks rendering an embedded `<img>` as an oversized inline image in
  the history list — its tags are stripped before display

## [1.2.0]

### Changed
- Selecting an entry (Enter/Space, the ↺ button, or clicking a row) now
  pastes it directly into whatever regains focus after the panel closes,
  instead of only copying it to the clipboard

## [1.1.0]

### Added
- Search box to filter clipboard history as you type
- Keyboard navigation: ↓/↑ (or j/k) to move the selection, Enter/Space to
  copy the selected entry and close the panel, auto-scrolling to keep the
  selection in view

## [1.0.0]

### Added
- Background logging of every text/image copy to a local SQLite database
- Bar icon and popup to browse, re-copy, and delete past clipboard entries
- "Clear All" with a confirmation dialog
- Sensitive-copy detection (password managers) to skip logging those, and
  de-duplication of consecutive identical copies
