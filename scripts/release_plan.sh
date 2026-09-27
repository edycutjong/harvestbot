#!/usr/bin/env bash
# Plan the next semver release from Angular/conventional commits since the highest v* tag.
# Usage: scripts/release_plan.sh [REF=HEAD] [NOTES_FILE=release-notes.md]
# Prints `skip=true|false`, `prev=<tag>`, `next=<tag>` (GITHUB_OUTPUT format) and writes grouped notes.
#   feat → minor · fix/perf → patch · `type!:` / BREAKING CHANGE → major · anything else → no release.
set -euo pipefail

REF="${1:-HEAD}"
NOTES="${2:-release-notes.md}"
SITE="https://harvestbot.edycu.dev"
REPO_URL="https://github.com/edycutjong/harvestbot"

# Highest semver tag in the repo (not just the nearest ancestor) so concurrent/out-of-order runs never reuse a number.
PREV=$(git tag -l 'v[0-9]*' --sort=-v:refname | head -n1)
if [ -n "$PREV" ] && git merge-base --is-ancestor "$REF" "$PREV"; then
  echo "skip=true"; echo "reason=$REF is already contained in $PREV"; exit 0
fi
if [ -z "$PREV" ]; then RANGE="$REF"; CUR="0.0.0"; else RANGE="$PREV..$REF"; CUR="${PREV#v}"; fi

LOG=$(git log --no-merges --format=%B "$RANGE")
BUMP="none"
if echo "$LOG" | grep -qE '^[a-z]+(\([^)]*\))?!:|^BREAKING CHANGE:'; then
  BUMP="major"
elif echo "$LOG" | grep -qE '^feat(\([^)]*\))?:'; then
  BUMP="minor"
elif echo "$LOG" | grep -qE '^(fix|perf)(\([^)]*\))?:'; then
  BUMP="patch"
fi
if [ "$BUMP" = "none" ]; then echo "skip=true"; echo "reason=no feat/fix/perf commits in $RANGE"; exit 0; fi

IFS=. read -r MA MI PA <<<"$CUR"
case "$BUMP" in
  major) MA=$((MA + 1)); MI=0; PA=0 ;;
  minor) MI=$((MI + 1)); PA=0 ;;
  patch) PA=$((PA + 1)) ;;
esac
NEXT="v${MA}.${MI}.${PA}"

# ── Grouped notes from commit subjects (commits land on main directly, so label-based
#    generated notes alone would be empty; GitHub's PR notes are appended by the workflow).
declare -a FEAT=() FIX=() SEC=() DOCS=() CHORE=() DEPS=()
while IFS=$'\t' read -r SHA AUTHOR SUBJ; do
  [ -z "$SHA" ] && continue
  LINE="- ${SUBJ} ([\`${SHA}\`](${REPO_URL}/commit/${SHA}))"
  if [[ "$AUTHOR" == dependabot* ]] || [[ "$SUBJ" =~ ^[a-z]+\(deps(-dev)?\): ]]; then DEPS+=("$LINE")
  elif [[ "$SUBJ" =~ ^security(\(.*\))?!?: ]] || [[ "$SUBJ" =~ ^[a-z]+\((security|sec)\)!?: ]]; then SEC+=("$LINE")
  elif [[ "$SUBJ" =~ ^feat(\(.*\))?!?: ]]; then FEAT+=("$LINE")
  elif [[ "$SUBJ" =~ ^(fix|perf)(\(.*\))?!?: ]]; then FIX+=("$LINE")
  elif [[ "$SUBJ" =~ ^docs(\(.*\))?!?: ]]; then DOCS+=("$LINE")
  else CHORE+=("$LINE")
  fi
done < <(git log --no-merges --format='%h%x09%an%x09%s' "$RANGE")

section() { # title, lines...
  local title="$1"; shift
  [ "$#" -eq 0 ] && return 0
  printf '### %s\n\n' "$title"; printf '%s\n' "$@"; printf '\n'
}

{
  printf '**Live:** [site](%s/) · [verify on chain](%s/verify/) · [judge in 30 s](%s/judge/) · [pitch deck](%s/deck/)\n\n' "$SITE" "$SITE" "$SITE" "$SITE"
  # shellcheck disable=SC2016 # literal backticks are Markdown
  printf 'Robinhood Chain testnet (46630). Attached: `deployments-46630.json` (system addresses), `receipts-46630.json` (the three beats), `bench-results.json` (Stylus vs Solidity gas).\n\n'
  printf '## What changed since %s\n\n' "${PREV:-the first commit}"
  section "🚀 Features" ${FEAT[@]+"${FEAT[@]}"}
  section "🐛 Fixes" ${FIX[@]+"${FIX[@]}"}
  section "🔒 Security" ${SEC[@]+"${SEC[@]}"}
  section "📝 Docs" ${DOCS[@]+"${DOCS[@]}"}
  section "🧰 CI / Chores" ${CHORE[@]+"${CHORE[@]}"}
  section "📦 Dependencies" ${DEPS[@]+"${DEPS[@]}"}
} >"$NOTES"

echo "skip=false"
echo "prev=${PREV}"
echo "next=${NEXT}"
