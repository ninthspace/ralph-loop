# Ralph Loop Plugin (ninthspace fork)

Implementation of the Ralph Wiggum technique for iterative, self-referential AI development loops in Claude Code.

---

## About this fork

This is a fork of [`anthropics/claude-plugins-public/plugins/ralph-loop`](https://github.com/anthropics/claude-plugins-public/tree/main/plugins/ralph-loop),
Apache-2.0, © Anthropic. The first commit in this repository is the upstream plugin
unmodified, so every change here is visible as a diff against it.

Three behavioural changes, all in `hooks/stop-hook.sh`, each with its own suite:

| | Change | Landed |
|---|---|---|
| 1 | **Fail-closed extraction** — an unreadable transcript no longer ends the loop | 1.1.0 |
| 2 | **A reminder is not an emission** — the hook's own output is no longer mistakable for the model's completion promise | 1.2.0 |
| 3 | **The `active` field means something** — `active: false` pauses a loop without destroying it | 1.2.0 |

Everything else — the commands, the setup script, the prompt format, the state file schema —
is upstream's and is left alone. **1.2.0 is the version to install**: it is the first that
has all three, and `cpm:ralph` documents its behaviour against it.

### Fail-closed extraction

**The stop hook no longer deletes the loop's state file when it cannot read the
transcript.**

`.claude/ralph-loop.local.md` *is* the loop — the Stop hook reads it to decide whether to
block session exit and feed the prompt back. Delete it and the loop stops. Upstream
removes it and exits 0 on three transcript-reading failures:

| Situation | Upstream | This fork |
|---|---|---|
| Turn ends on a tool call (no text block) | continues | continues |
| Transcript file not found | **deletes the loop** | continues |
| No assistant records match the grep | **deletes the loop** | continues |
| `jq` cannot parse the records | **deletes the loop** | continues |
| Completion promise matched | ends the loop | ends the loop |
| `max_iterations` reached | ends the loop | ends the loop |

The reasoning is upstream's own. Its comment on the no-text-blocks case reads: *"empty
text means no `<promise>` tag, so the loop simply continues."* That holds for every other
way of failing to read the text — the extracted output feeds exactly one decision, whether
the promise was emitted, so failing to read it means *no promise this iteration*, not *the
loop is over*.

The costs are asymmetric. Continuing when it should have stopped wastes one iteration and
the promise is caught on the next pass. Stopping when it should have continued ends the
run silently: exit 0, no promise, no state file — indistinguishable from a completed run
for anyone reading the session afterwards. An unattended loop that dies this way looks
exactly like one that succeeded.

The `grep '"role":"assistant"'` case is the one worth singling out. It is an undeclared
dependency on Claude Code's JSONL key order and spacing. `tests/test-fail-closed.sh`
includes a transcript that is valid JSON with a single added space — `"role": "assistant"`
— and upstream deletes the loop on it. If that serialisation ever changes, every loop on
every machine ends silently and at once.

### Deliberately unchanged

Three deletions remain, all for a state file that is itself unusable: a non-numeric
`iteration`, a non-numeric `max_iterations`, and a body with no prompt text. Those are a
different class from a transcript that cannot be read, and are left as upstream has them.

### A reminder is not an emission

**Second change: the stop hook no longer prints the completion promise inside promise
tags.**

The loop ends when the model wraps its promise in `<promise>` tags, which makes the tagged
pattern the natural thing to grep a run for. Upstream puts that literal pattern into the
per-iteration reminder, so on a 24-iteration run a grep for the emission returns 24 hits
from the hook and none from the model until the last one. The hook is *instructing*, not
*emitting* — but a transcript does not record the difference, so an observer cannot tell a
loop that finished from one that was told how to finish, and neither can a script watching
the run.

The reminder now names the promise text and the tag separately:

```
🔄 Ralph iteration 8 | To stop, wrap this exact statement in promise tags: "SPEC_DELIVERED"
(ONLY when it is TRUE - do not lie to exit!)
```

The model still gets the exact string, the tag name, and the warning; they are simply not
adjacent. The detection message changed for the same reason, and gained a marker emitted
nowhere else:

```
✅ Ralph loop: RALPH_PROMISE_MATCHED at iteration 24 — "SPEC_DELIVERED"
```

So a run now answers two questions unambiguously:

| Question | Grep for |
|---|---|
| Did the model emit its promise? | `<promise>` — every occurrence is the model's |
| Did the loop complete? | `RALPH_PROMISE_MATCHED` |

`scripts/setup-ralph-loop.sh` still shows the tagged form once, when the loop starts, in
the block that teaches the format. That is deliberate — the model has to learn the exact
shape somewhere — and it is one occurrence per run rather than one per iteration.

### The `active` field means something

**Third change: `active: false` pauses the loop.**

Upstream writes `active: true` into every state file and never reads it; a loop is active
precisely while its file exists. A field named `active` that governs nothing is worse than
no field at all, because the obvious way to pause a run is to set it false — and doing that
has no effect whatsoever, silently. The only working stop was deleting the file, which
discards the prompt and the iteration count along with it.

The hook now reads it. Anything other than `true` allows the session to exit, and the state
file is left **completely untouched** — same iteration, same prompt, same field:

```sh
# pause
sed -i '' 's/^active: true/active: false/' .claude/ralph-loop.local.md

# resume, at the same iteration
sed -i '' 's/^active: false/active: true/' .claude/ralph-loop.local.md
```

A state file with no `active:` line at all runs, which is what every file written before
this change relies on — the same compatibility rule the `session_id` check already uses.

`/cancel-ralph` is unchanged and still deletes the file. Pause and cancel are now different
operations, which they were not before.

### Verifying

```sh
bash tests/test-fail-closed.sh      # 10 assertions
bash tests/test-active-field.sh     # 11 assertions
bash tests/test-promise-markers.sh  # 12 assertions
```

**`test-fail-closed.sh`** — six require the loop to survive an unreadable transcript; two
require it to still end on a matched promise and on the iteration cap (without those, a
hook that did nothing at all would pass); two require the hook to actually block the exit
and advance `iteration`. Run against upstream's hook it fails 4 of 10.

**`test-active-field.sh`** — that the field is read, that pausing leaves the file
byte-for-byte unchanged, and that resuming continues from the same iteration. Its controls
are the *active* cases: "allows the exit when paused" is also satisfied by a hook that has
stopped blocking anything at all.

**`test-promise-markers.sh`** — that no hook output carries the tagged pattern, *and* that
the reminder still states the promise text, the tag name and the do-not-lie warning —
without that second half, deleting the reminder outright would pass. It ends on a whole-run
check: three ongoing iterations plus a matched one must yield zero tagged patterns and
exactly one completion marker.

All three fork behaviours were verified by reverting the change and confirming the relevant
assertions fail — including the destructive variant of the pause, which the byte-for-byte
assertions exist to catch.

### Installing

```
/plugin marketplace add ninthspace/ralph-loop
/plugin install ralph-loop@ninthspace-ralph
```

Check what you got with `/plugin` — `ralph-loop@ninthspace-ralph` should read **1.2.0** or
later. Below that, some of the three changes above are simply not present, and the ones that
are missing fail quietly: a loop that ends silently, a transcript whose promise greps are all
the hook's own, a pause that does nothing.

Enable only one ralph plugin at a time. Two registered Stop hooks both fire on the same
session, and the state file only has to be deleted by one of them for the loop to die.

---

## What is Ralph Loop?

Ralph Loop is a development methodology based on continuous AI agent loops. As Geoffrey Huntley describes it: **"Ralph is a Bash loop"** - a simple `while true` that repeatedly feeds an AI agent a prompt file, allowing it to iteratively improve its work until completion.

This technique is inspired by the Ralph Wiggum coding technique (named after the character from The Simpsons), embodying the philosophy of persistent iteration despite setbacks.

### Core Concept

This plugin implements Ralph using a **Stop hook** that intercepts Claude's exit attempts:

```bash
# You run ONCE:
/ralph-loop "Your task description" --completion-promise "DONE"

# Then Claude Code automatically:
# 1. Works on the task
# 2. Tries to exit
# 3. Stop hook blocks exit
# 4. Stop hook feeds the SAME prompt back
# 5. Repeat until completion
```

The loop happens **inside your current session** - you don't need external bash loops. The Stop hook in `hooks/stop-hook.sh` creates the self-referential feedback loop by blocking normal session exit.

This creates a **self-referential feedback loop** where:
- The prompt never changes between iterations
- Claude's previous work persists in files
- Each iteration sees modified files and git history
- Claude autonomously improves by reading its own past work in files

## Quick Start

```bash
/ralph-loop "Build a REST API for todos. Requirements: CRUD operations, input validation, tests. Output <promise>COMPLETE</promise> when done." --completion-promise "COMPLETE" --max-iterations 50
```

Claude will:
- Implement the API iteratively
- Run tests and see failures
- Fix bugs based on test output
- Iterate until all requirements met
- Output the completion promise when done

## Commands

### /ralph-loop

Start a Ralph loop in your current session.

**Usage:**
```bash
/ralph-loop "<prompt>" --max-iterations <n> --completion-promise "<text>"
```

**Options:**
- `--max-iterations <n>` - Stop after N iterations (default: unlimited)
- `--completion-promise <text>` - Phrase that signals completion

### /cancel-ralph

Cancel the active Ralph loop.

**Usage:**
```bash
/cancel-ralph
```

## Prompt Writing Best Practices

### 1. Clear Completion Criteria

❌ Bad: "Build a todo API and make it good."

✅ Good:
```markdown
Build a REST API for todos.

When complete:
- All CRUD endpoints working
- Input validation in place
- Tests passing (coverage > 80%)
- README with API docs
- Output: <promise>COMPLETE</promise>
```

### 2. Incremental Goals

❌ Bad: "Create a complete e-commerce platform."

✅ Good:
```markdown
Phase 1: User authentication (JWT, tests)
Phase 2: Product catalog (list/search, tests)
Phase 3: Shopping cart (add/remove, tests)

Output <promise>COMPLETE</promise> when all phases done.
```

### 3. Self-Correction

❌ Bad: "Write code for feature X."

✅ Good:
```markdown
Implement feature X following TDD:
1. Write failing tests
2. Implement feature
3. Run tests
4. If any fail, debug and fix
5. Refactor if needed
6. Repeat until all green
7. Output: <promise>COMPLETE</promise>
```

### 4. Escape Hatches

Always use `--max-iterations` as a safety net to prevent infinite loops on impossible tasks:

```bash
# Recommended: Always set a reasonable iteration limit
/ralph-loop "Try to implement feature X" --max-iterations 20

# In your prompt, include what to do if stuck:
# "After 15 iterations, if not complete:
#  - Document what's blocking progress
#  - List what was attempted
#  - Suggest alternative approaches"
```

**Note**: The `--completion-promise` uses exact string matching, so you cannot use it for multiple completion conditions (like "SUCCESS" vs "BLOCKED"). Always rely on `--max-iterations` as your primary safety mechanism.

## Philosophy

Ralph embodies several key principles:

### 1. Iteration > Perfection
Don't aim for perfect on first try. Let the loop refine the work.

### 2. Failures Are Data
"Deterministically bad" means failures are predictable and informative. Use them to tune prompts.

### 3. Operator Skill Matters
Success depends on writing good prompts, not just having a good model.

### 4. Persistence Wins
Keep trying until success. The loop handles retry logic automatically.

## When to Use Ralph

**Good for:**
- Well-defined tasks with clear success criteria
- Tasks requiring iteration and refinement (e.g., getting tests to pass)
- Greenfield projects where you can walk away
- Tasks with automatic verification (tests, linters)

**Not good for:**
- Tasks requiring human judgment or design decisions
- One-shot operations
- Tasks with unclear success criteria
- Production debugging (use targeted debugging instead)

## Real-World Results

- Successfully generated 6 repositories overnight in Y Combinator hackathon testing
- One $50k contract completed for $297 in API costs
- Created entire programming language ("cursed") over 3 months using this approach

## Windows Compatibility

The stop hook uses a bash script that requires Git for Windows to run properly.

**Issue**: On Windows, the `bash` command may resolve to WSL bash (often misconfigured) instead of Git Bash, causing the hook to fail with errors like:
- `wsl: Unknown key 'automount.crossDistro'`
- `execvpe(/bin/bash) failed: No such file or directory`

**Workaround**: Edit the cached plugin's `hooks/hooks.json` to use Git Bash explicitly:

```json
"command": "\"C:/Program Files/Git/bin/bash.exe\" ${CLAUDE_PLUGIN_ROOT}/hooks/stop-hook.sh"
```

**Location**: `~/.claude/plugins/cache/claude-plugins-official/ralph-wiggum/<hash>/hooks/hooks.json`

**Note**: Use `Git/bin/bash.exe` (the wrapper with proper PATH), not `Git/usr/bin/bash.exe` (raw MinGW bash without utilities in PATH).

## Learn More

- Original technique: https://ghuntley.com/ralph/
- Ralph Orchestrator: https://github.com/mikeyobrien/ralph-orchestrator

## For Help

Run `/help` in Claude Code for detailed command reference and examples.
