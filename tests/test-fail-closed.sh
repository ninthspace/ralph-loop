#!/bin/bash
# test-fail-closed.sh — the stop hook must not delete the loop's state file when it
# cannot read the transcript.
#
# Each case runs the real hook in a scratch directory and asks one question: is the state
# file still there afterwards? That is the only property under test, because it is the one
# that decides whether an unattended run continues or ends silently.
#
# The pairing matters more than any single case. "Survives a missing transcript" proves
# nothing on its own -- a hook that never deleted anything would pass it -- so the two
# branches that SHOULD delete (a matched promise, the iteration cap) are asserted in the
# same run. Together they show the hook still ends when it should.
#
# Usage: bash tests/test-fail-closed.sh

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-hook.sh"
PASS=0
FAIL=0

state_file() { # <dir> [iteration] [promise]
  mkdir -p "$1/.claude"
  cat > "$1/.claude/ralph-loop.local.md" <<EOF
---
active: true
iteration: ${2:-1}
max_iterations: 50
completion_promise: "${3:-SPEC_DELIVERED}"
started_at: "2026-01-01T00:00:00Z"
---

Work the task to completion.
EOF
}

# Returns "kept" or "deleted" after running the hook against <transcript>.
run_hook() { # <dir> <transcript>
  ( cd "$1" && printf '{"transcript_path":"%s","session_id":""}' "$2" | bash "$HOOK" ) >/dev/null 2>&1
  [[ -f "$1/.claude/ralph-loop.local.md" ]] && echo "kept" || echo "deleted"
}

check() { # <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "  PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (expected $2, got $3)"
    FAIL=$((FAIL + 1))
  fi
}

echo "Testing: stop hook fails closed on unreadable transcripts"
echo "========================================================="

T=$(mktemp -d)

# A turn that ends on a tool call. Every agentic story ends this way -- with a commit --
# so this is the ordinary shape, not a corrupt one.
printf '%s\n' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Story complete, committed."}]}}' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"a","input":{}}]}}' \
  > "$T/tool-call-last.jsonl"

printf '%s\n' \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done. <promise>SPEC_DELIVERED</promise>"}]}}' \
  > "$T/promise.jsonl"

printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}' \
  > "$T/no-promise.jsonl"

# Malformed JSON: jq fails on the slurp.
printf '%s\n' '{"role":"assistant" TRUNCATED' > "$T/malformed.jsonl"

# Well-formed JSONL containing no assistant records at all.
printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' > "$T/no-assistant.jsonl"

# Simulates a serialisation change: valid records the grep pattern cannot match.
printf '%s\n' '{"type":"assistant","message":{"role": "assistant","content":[{"type":"text","text":"hi"}]}}' \
  > "$T/respaced.jsonl"

# --- must keep the state file -------------------------------------------------------

D=$(mktemp -d); state_file "$D"
check "a turn ending on a tool call keeps the loop alive" "kept" "$(run_hook "$D" "$T/tool-call-last.jsonl")"

D=$(mktemp -d); state_file "$D"
check "a missing transcript keeps the loop alive" "kept" "$(run_hook "$D" "$T/does-not-exist.jsonl")"

D=$(mktemp -d); state_file "$D"
check "a malformed transcript keeps the loop alive" "kept" "$(run_hook "$D" "$T/malformed.jsonl")"

D=$(mktemp -d); state_file "$D"
check "a transcript with no assistant records keeps the loop alive" "kept" "$(run_hook "$D" "$T/no-assistant.jsonl")"

D=$(mktemp -d); state_file "$D"
check "a transcript the grep pattern cannot match keeps the loop alive" "kept" "$(run_hook "$D" "$T/respaced.jsonl")"

D=$(mktemp -d); state_file "$D"
check "an ordinary iteration with no promise keeps the loop alive" "kept" "$(run_hook "$D" "$T/no-promise.jsonl")"

# --- must still delete it -----------------------------------------------------------
# Without these, every assertion above is satisfied by a hook that does nothing at all.

D=$(mktemp -d); state_file "$D"
check "control: a matched promise still ends the loop" "deleted" "$(run_hook "$D" "$T/promise.jsonl")"

D=$(mktemp -d); state_file "$D" 50
check "control: reaching max_iterations still ends the loop" "deleted" "$(run_hook "$D" "$T/no-promise.jsonl")"

# --- the loop must actually advance -------------------------------------------------
# A hook that kept the file but stopped blocking the exit would pass everything above
# while the loop silently did not run.

D=$(mktemp -d); state_file "$D"
OUT=$( cd "$D" && printf '{"transcript_path":"%s","session_id":""}' "$T/tool-call-last.jsonl" | bash "$HOOK" 2>/dev/null )
DECISION=$(echo "$OUT" | jq -r '.decision // "none"' 2>/dev/null)
check "the hook blocks the stop and feeds the prompt back" "block" "$DECISION"
check "the iteration counter advances" "iteration: 2" "$(grep '^iteration:' "$D/.claude/ralph-loop.local.md")"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
