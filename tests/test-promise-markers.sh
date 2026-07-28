#!/bin/bash
# test-promise-markers.sh — the hook's own output must never look like a promise emission.
#
# The loop ends when the model emits its completion promise wrapped in promise tags. That
# makes the tagged pattern the natural thing to grep a run for, and upstream put the
# literal pattern into the per-iteration reminder -- so on a 24-iteration run, a grep for
# the emission returns 24 hits from the hook and none from the model until the last one.
# An observer cannot tell a loop that finished from one that was told how to finish, and
# neither can any script watching the run.
#
# Two properties:
#
#   1. The hook's output never contains the tagged pattern. Not in the reminder, not in
#      the detection message. Whatever the tags surround in a transcript came from the
#      model.
#   2. The information the model needs survives anyway -- the exact promise text, and the
#      fact that it goes in promise tags. Property 1 alone is satisfied by saying nothing,
#      which would trade an observability bug for a functional one.
#
# Plus a marker the fork adds: RALPH_PROMISE_MATCHED, emitted only on a genuine match, so
# there is something unambiguous to grep for. It is asserted both ways -- present when the
# promise matched, absent when it did not -- because a marker that always fires is no
# better than the pattern it replaces.
#
# Usage: bash tests/test-promise-markers.sh

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/stop-hook.sh"
SETUP="$(cd "$(dirname "$0")/.." && pwd)/scripts/setup-ralph-loop.sh"
PASS=0
FAIL=0

PROMISE="SPEC_DELIVERED"

state_file() { # <dir> [iteration]
  mkdir -p "$1/.claude"
  cat > "$1/.claude/ralph-loop.local.md" <<EOF
---
active: true
iteration: ${2:-1}
max_iterations: 50
completion_promise: "$PROMISE"
started_at: "2026-01-01T00:00:00Z"
---

Work the task to completion.
EOF
}

hook_output() { # <dir> <transcript>  -- stdout and stderr, as an observer would see them
  ( cd "$1" && printf '{"transcript_path":"%s","session_id":""}' "$2" | bash "$HOOK" 2>&1 )
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

# The pattern under test, assembled rather than written out, so this file does not itself
# contain the literal string a repo-wide grep would be looking for.
TAG_OPEN="<$(printf 'promise')>"
TAG_CLOSE="</$(printf 'promise')>"
EMISSION="${TAG_OPEN}${PROMISE}${TAG_CLOSE}"

echo "Testing: the hook's output is not mistakable for a promise emission"
echo "==================================================================="

T=$(mktemp -d)
printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"still working"}]}}' \
  > "$T/no-promise.jsonl"
printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Done. ${EMISSION}\"}]}}" \
  > "$T/promise.jsonl"

# --- control: the fixture actually contains what we claim it does --------------------

check "control: the emission fixture carries the tagged pattern" "yes" \
  "$(grep -qF "$EMISSION" "$T/promise.jsonl" && echo yes || echo no)"

# --- property 1: the hook never emits the pattern ------------------------------------

D=$(mktemp -d); state_file "$D"
ONGOING=$(hook_output "$D" "$T/no-promise.jsonl")
check "an ordinary iteration's output does not contain the tagged pattern" "absent" \
  "$(echo "$ONGOING" | grep -qF "$EMISSION" && echo present || echo absent)"

# Checked separately from the pattern above: a reminder could avoid the exact tagged form
# and still emit a stray tag that a looser grep would catch.
check "and contains no promise tag at all" "absent" \
  "$(echo "$ONGOING" | grep -qF "$TAG_OPEN" && echo present || echo absent)"

D=$(mktemp -d); state_file "$D"
MATCHED=$(hook_output "$D" "$T/promise.jsonl")
check "the detection message does not contain the tagged pattern either" "absent" \
  "$(echo "$MATCHED" | grep -qF "$EMISSION" && echo present || echo absent)"

# --- property 2: the model still gets what it needs ----------------------------------
# Without these, deleting the reminder outright would pass everything above.

check "the ongoing reminder still states the exact promise text" "present" \
  "$(echo "$ONGOING" | grep -qF "$PROMISE" && echo present || echo absent)"

check "and still tells the model to use promise tags" "present" \
  "$(echo "$ONGOING" | grep -qi "promise tags" && echo present || echo absent)"

check "and still warns against emitting it untruthfully" "present" \
  "$(echo "$ONGOING" | grep -qi "do not lie" && echo present || echo absent)"

# --- the unambiguous marker ----------------------------------------------------------

check "a genuine match emits RALPH_PROMISE_MATCHED" "present" \
  "$(echo "$MATCHED" | grep -qF "RALPH_PROMISE_MATCHED" && echo present || echo absent)"

check "an ordinary iteration does not" "absent" \
  "$(echo "$ONGOING" | grep -qF "RALPH_PROMISE_MATCHED" && echo present || echo absent)"

# The marker is only useful if it is the hook's alone. The setup script runs once per loop
# and prints the promise instructions, so it is the other place a false positive could
# come from.
SETUP_OUT=$( cd "$(mktemp -d)" && bash "$SETUP" --completion-promise "$PROMISE" --max-iterations 5 Do the work 2>&1 )
check "the setup script does not emit the marker" "absent" \
  "$(echo "$SETUP_OUT" | grep -qF "RALPH_PROMISE_MATCHED" && echo present || echo absent)"

# --- what a run actually looks like --------------------------------------------------
# The end-to-end statement of the bug: across several ongoing iterations plus the final
# matched one, the tagged pattern must appear exactly as many times as the model emitted
# it -- which in hook output alone is zero.

D=$(mktemp -d); state_file "$D"
RUN=""
for _ in 1 2 3; do
  RUN="${RUN}$(hook_output "$D" "$T/no-promise.jsonl")"
done
RUN="${RUN}$(hook_output "$D" "$T/promise.jsonl")"
check "over a whole run, hook output contains zero tagged patterns" "0" \
  "$(printf '%s' "$RUN" | grep -oF "$EMISSION" | wc -l | tr -d ' ')"
check "and exactly one completion marker" "1" \
  "$(printf '%s' "$RUN" | grep -oF "RALPH_PROMISE_MATCHED" | wc -l | tr -d ' ')"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
