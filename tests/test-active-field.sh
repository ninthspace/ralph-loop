#!/bin/bash
# test-active-field.sh — the `active:` field in the state file must actually govern the
# loop, and pausing must be non-destructive.
#
# Upstream writes `active: true` into every state file and never reads it. That is the
# defect: the field names the loop's most important property and controls nothing, so the
# obvious way to pause a run -- set it false -- does nothing at all, and silently. The only
# working stop is deleting the file, which throws away the prompt and the iteration count.
#
# Three properties, and the third is the one that makes the feature worth having:
#
#   1. `active: true` (and an absent field) behave as before -- the loop blocks the exit.
#   2. Anything else allows the exit.
#   3. Pausing does not TOUCH the file. Not the iteration counter, not the prompt, not the
#      field itself. A pause that advanced the counter or removed the file would be a
#      differently-shaped version of the same bug: a control that does not do what it says.
#
# The pairing carries the weight here. "Allows exit when paused" is satisfied by a hook
# that never blocks anything, so every paused case is run against an active control built
# from the same fixture in the same way.
#
# Usage: bash tests/test-active-field.sh

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-hook.sh"
PASS=0
FAIL=0

# <dir> [active-value]  -- omit the value entirely to write no `active:` line at all.
state_file() {
  local dir="$1"
  mkdir -p "$dir/.claude"
  {
    echo "---"
    [[ $# -ge 2 ]] && echo "active: $2"
    echo "iteration: 7"
    echo "max_iterations: 50"
    echo 'completion_promise: "SPEC_DELIVERED"'
    echo 'started_at: "2026-01-01T00:00:00Z"'
    echo "---"
    echo ""
    echo "Work the task to completion."
  } > "$dir/.claude/ralph-loop.local.md"
}

# "block" when the hook blocks the exit, "allow" when it lets the session end.
decision_of() { # <dir> <transcript>
  local out
  out=$( cd "$1" && printf '{"transcript_path":"%s","session_id":""}' "$2" | bash "$HOOK" 2>/dev/null )
  local d
  d=$(echo "$out" | jq -r '.decision // "allow"' 2>/dev/null) || d="allow"
  [[ "$d" == "block" ]] && echo "block" || echo "allow"
}

check() { # <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "  PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1 (expected '$2', got '$3')"
    FAIL=$((FAIL + 1))
  fi
}

echo "Testing: the active: field governs the loop"
echo "==========================================="

T=$(mktemp -d)
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}' \
  > "$T/no-promise.jsonl"

# --- controls: the loop still runs when it should ------------------------------------
# These come first deliberately. Every "allows exit" assertion below is also satisfied by
# a hook that has stopped blocking altogether, and these are what rule that out.

D=$(mktemp -d); state_file "$D" true
check "control: active: true blocks the exit" "block" "$(decision_of "$D" "$T/no-promise.jsonl")"

D=$(mktemp -d); state_file "$D"
check "control: a state file with no active: field blocks the exit (legacy compatibility)" \
  "block" "$(decision_of "$D" "$T/no-promise.jsonl")"

# --- the field is read ---------------------------------------------------------------

D=$(mktemp -d); state_file "$D" false
check "active: false allows the exit" "allow" "$(decision_of "$D" "$T/no-promise.jsonl")"

# Not a boolean-parsing exercise: anything that is not `true` is not active. A state file
# reading `active: paused` should not quietly keep running because it failed to say false.
D=$(mktemp -d); state_file "$D" paused
check "any non-true value allows the exit" "allow" "$(decision_of "$D" "$T/no-promise.jsonl")"

D=$(mktemp -d); state_file "$D" "true "
check "trailing whitespace does not defeat the true case" "block" "$(decision_of "$D" "$T/no-promise.jsonl")"

# --- pausing is non-destructive ------------------------------------------------------
# The point of the field over `rm` is that the loop survives the pause. If any of these
# fail, deleting the file was just as good and the field is decoration.

D=$(mktemp -d); state_file "$D" false
BEFORE=$(cat "$D/.claude/ralph-loop.local.md")
decision_of "$D" "$T/no-promise.jsonl" >/dev/null
check "a paused loop keeps its state file" "yes" \
  "$( [[ -f "$D/.claude/ralph-loop.local.md" ]] && echo yes || echo no )"
check "a paused loop's state file is byte-for-byte unchanged" "same" \
  "$( [[ "$BEFORE" == "$(cat "$D/.claude/ralph-loop.local.md")" ]] && echo same || echo modified )"

# Stated separately because it is the failure a reader would actually hit: pause a run
# overnight, resume it, and find the counter has been advancing without any work happening.
check "a paused loop does not advance the iteration counter" "iteration: 7" \
  "$(grep '^iteration:' "$D/.claude/ralph-loop.local.md")"

# --- and the pause is reversible -----------------------------------------------------
# The whole claim is that this is a pause rather than a stop, which is only true if
# flipping the field back resumes the same loop at the same place.

sed 's/^active: false/active: true/' "$D/.claude/ralph-loop.local.md" > "$D/.tmp" && mv "$D/.tmp" "$D/.claude/ralph-loop.local.md"
check "setting active: true again resumes the loop" "block" "$(decision_of "$D" "$T/no-promise.jsonl")"
check "and it resumes from the iteration it was paused at" "iteration: 8" \
  "$(grep '^iteration:' "$D/.claude/ralph-loop.local.md")"

# --- a paused loop is paused, not finished -------------------------------------------
# The hook must not treat a pause as completion: no promise was emitted, so nothing should
# claim one was.

D=$(mktemp -d); state_file "$D" false
OUT=$( cd "$D" && printf '{"transcript_path":"%s","session_id":""}' "$T/no-promise.jsonl" | bash "$HOOK" 2>&1 )
check "pausing does not report a completed promise" "quiet" \
  "$(echo "$OUT" | grep -q "RALPH_PROMISE_MATCHED" && echo claimed || echo quiet)"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
