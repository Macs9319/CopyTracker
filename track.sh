#!/bin/bash
# Backing store for the Copy Tracker plugin. Every copy action gets one row
# in a SQLite database; the panel shells out here to read/write it.
set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
IMAGE_DIR="$STATE_DIR/copytracker-images"
DB="$STATE_DIR/copytracker.db"
MAX_ENTRIES=1000

mkdir -p "$STATE_DIR" "$IMAGE_DIR"

init_db() {
  sqlite3 "$DB" <<'SQL'
CREATE TABLE IF NOT EXISTS clips (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT NOT NULL,
  content TEXT NOT NULL,
  mime TEXT,
  created_at TEXT NOT NULL DEFAULT (datetime('now','localtime'))
);
SQL
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

trim_table() {
  mapfile -t stale_images < <(sqlite3 "$DB" "SELECT DISTINCT content FROM clips WHERE type='image' AND id NOT IN (SELECT id FROM clips ORDER BY id DESC LIMIT $MAX_ENTRIES);")
  sqlite3 "$DB" "DELETE FROM clips WHERE id NOT IN (SELECT id FROM clips ORDER BY id DESC LIMIT $MAX_ENTRIES);"
  prune_images "${stale_images[@]}"
}

# Removes each given image file, but only once no remaining row still
# references it — the same file can back multiple rows, since insert-image
# dedups by content hash instead of writing a fresh copy every time.
prune_images() {
  local f still_used
  for f in "$@"; do
    [[ -z "$f" ]] && continue
    still_used=$(sqlite3 "$DB" "SELECT COUNT(*) FROM clips WHERE type='image' AND content='$(sql_escape "$f")';")
    [[ "$still_used" -eq 0 ]] && rm -f "$f"
  done
}

require_int() {
  [[ "$1" =~ ^[0-9]+$ ]] || { echo "expected an integer, got: $1" >&2; exit 1; }
}

# Puts entry $1 back on the system clipboard. Returns non-zero (without
# touching the clipboard) if the id doesn't exist.
copy_entry() {
  local id="$1" row type content mime
  row=$(sqlite3 -json "$DB" "SELECT type, content, mime FROM clips WHERE id=$id LIMIT 1;")
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

init_db

cmd="${1:-}"
shift || true

case "$cmd" in
insert-text)
  is_sensitive && exit 0
  text=$(cat)
  text="${text%$'\n'}"
  [[ -z "$text" ]] && exit 0

  last=$(sqlite3 "$DB" "SELECT content FROM clips WHERE type='text' ORDER BY id DESC LIMIT 1;")
  [[ "$text" == "$last" ]] && exit 0

  escaped=$(sql_escape "$text")
  printf "INSERT INTO clips (type, content) VALUES ('text', '%s');" "$escaped" | sqlite3 "$DB"
  trim_table
  echo changed
  ;;

insert-image)
  is_sensitive && exit 0
  mime="${1:-image/png}"
  ext="${mime#image/}"
  [[ "$ext" == "jpeg" ]] && ext="jpg"

  tmp=$(mktemp --tmpdir="$IMAGE_DIR" clip.XXXXXX)
  cat >"$tmp"
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    exit 0
  fi

  hash=$(sha256sum "$tmp" | awk '{print $1}')
  file="$IMAGE_DIR/$hash.$ext"
  if [[ -e "$file" ]]; then
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
  fi

  last=$(sqlite3 "$DB" "SELECT content FROM clips WHERE type='image' ORDER BY id DESC LIMIT 1;")
  [[ "$file" == "$last" ]] && exit 0

  file_escaped=$(sql_escape "$file")
  mime_escaped=$(sql_escape "$mime")
  printf "INSERT INTO clips (type, content, mime) VALUES ('image', '%s', '%s');" "$file_escaped" "$mime_escaped" | sqlite3 "$DB"
  trim_table
  echo changed
  ;;

list)
  limit="${1:-300}"
  require_int "$limit"
  query="${2:-}"
  if [[ -n "$query" ]]; then
    escaped=$(like_escape "$query")
    sqlite3 -json "$DB" "SELECT id, type, content, mime, created_at FROM clips WHERE content LIKE '%$escaped%' ESCAPE '\' ORDER BY id DESC LIMIT $limit;"
  else
    sqlite3 -json "$DB" "SELECT id, type, content, mime, created_at FROM clips ORDER BY id DESC LIMIT $limit;"
  fi
  ;;

count)
  sqlite3 "$DB" "SELECT COUNT(*) FROM clips;"
  ;;

delete)
  id="${1:?id required}"
  require_int "$id"
  row=$(sqlite3 -json "$DB" "SELECT type, content FROM clips WHERE id=$id LIMIT 1;")
  sqlite3 "$DB" "DELETE FROM clips WHERE id=$id;"
  if [[ "$(jq -r '.[0].type // empty' <<<"$row")" == "image" ]]; then
    prune_images "$(jq -r '.[0].content // empty' <<<"$row")"
  fi
  ;;

clear)
  mapfile -t all_images < <(sqlite3 "$DB" "SELECT DISTINCT content FROM clips WHERE type='image';")
  sqlite3 "$DB" "DELETE FROM clips;"
  prune_images "${all_images[@]}"
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
  echo "usage: track.sh {insert-text|insert-image <mime>|list [limit] [query]|count|delete <id>|clear|copy <id>|paste <id>}" >&2
  exit 1
  ;;
esac
