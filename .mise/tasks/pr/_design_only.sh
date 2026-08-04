#!/usr/bin/env bash
# Does this branch add a new design document without the implementation that goes with it?
#
# `docs/design/NN-<feature>.md` and the code it describes belong to the same pull request
# (docs/development-process.md 2.11). A design-only PR splits one decision across two reviews: the
# user approves a document, the implementation lands later against a design nobody re-reads, and
# any drift between the two is invisible at merge time. `pr/status` calls this just before it would
# answer GREEN, so "CI is green on a document with no code" never counts as a finished flow.
#
# Deliberately narrow, because plenty of design-only diffs are legitimate:
#   - fires only when a *newly added* `docs/design/NN-*.md` is present (status `A`)
#   - never fires on edits to existing design docs (typos, addenda, decision reversals)
#   - never fires when the branch also touches implementation paths (§IMPL_PATHS below)
#
#   _design_only.sh [base-ref]   # base-ref defaults to origin/main
#
# Exit 0 (and prints the offending design docs) when the branch is design-only; exit 1 otherwise,
# including every error case -- a diff this cannot compute must not block a turn.
set -uo pipefail

# Everything a design document could plausibly be implemented in -- app code, tests, build inputs,
# and the harness itself (a design for a workflow or a mise task is implemented there, not in
# Swift). Erring wide keeps this quiet on PRs that do carry their implementation.
readonly IMPL_PATHS='^(Kikimi/|KikimiTests/|web/|tools/|\.mise/|\.claude/|\.github/|\.githooks/|Package\.swift|project\.yml)'

base_ref="${1:-origin/main}"

command -v git >/dev/null 2>&1 || exit 1
base="$(git merge-base HEAD "$base_ref" 2>/dev/null || true)"
[ -n "$base" ] || exit 1

changed="$(git diff --name-status "$base" HEAD 2>/dev/null || true)"
[ -n "$changed" ] || exit 1

# `$1 ~ /^A/`: git spells a plain addition `A`, and a rename-with-edit `R096` -- only the former is
# a genuinely new document. `$NF` (not `$2`) for the path, since rename rows carry two of them and
# the destination is the one that matters.
new_designs="$(printf '%s\n' "$changed" | awk '$1 == "A" && $NF ~ /^docs\/design\/[0-9]+-.*\.md$/ { print $NF }')"
[ -n "$new_designs" ] || exit 1

if printf '%s\n' "$changed" | awk '{ print $NF }' | grep -qE "$IMPL_PATHS"; then
  exit 1
fi

printf '%s\n' "$new_designs"
exit 0
