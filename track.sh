#!/bin/bash
# Backing store for the Copy Tracker plugin. Every copy action gets one row
# in a SQLite database; the panel shells out here to read/write it.
set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
IMAGE_DIR="$STATE_DIR/copytracker-images"
DB="$STATE_DIR/copytracker.db"
# Overridable via env (mainly so tests can exercise the caps without writing
# thousands of rows).
: "${MAX_ENTRIES:=1000}"
: "${MAX_PINNED:=200}"
: "${MAX_TEXT_CHARS:=100000}"

mkdir -p "$STATE_DIR" "$IMAGE_DIR"

# The busy timeout is per-connection (unlike journal_mode, it isn't persisted
# in the database file), so every sqlite3 invocation needs it set explicitly —
# the text/image watchers and panel actions all hit this same file and would
# otherwise fail immediately instead of waiting out a momentary lock. Using
# the `.timeout` dot-command rather than `PRAGMA busy_timeout=`, since the
# PRAGMA form prints its own result row and would corrupt every query's
# output (plain and -json alike).
db() {
  sqlite3 -cmd ".timeout 5000" "$DB" "$@"
}

dbjson() {
  sqlite3 -cmd ".timeout 5000" -json "$DB" "$@"
}

init_db() {
  db <<'SQL'
CREATE TABLE IF NOT EXISTS clips (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT NOT NULL,
  content TEXT NOT NULL,
  mime TEXT,
  pinned INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);
SQL
  # WAL lets the watcher processes and panel actions read/write concurrently
  # instead of blocking on a single file lock. Persisted in the DB file, so
  # this only needs to run once, but it's idempotent.
  db "PRAGMA journal_mode=WAL;" >/dev/null
  # Migrate databases created before the pinned column existed.
  if ! db "PRAGMA table_info(clips);" | grep -q '|pinned|'; then
    db "ALTER TABLE clips ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;"
  fi
}

# Skip anything flagged as a password-manager copy, same convention the
# built-in clipboard history plugin uses.
is_sensitive() {
  local types
  types=$(wl-paste --list-types 2>/dev/null || true)
  [[ ${CLIPBOARD_STATE:-} == "sensitive" ]] && return 0
  grep -qx 'x-kde-passwordManagerHint' <<<"$types" && return 0
  return 1
}

sql_escape() {
  # Doubling single quotes is the standard (and sufficient) SQLite string
  # literal escape — SQLite has no backslash-escape sequences to worry about.
  printf '%s' "${1//\'/\'\'}"
}

# Escapes a string for safe use inside a LIKE '%...%' pattern: backslash
# first (it's about to become the escape char), then the LIKE wildcards,
# then quotes last via sql_escape.
like_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//%/\\%}"
  s="${s//_/\\_}"
  sql_escape "$s"
}

# Pinned entries are exempt from the MAX_ENTRIES cap, but not unbounded:
# beyond MAX_PINNED, the oldest excess ones fall back to unpinned instead of
# being deleted outright, so they just become subject to the normal trim
# below rather than disappearing immediately. Only the oldest unpinned
# entries beyond MAX_ENTRIES are actually deleted.
trim_table() {
  db "UPDATE clips SET pinned=0 WHERE pinned=1 AND id NOT IN (SELECT id FROM clips WHERE pinned=1 ORDER BY id DESC LIMIT $MAX_PINNED);"

  mapfile -t stale_images < <(db "SELECT DISTINCT content FROM clips WHERE type='image' AND pinned=0 AND id NOT IN (SELECT id FROM clips WHERE pinned=0 ORDER BY id DESC LIMIT $MAX_ENTRIES);")
  db "DELETE FROM clips WHERE pinned=0 AND id NOT IN (SELECT id FROM clips WHERE pinned=0 ORDER BY id DESC LIMIT $MAX_ENTRIES);"
  prune_images "${stale_images[@]}"
}

# Removes each given image file, but only once no remaining row still
# references it — the same file can back multiple rows, since insert-image
# dedups by content hash instead of writing a fresh copy every time.
prune_images() {
  local f still_used
  for f in "$@"; do
    [[ -z "$f" ]] && continue
    still_used=$(db "SELECT COUNT(*) FROM clips WHERE type='image' AND content='$(sql_escape "$f")';")
    [[ "$still_used" -eq 0 ]] && rm -f "$f"
  done
}

# Inserts a fresh row for (type, content), carrying over any existing
# pinned flag and removing prior row(s) with identical content first —
# so re-copying something already in the history bumps it to the top
# instead of piling up a duplicate. mime may be empty for text entries.
upsert_clip() {
  local type="$1" content="$2" mime="$3" pinned
  pinned=$(db "SELECT COALESCE(MAX(pinned), 0) FROM clips WHERE type='$type' AND content='$content';")
  db "DELETE FROM clips WHERE type='$type' AND content='$content';"
  if [[ -n "$mime" ]]; then
    db "INSERT INTO clips (type, content, mime, pinned) VALUES ('$type', '$content', '$mime', $pinned);"
  else
    db "INSERT INTO clips (type, content, pinned) VALUES ('$type', '$content', $pinned);"
  fi
}

require_int() {
  [[ "$1" =~ ^[0-9]+$ ]] || { echo "expected an integer, got: $1" >&2; exit 1; }
}

# Puts entry $1 back on the system clipboard. Returns non-zero (without
# touching the clipboard) if the id doesn't exist.
copy_entry() {
  local id="$1" row type content mime
  row=$(dbjson "SELECT type, content, mime FROM clips WHERE id=$id LIMIT 1;")
  type=$(jq -r '.[0].type // empty' <<<"$row")
  content=$(jq -r '.[0].content // empty' <<<"$row")
  mime=$(jq -r '.[0].mime // empty' <<<"$row")
  [[ -z "$type" ]] && return 1

  if [[ "$type" == "image" ]]; then
    wl-copy --type "$mime" <"$content"
  else
    printf '%s' "$content" | wl-copy
  fi
}

# Guarded so tests/track_test.sh can source this file for its functions
# (sql_escape, like_escape, trim_table, ...) without running the CLI dispatch.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

init_db

cmd="${1:-}"
shift || true

case "$cmd" in
insert-text)
  is_sensitive && exit 0
  text=$(cat)
  text="${text%$'\n'}"
  [[ -z "$text" ]] && exit 0

  # Bound how much a single copy can bloat the database — huge pastes (a log
  # file, a giant diff) get truncated rather than stored in full.
  if (( ${#text} > MAX_TEXT_CHARS )); then
    text="${text:0:MAX_TEXT_CHARS}"$'\n[truncated]'
  fi

  last=$(db "SELECT content FROM clips WHERE type='text' ORDER BY id DESC LIMIT 1;")
  [[ "$text" == "$last" ]] && exit 0

  escaped=$(sql_escape "$text")
  upsert_clip "text" "$escaped" ""
  trim_table
  echo changed
  ;;

insert-image)
  is_sensitive && exit 0

  tmp=$(mktemp --tmpdir="$IMAGE_DIR" clip.XXXXXX)
  cat >"$tmp"
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    exit 0
  fi

  # Detect the real MIME type from content rather than trusting the caller —
  # the watcher uses `wl-paste --type image` (whatever image format the app
  # actually offers), so this may be png, jpeg, webp, gif, etc.
  mime=$(file --brief --mime-type "$tmp" 2>/dev/null || echo "")
  case "$mime" in
    image/*) ;;
    *) mime="image/png" ;;
  esac
  ext="${mime#image/}"
  case "$ext" in
    jpeg) ext="jpg" ;;
    svg+xml) ext="svg" ;;
    x-icon) ext="ico" ;;
  esac

  hash=$(sha256sum "$tmp" | awk '{print $1}')
  file="$IMAGE_DIR/$hash.$ext"
  if [[ -e "$file" ]]; then
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
  fi

  last=$(db "SELECT content FROM clips WHERE type='image' ORDER BY id DESC LIMIT 1;")
  [[ "$file" == "$last" ]] && exit 0

  file_escaped=$(sql_escape "$file")
  mime_escaped=$(sql_escape "$mime")
  upsert_clip "image" "$file_escaped" "$mime_escaped"
  trim_table
  echo changed
  ;;

list)
  limit="${1:-300}"
  require_int "$limit"
  query="${2:-}"
  if [[ -n "$query" ]]; then
    escaped=$(like_escape "$query")
    dbjson "SELECT id, type, content, mime, pinned, created_at FROM clips WHERE content LIKE '%$escaped%' ESCAPE '\' ORDER BY pinned DESC, id DESC LIMIT $limit;"
  else
    dbjson "SELECT id, type, content, mime, pinned, created_at FROM clips ORDER BY pinned DESC, id DESC LIMIT $limit;"
  fi
  ;;

count)
  db "SELECT COUNT(*) FROM clips;"
  ;;

delete)
  id="${1:?id required}"
  require_int "$id"
  row=$(dbjson "SELECT type, content FROM clips WHERE id=$id LIMIT 1;")
  db "DELETE FROM clips WHERE id=$id;"
  if [[ "$(jq -r '.[0].type // empty' <<<"$row")" == "image" ]]; then
    prune_images "$(jq -r '.[0].content // empty' <<<"$row")"
  fi
  ;;

clear)
  mapfile -t all_images < <(db "SELECT DISTINCT content FROM clips WHERE type='image' AND pinned=0;")
  db "DELETE FROM clips WHERE pinned=0;"
  prune_images "${all_images[@]}"
  ;;

pin)
  id="${1:?id required}"
  require_int "$id"
  db "UPDATE clips SET pinned=1 WHERE id=$id;"
  ;;

unpin)
  id="${1:?id required}"
  require_int "$id"
  db "UPDATE clips SET pinned=0 WHERE id=$id;"
  ;;

copy)
  id="${1:?id required}"
  require_int "$id"
  copy_entry "$id" || exit 0
  ;;

paste)
  id="${1:?id required}"
  require_int "$id"
  copy_entry "$id" || exit 0
  # Give the popup a moment to close and hand focus back to whatever was
  # behind it, then paste through the clipboard rather than typing it out —
  # the only option that works for both text and images. Same convention
  # (delay + shift-insert via wtype) as the built-in clipboard history
  # plugin's omarchy-clipboard-paste-text helper.
  sleep 0.15
  wtype -M shift -k Insert -m shift 2>/dev/null || true
  ;;

*)
  echo "usage: track.sh {insert-text|insert-image|list [limit] [query]|count|delete <id>|clear|pin <id>|unpin <id>|copy <id>|paste <id>}" >&2
  exit 1
  ;;
esac

fi
