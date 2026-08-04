#!/usr/bin/env bash
# Stop hook: refuse to end a turn while a worktree holds commits that have not reached a green PR.
#
# stdin: hook JSON payload, e.g. {"cwd":"/abs/worktree","stop_hook_active":false}
#
# This is the tail half of the worktree + PR flow (docs/development-process.md 2.11). The entrance
# is guarded by `no-edit-on-main.sh` (no edits on `main`); this guards the exit, so that "実装した
# のに PR を作らずに報告して終わる" is structurally impossible. The human's only checkpoint is
# reviewing and merging the PR -- everything between the first commit and a green CI is mechanical
# and belongs to the agent.
#
# The line is the first commit, on purpose: while the work is still uncommitted the agent may ask
# a question and stop, exactly as before. Committing is the act that opts into the rest of the flow.
#
# It never sleeps. It returns immediately with the next action; `mise run pr:wait` is where actual
# waiting happens, and the agent runs that itself.
#
#   allowed to stop : not a worktree / no commits of its own / PR required checks green
#   blocked         : unpushed / no PR / checks pending / checks failing / design doc without code
#
# Two independent runaway guards, since a Stop hook that always blocks would loop forever:
#   - FAILING is auto-retried at most MAX_FIX_ATTEMPTS times per PR, then the turn is allowed to end
#     so a human can look at a failure the agent evidently cannot fix.
#   - any state repeating MAX_SAME_STATE times in a row releases the turn regardless.
# Escape hatch: KIKIMI_SKIP_PR_FLOW_GUARD=1.
set -uo pipefail

readonly MAX_FIX_ATTEMPTS=3
readonly MAX_SAME_STATE=6

[[ "${KIKIMI_SKIP_PR_FLOW_GUARD:-}" == "1" ]] && exit 0

input="$(cat)"
hook_cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[[ -n "$hook_cwd" && -d "$hook_cwd" ]] || exit 0
cd "$hook_cwd" || exit 0

command -v git >/dev/null 2>&1 || exit 0
toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$toplevel" ]] || exit 0

# Prefer the branch's own copy of the status script (so a PR that changes the flow is judged by the
# rules it is proposing), falling back to the main checkout's.
status_script="$toplevel/.mise/tasks/pr/status"
if [[ ! -x "$status_script" ]]; then
  common_dir="$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo /)" 2>/dev/null && pwd)"
  status_script="$(dirname "${common_dir:-/}")/.mise/tasks/pr/status"
fi
[[ -x "$status_script" ]] || exit 0

detail="$("$status_script" 2>&1 >/dev/null)"
state="$("$status_script" 2>/dev/null)"

case "$state" in
  NOT_A_WORKTREE|NO_COMMITS|GREEN|'')
    # Nothing outstanding: clear the counters so the next PR starts from zero.
    rm -f "$(git rev-parse --git-common-dir)/kikimi-pr-flow-state" 2>/dev/null
    exit 0
    ;;
esac

pr_number="$(gh pr view --json number --jq .number 2>/dev/null || echo none)"
state_file="$(git rev-parse --git-common-dir)/kikimi-pr-flow-state"

prev_pr='' prev_state='' same_count=0 fix_attempts=0
if [[ -f "$state_file" ]]; then
  IFS='|' read -r prev_pr prev_state same_count fix_attempts < "$state_file" || true
fi
[[ "$prev_pr" == "$pr_number" ]] || { prev_state=''; same_count=0; fix_attempts=0; }
if [[ "$prev_state" == "$state" ]]; then
  same_count=$((same_count + 1))
else
  same_count=1
fi
[[ "$state" == "FAILING" ]] && fix_attempts=$((fix_attempts + 1))
printf '%s|%s|%s|%s' "$pr_number" "$state" "$same_count" "$fix_attempts" > "$state_file"

if [[ "$state" == "FAILING" && "$fix_attempts" -gt "$MAX_FIX_ATTEMPTS" ]]; then
  echo "[pr-flow-guard] CI has stayed red across $MAX_FIX_ATTEMPTS automatic fix attempts; releasing the turn so a human can weigh in." >&2
  exit 0
fi
if [[ "$same_count" -gt "$MAX_SAME_STATE" ]]; then
  echo "[pr-flow-guard] state '$state' repeated $MAX_SAME_STATE times without advancing; releasing the turn." >&2
  exit 0
fi

case "$state" in
  UNPUSHED)
    next='Push the branch: `git push -u origin HEAD`. The pre-push hook runs `mise run test` first.'
    ;;
  NO_PR)
    next='Open the pull request: `gh pr create --title "<conventional-commit style title>" --body "<症状 / 原因 / 修正 / 確認>"`.
Follow the shape of the recent merged PRs (Japanese body, a 変更ファイル table, and an explicit note
on what still needs the user'"'"'s UI verification).'
    ;;
  PENDING)
    next='Wait for the required checks in the FOREGROUND: `mise run pr:wait` (it exits as soon as they
pass or one fails; Build & test takes about 4 minutes). Do not background it -- this hook fires again
the moment you stop, and only a concluded result advances the flow.'
    ;;
  DESIGN_ONLY)
    next='Implement the design in THIS pull request -- design and implementation ship together
(docs/development-process.md 2.11). Write the code and its layer-1 tests against the design doc
listed above, commit, push, and run `mise run pr:wait` again. Do not open a follow-up PR for the
implementation, and do not report the design as finished work on its own.
(If this really is a standalone document -- a design reversal, an addendum -- set
KIKIMI_ALLOW_DESIGN_ONLY_PR=1 and say so in the PR body.)'
    ;;
  FAILING)
    next="Fix CI (automatic attempt $fix_attempts of $MAX_FIX_ATTEMPTS). Read the failing job:
  \`gh run view --log-failed\`   (or open the link above)
then fix the cause, commit, push, and run \`mise run pr:wait\` again. Reproduce locally first where
you can -- \`mise run lint\` / \`mise run test\` / \`mise run build\` mirror the three required checks."
    ;;
esac

cat >&2 <<MSG
[pr-flow-guard] Not done yet: $state

$detail

$next

The turn ends when the required checks are green. Merging stays the user's call -- never merge.
(Set KIKIMI_SKIP_PR_FLOW_GUARD=1 to bypass this guard.)
MSG
exit 2
