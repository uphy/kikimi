#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|NotebookEdit): refuse to modify a tracked file in the main checkout
# while it is on `main`.
#
# stdin: hook JSON payload, e.g. {"tool_name":"Edit","tool_input":{"file_path":"/abs/path.swift"}}
#
# Why this exists, when `build-before-commit.sh` already refuses to commit on `main`: that guard
# only fires on a command containing `git commit`. An agent that implements, builds, deploys with
# `mise run apply` and reports -- all without committing -- never trips it, and the work ends up
# stranded on `main` with no PR (observed 2026-08-04, CLAUDE.md "開発フロー: worktree + PR"). The
# flow needs a guard at the *entrance* (the first edit), not only at the exit.
#
# Deliberately narrow, so investigation on `main` stays frictionless:
# - files outside any git repository (memory, scratchpad, dotfiles) -> allowed
# - files inside a worktree (`.claude/worktrees/*`) -> allowed, that is the whole point
# - files inside the main checkout but git-ignored (CLAUDE.local.md, docs/references/chirami-map.md,
#   .build, build) -> allowed, they are local assets that never become a commit
# - anything else in the main checkout while HEAD is `main` -> blocked with the recovery command
#
# Escape hatch: KIKIMI_ALLOW_MAIN_EDIT=1.
set -uo pipefail

input="$(cat)"

if [[ "${KIKIMI_ALLOW_MAIN_EDIT:-}" == "1" ]]; then
  exit 0
fi

file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
if [[ -z "$file_path" ]]; then
  exit 0
fi

# A Write to a not-yet-existing file has no directory to ask git about, so walk up to the nearest
# ancestor that does exist.
probe="$(dirname "$file_path")"
while [[ ! -d "$probe" && "$probe" != "/" && -n "$probe" ]]; do
  probe="$(dirname "$probe")"
done
[[ -d "$probe" ]] || exit 0

toplevel="$(git -C "$probe" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$toplevel" ]] || exit 0

# `--git-common-dir` resolves to the main checkout's `.git` from inside any worktree, so its parent
# is the main checkout -- no path-string matching on `.claude/worktrees/` needed. Two traps:
# it prints a path relative to the git process's own cwd (so the `cd` has to happen inside
# `$probe`), and it must be compared against `--show-toplevel` in the *physical* form -- git always
# resolves symlinks, so a plain `pwd` would report `/var/...` against git's `/private/var/...` on
# macOS and silently classify the main checkout as a worktree.
common_dir="$(cd "$probe" && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
[[ -n "$common_dir" && "$common_dir" != "/" ]] || exit 0
main_checkout="$(dirname "$common_dir")"

# Inside a worktree: allowed.
[[ "$toplevel" == "$main_checkout" ]] || exit 0

branch="$(git -C "$probe" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[[ "$branch" == "main" ]] || exit 0

# Git-ignored files in the main checkout are local assets, never commits.
if git -C "$probe" check-ignore -q "$file_path" 2>/dev/null; then
  exit 0
fi

rel="${file_path#"$main_checkout"/}"
suggested="chore/$(basename "${rel%.*}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
[[ -n "$suggested" && "$suggested" != "chore/" ]] || suggested="chore/edit"

cat >&2 <<MSG
Refusing to edit \`$rel\` on \`main\`: this repository develops on worktrees and merges via PR
(CLAUDE.md "開発フロー: worktree + PR", docs/development-process.md 2.11). \`main\`'s ruleset
rejects direct pushes, so work left here cannot reach origin.

Do this instead, then repeat the edit:

  mise run wt <type>/<name> --move     # e.g. mise run wt $suggested --move
                                       # --move carries any uncommitted work over and restores main

then switch the session into the printed path with the EnterWorktree tool (passing \`path\`).
Committing needs the session's own cwd to be inside the worktree -- \`git -C <worktree>\` alone
still reads as \`main\` to the commit hook.

Investigation and conversation on \`main\` need no worktree; only edits to tracked files do.
Set KIKIMI_ALLOW_MAIN_EDIT=1 to override.
MSG
exit 2
