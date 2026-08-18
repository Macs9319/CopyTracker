# Changelog

All notable changes to Copy Tracker are documented here.

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
