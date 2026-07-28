#!/bin/bash

# Ralph Loop Stop Hook
# Prevents session exit when a ralph-loop is active
# Feeds Claude's output back as input to continue the loop

set -euo pipefail

# Read hook input from stdin (advanced stop hook API)
HOOK_INPUT=$(cat)

# Check if ralph-loop is active
RALPH_STATE_FILE=".claude/ralph-loop.local.md"

if [[ ! -f "$RALPH_STATE_FILE" ]]; then
  # No active loop - allow exit
  exit 0
fi

# Parse markdown frontmatter (YAML between ---) and extract values
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
# Extract completion_promise and strip surrounding quotes if present
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')

# Session isolation: the state file is project-scoped, but the Stop hook
# fires in every Claude Code session in that project. If another session
# started the loop, this session must not block (or touch the state file).
# Legacy state files without session_id fall through (preserves old behavior).
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//' || true)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')
if [[ -n "$STATE_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

# CHANGED FROM UPSTREAM (ninthspace fork): the `active:` field is now read.
# See "The `active` field means something" in README.md.
#
# The setup script writes `active: true` and upstream never looks at it -- the loop is
# "active" precisely while the file exists. A field named `active` that does nothing is
# worse than no field: the obvious way to pause a loop is to set it false, and doing that
# has no effect whatsoever, silently. The only working stop is deleting the file, which
# discards the prompt and the iteration count with it.
#
# Reading it costs three lines and makes the name honest. Anything other than `true` is
# treated as paused: the hook allows the exit and leaves the file completely alone, so
# setting it back to `true` resumes the same loop at the same iteration.
#
# Absent field falls through as active, which is what every state file written before this
# change relies on -- the same compatibility rule as `session_id` above.
LOOP_ACTIVE=$(echo "$FRONTMATTER" | grep '^active:' | sed 's/active: *//' | tr -d '[:space:]' || true)
if [[ -n "$LOOP_ACTIVE" ]] && [[ "$LOOP_ACTIVE" != "true" ]]; then
  exit 0
fi

# Validate numeric fields before arithmetic operations
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Ralph loop: State file corrupted" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: 'iteration' field is not a valid number (got: '$ITERATION')" >&2
  echo "" >&2
  echo "   This usually means the state file was manually edited or corrupted." >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Ralph loop: State file corrupted" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: 'max_iterations' field is not a valid number (got: '$MAX_ITERATIONS')" >&2
  echo "" >&2
  echo "   This usually means the state file was manually edited or corrupted." >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Check if max iterations reached
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "🛑 Ralph loop: Max iterations ($MAX_ITERATIONS) reached."
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Get transcript path from hook input
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

# CHANGED FROM UPSTREAM (ninthspace fork): the three branches below no longer delete the
# state file. See "Fail-closed extraction" in README.md.
#
# LAST_OUTPUT feeds exactly one decision: whether the completion promise was emitted. So
# any failure to read it means "no promise this iteration" -- which is what an empty
# string already encodes -- and not "the loop is over". Deleting the state file here ends
# the run silently: exit 0, no promise, no state file, which is byte-for-byte what a
# successful completion looks like to anyone reading the session afterwards.
#
# The costs are asymmetric. Continuing when we should have stopped costs one iteration,
# and the promise is detected on the next pass. Stopping when we should have continued
# costs the entire run, invisibly. Upstream already applies this reasoning to the
# "no text blocks" case (see the `last // ""` comment below); this fork applies it to the
# remaining extraction failures.
#
# The `grep '"role":"assistant"'` below is the one worth noticing: it is an undeclared
# dependency on Claude Code's JSONL key order and spacing. If that serialisation ever
# changes, the grep matches nothing on every machine at once -- so this branch in
# particular must not be able to delete anything.
LAST_OUTPUT=""
EXTRACT_NOTE=""

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  EXTRACT_NOTE="transcript file not found at $TRANSCRIPT_PATH"
else
  # Read last assistant message from transcript (JSONL format - one JSON per line)
  LAST_LINES=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -n 100) || LAST_LINES=""

  if [[ -z "$LAST_LINES" ]]; then
    EXTRACT_NOTE="no assistant messages found in $TRANSCRIPT_PATH"
  else
    # Parse the recent lines and pull out the final text block.
    # `last // ""` yields empty string when no text blocks exist (e.g. a turn
    # that is all tool calls). That's fine: empty text means no <promise> tag,
    # so the loop simply continues.
    # (Briefly disable errexit so a jq failure can be caught by the $? check.)
    set +e
    LAST_OUTPUT=$(echo "$LAST_LINES" | jq -rs '
      map(.message.content[]? | select(.type == "text") | .text) | last // ""
    ' 2>&1)
    JQ_EXIT=$?
    set -e

    if [[ $JQ_EXIT -ne 0 ]]; then
      EXTRACT_NOTE="could not parse assistant message JSON: $LAST_OUTPUT"
      LAST_OUTPUT=""
    fi
  fi
fi

if [[ -n "$EXTRACT_NOTE" ]]; then
  echo "⚠️  Ralph loop: $EXTRACT_NOTE" >&2
  echo "   The completion promise cannot be checked this iteration." >&2
  echo "   Continuing the loop -- the state file is left in place. Stop it with" >&2
  echo "   /cancel-ralph, or by deleting $RALPH_STATE_FILE." >&2
fi

# Check for completion promise (only if set)
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  # Extract text from <promise> tags using Perl for multiline support
  # -0777 slurps entire input, s flag makes . match newlines
  # .*? is non-greedy (takes FIRST tag), whitespace normalized
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

  # Use = for literal string comparison (not pattern matching)
  # == in [[ ]] does glob pattern matching which breaks with *, ?, [ characters
  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
    # RALPH_PROMISE_MATCHED is the marker to grep a run for. It is emitted here and
    # nowhere else -- not by the setup script, not by the per-iteration reminder -- so it
    # answers "did this loop actually complete?" without the ambiguity the tags carry.
    echo "✅ Ralph loop: RALPH_PROMISE_MATCHED at iteration $ITERATION — \"$COMPLETION_PROMISE\""
    rm "$RALPH_STATE_FILE"
    exit 0
  fi
fi

# Not complete - continue loop with SAME PROMPT
NEXT_ITERATION=$((ITERATION + 1))

# Extract prompt (everything after the closing ---)
# Skip first --- line, skip until second --- line, then print everything after
# Use i>=2 instead of i==2 to handle --- in prompt content
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "⚠️  Ralph loop: State file corrupted or incomplete" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: No prompt text found" >&2
  echo "" >&2
  echo "   This usually means:" >&2
  echo "     • State file was manually edited" >&2
  echo "     • File was corrupted during writing" >&2
  echo "" >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Update iteration in frontmatter (portable across macOS and Linux)
# Create temp file, then atomically replace
TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$RALPH_STATE_FILE"

# Build system message with iteration count and completion promise info.
#
# CHANGED FROM UPSTREAM (ninthspace fork): this reminder no longer spells the promise
# inside its own tags. See "A reminder is not an emission" in README.md.
#
# Upstream emitted the literal promise-in-tags here, once per iteration. A model reads
# that as an instruction, but a transcript does not record the difference -- so grepping a
# run for the emission matches the hook's own reminder every iteration, and an observer
# cannot tell a loop that finished from one that was merely told how to finish. On a
# 24-iteration run that is 24 false positives and no true one.
#
# The model still gets the exact text and the tag name. They are simply not adjacent, so
# the emission pattern belongs to the model alone.
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="🔄 Ralph iteration $NEXT_ITERATION | To stop, wrap this exact statement in promise tags: \"$COMPLETION_PROMISE\" (ONLY when it is TRUE - do not lie to exit!)"
else
  SYSTEM_MSG="🔄 Ralph iteration $NEXT_ITERATION | No completion promise set - loop runs infinitely"
fi

# Output JSON to block the stop and feed prompt back
# The "reason" field contains the prompt that will be sent back to Claude
jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

# Exit 0 for successful hook execution
exit 0
