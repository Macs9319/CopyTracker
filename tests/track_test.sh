#!/bin/bash
# Test suite for track.sh — plain bash, no external test framework. Each
# test runs in its own subshell against a throwaway XDG_STATE_HOME, so
# nothing here ever touches a real copy history.
#
# Run: ./tests/track_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACK_SH="$SCRIPT_DIR/../track.sh"

tests_run=0
failures=0

# ---------- sql_escape / injection safety ----------

test_sql_escape_doubles_single_quotes() {
  local got
  got=$(sql_escape "it's a test")
  [[ "$got" == "it''s a test" ]]
}

# The escaped form is spliced directly into a SQL string literal below, the
# same way upsert_clip does it. If sql_escape were wrong, this payload would
# break out of the literal and the DROP TABLE would actually run.
test_sql_escape_survives_injection_payload() {
  local payload="'); DROP TABLE clips; --"
  local escaped
  escaped=$(sql_escape "$payload")
  db "INSERT INTO clips (type, content, pinned) VALUES ('text', '$escaped', 0);"

  local count got
  count=$(db "SELECT COUNT(*) FROM clips;")
  [[ "$count" == "1" ]] || return 1
  got=$(db "SELECT content FROM clips WHERE type='text' LIMIT 1;")
  [[ "$got" == "$payload" ]]
}

# ---------- like_escape / search wildcards ----------

test_like_escape_treats_percent_literally() {
  db "INSERT INTO clips (type, content, pinned) VALUES ('text', '100% done', 0);"
  db "INSERT INTO clips (type, content, pinned) VALUES ('text', 'no percent here', 0);"

  local escaped matched
  escaped=$(like_escape "%")
  matched=$(dbjson "SELECT content FROM clips WHERE content LIKE '%$escaped%' ESCAPE '\' ORDER BY id;" | jq -r 'length')
  [[ "$matched" == "1" ]]
}

test_like_escape_treats_underscore_literally() {
  db "INSERT INTO clips (type, content, pinned) VALUES ('text', 'file_1', 0);"
  db "INSERT INTO clips (type, content, pinned) VALUES ('text', 'fileX1', 0);"

  local escaped matched
  escaped=$(like_escape "file_1")
  matched=$(dbjson "SELECT content FROM clips WHERE content LIKE '%$escaped%' ESCAPE '\';" | jq -r 'length')
  [[ "$matched" == "1" ]]
}

test_like_escape_handles_backslash() {
  db "INSERT INTO clips (type, content, pinned) VALUES ('text', 'C:\Users\test', 0);"

  local escaped matched
  escaped=$(like_escape 'C:\Users\test')
  matched=$(dbjson "SELECT content FROM clips WHERE content LIKE '%$escaped%' ESCAPE '\';" | jq -r 'length')
  [[ "$matched" == "1" ]]
}

# ---------- id interpolation safety (delete/pin/unpin/copy/paste) ----------

# id is spliced into `WHERE id=$id` unescaped everywhere except list/count —
# require_int is the only thing standing between clipboard-adjacent input
# and a raw SQL id. Confirm it actually rejects and nothing runs.
test_require_int_rejects_non_numeric_id() {
  local status=0
  bash "$TRACK_SH" delete "1; DROP TABLE clips; --" >/dev/null 2>&1 || status=$?
  [[ $status -ne 0 ]] || return 1

  local count
  count=$(db "SELECT COUNT(*) FROM clips;")
  [[ "$count" == "0" ]]
}

# ---------- trim_table caps ----------

test_trim_table_caps_unpinned_entries() {
  MAX_ENTRIES=3
  local i
  for i in 1 2 3 4 5; do
    db "INSERT INTO clips (type, content, pinned) VALUES ('text', 'entry-$i', 0);"
  done
  trim_table

  local count remaining
  count=$(db "SELECT COUNT(*) FROM clips;")
  [[ "$count" == "3" ]] || return 1
  remaining=$(dbjson "SELECT content FROM clips ORDER BY id;" | jq -r '[.[].content] | join(",")')
  [[ "$remaining" == "entry-3,entry-4,entry-5" ]]
}

# Pinned entries beyond MAX_PINNED fall back to unpinned instead of being
# deleted outright.
test_trim_table_demotes_excess_pinned_instead_of_deleting() {
  MAX_PINNED=2
  local i
  for i in 1 2 3 4; do
    db "INSERT INTO clips (type, content, pinned) VALUES ('text', 'pinned-$i', 1);"
  done
  trim_table

  local pinned_count total
  pinned_count=$(db "SELECT COUNT(*) FROM clips WHERE pinned=1;")
  total=$(db "SELECT COUNT(*) FROM clips;")
  [[ "$pinned_count" == "2" ]] || return 1
  [[ "$total" == "4" ]]
}

# ---------- insert-text truncation ----------

test_insert_text_truncates_long_content() {
  local long stored
  long=$(head -c 500 </dev/zero | tr '\0' 'a')
  printf '%s' "$long" | MAX_TEXT_CHARS=50 bash "$TRACK_SH" insert-text >/dev/null

  stored=$(dbjson "SELECT content FROM clips WHERE type='text' LIMIT 1;" | jq -r '.[0].content')
  # 50 'a's + "\n[truncated]"
  [[ "$stored" == "$(printf 'a%.0s' {1..50})"$'\n[truncated]' ]]
}

test_insert_text_leaves_short_content_untouched() {
  printf 'short text' | MAX_TEXT_CHARS=50 bash "$TRACK_SH" insert-text >/dev/null

  local stored
  stored=$(dbjson "SELECT content FROM clips WHERE type='text' LIMIT 1;" | jq -r '.[0].content')
  [[ "$stored" == "short text" ]]
}

# ---------- harness ----------

run_test() {
  local name="$1" tmp_state
  tests_run=$((tests_run + 1))
  tmp_state=$(mktemp -d)

  if (
    export XDG_STATE_HOME="$tmp_state"
    # shellcheck source=../track.sh
    source "$TRACK_SH"
    init_db
    "$name"
  ); then
    echo "ok   - $name"
  else
    echo "FAIL - $name"
    failures=$((failures + 1))
  fi

  rm -rf "$tmp_state"
}

main() {
  local t
  while IFS= read -r t; do
    run_test "$t"
  done < <(declare -F | awk '{print $3}' | grep '^test_' | sort)

  echo
  echo "$tests_run tests, $failures failed"
  [[ "$failures" -eq 0 ]]
}

main
