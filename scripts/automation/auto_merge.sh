#!/usr/bin/env bash
set -euo pipefail

# Auto-merge ZiggyStarClaw PRs when merge gates are satisfied.
# Policy (from Deano): merge only when:
# - CI passes
# - local tests pass (we run `zig build`)
# - chatgpt-review/codex feedback is addressed (incl. inline review comments)
# - all human comment threads are addressed
# Additionally: do NOT auto-merge if PR has label "no-auto-merge".

REPO="DeanoC/ZiggyStarClaw"

# Safety: only auto-merge PRs created by allowlisted authors.
# (Today this is just DeanoC; later we can add a dedicated Ziggy bot account.)
ALLOWED_AUTHORS=("DeanoC")

# Ensure we always run from the ZiggyStarClaw worktree root even if invoked from elsewhere.
repo_root=$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "${repo_root}" ]]; then
  echo "[auto-merge] ERROR: not inside a git repo" >&2
  exit 2
fi
cd "$repo_root"

log() { echo "[auto-merge] $*"; }

# Local sanity build (acts as our 'local tests')
log "Running local build: zig build"
zig build

prs=$(gh pr list --repo "$REPO" --state open --json number --jq '.[].number')
if [[ -z "${prs}" ]]; then
  log "No open PRs."
  exit 0
fi

for pr in $prs; do
  author=$(gh pr view "$pr" --repo "$REPO" --json author --jq '.author.login')
  allowed=false
  for a in "${ALLOWED_AUTHORS[@]}"; do
    if [[ "$author" == "$a" ]]; then
      allowed=true
      break
    fi
  done
  if [[ "$allowed" != "true" ]]; then
    log "PR #$pr author=$author not allowlisted; skipping"
    continue
  fi

  # Skip draft
  isDraft=$(gh pr view "$pr" --repo "$REPO" --json isDraft --jq '.isDraft')
  if [[ "$isDraft" == "true" ]]; then
    log "PR #$pr is draft; skipping"
    continue
  fi

  # Skip label no-auto-merge
  has_no_auto=$(gh pr view "$pr" --repo "$REPO" --json labels --jq '[.labels[].name] | any(.=="no-auto-merge")')
  if [[ "$has_no_auto" == "true" ]]; then
    log "PR #$pr has label no-auto-merge; skipping"
    continue
  fi

  mergeable=$(gh pr view "$pr" --repo "$REPO" --json mergeable --jq '.mergeable')

  # GitHub's mergeable field is eventually-consistent and can temporarily report UNKNOWN
  # right after label/check changes. If checks are green, do a short retry once.
  if [[ "$mergeable" == "UNKNOWN" ]]; then
    if gh pr checks "$pr" --repo "$REPO" >/tmp/zsc-pr-${pr}-checks.txt 2>&1; then
      log "PR #$pr mergeable=UNKNOWN but checks are green; retrying mergeable in 20s"
      sleep 20
      mergeable=$(gh pr view "$pr" --repo "$REPO" --json mergeable --jq '.mergeable')
    fi
  fi

  if [[ "$mergeable" != "MERGEABLE" ]]; then
    log "PR #$pr not mergeable ($mergeable); skipping"
    continue
  fi

  # CI gate: require checks to pass. gh exits non-zero if required checks fail.
  if ! gh pr checks "$pr" --repo "$REPO" >/tmp/zsc-pr-${pr}-checks.txt 2>&1; then
    log "PR #$pr checks not green; skipping"
    continue
  fi

  # Inline review comments gate (Option B policy):
  # - block on ANY human inline comments
  # - ALSO block on Codex bot inline comments (they're actionable feedback)
  # - ignore other bots
  inline_block=$(gh api "repos/DeanoC/ZiggyStarClaw/pulls/$pr/comments" \
    --jq 'map(.user.login) | any(. == "chatgpt-codex-connector[bot]" or (endswith("[bot]") | not))')
  if [[ "$inline_block" == "true" ]]; then
    log "PR #$pr has blocking inline review comments (human and/or codex bot); skipping"
    continue
  fi

  # Review decision gate:
  # - If GitHub has a decision and it isn't APPROVED, skip.
  # - If GitHub has NO decision (common when there are no formal reviews), we allow
  #   a lightweight "LGTM" signal from our Codex connector bot: a PR *issue comment*
  #   whose body contains a thumbs-up emoji.
  reviewDecision=$(gh pr view "$pr" --repo "$REPO" --json reviewDecision --jq '.reviewDecision // ""')
  if [[ -n "$reviewDecision" && "$reviewDecision" != "APPROVED" ]]; then
    log "PR #$pr reviewDecision=$reviewDecision; skipping"
    continue
  fi

  if [[ -z "$reviewDecision" ]]; then
    # Accept either:
    # - an issue comment whose body contains 👍, OR
    # - an issue reaction (+1) by the bot (often used as the "LGTM" signal).
    bot_lgtm_comment=$(gh api "repos/DeanoC/ZiggyStarClaw/issues/$pr/comments" \
      --jq 'map(select(.user.login == "chatgpt-codex-connector[bot]") | .body) | any(test("👍"))')

    bot_lgtm_reaction=$(gh api -H "Accept: application/vnd.github+json" "repos/DeanoC/ZiggyStarClaw/issues/$pr/reactions" \
      --jq 'map(select(.user.login == "chatgpt-codex-connector[bot]" and .content == "+1")) | length > 0')

    if [[ "$bot_lgtm_comment" != "true" && "$bot_lgtm_reaction" != "true" ]]; then
      log "PR #$pr has no GitHub APPROVED review and no bot LGTM (👍 comment or +1 reaction) from chatgpt-codex-connector[bot]; skipping"
      continue
    fi
  fi

  url=$(gh pr view "$pr" --repo "$REPO" --json url --jq '.url')
  title=$(gh pr view "$pr" --repo "$REPO" --json title --jq '.title')
  log "Merging PR #$pr: $title ($url)"

  gh pr merge "$pr" --repo "$REPO" --merge --delete-branch --admin
  log "Merged PR #$pr"
done
