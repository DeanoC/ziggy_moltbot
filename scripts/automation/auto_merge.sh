#!/usr/bin/env bash
set -euo pipefail

# Auto-merge ZiggyStarClaw PRs when merge gates are satisfied.
# Policy (from Deano): merge only when:
# - CI passes
# - local tests pass (we run `zig build`)
# - chatgpt-review/codex feedback is addressed (incl. inline review comments)
# - all human comment threads are addressed
# Additionally: do NOT auto-merge if PR has label "no-auto-merge".

# Repo routing:
# - Default repo: DeanoC/ZiggyStarClaw
# - Override via ZIGGY_REPO or ZIGGY_ROUTING_TAG ([zsc] or [openclaw])
# - Allowlist via ZIGGY_ALLOWED_REPOS (comma/space separated)
DEFAULT_REPO="DeanoC/ZiggyStarClaw"
DEFAULT_ALLOWED_REPOS=("DeanoC/ZiggyStarClaw" "DeanoC/openclaw")
ROUTING_TAG="${ZIGGY_ROUTING_TAG:-}"
REPO=""

# Safety: only auto-merge PRs created by allowlisted authors.
# (Today this is just DeanoC; later we can add a dedicated Ziggy bot account.)
ALLOWED_AUTHORS=("DeanoC")

# To reduce "eventual consistency" races (late-arriving bot review comments, checks that
# register a moment after the first green poll, etc.), require a minimum age before
# merging self-authored PRs.
#
# Default: 180 seconds. Override with ZIGGY_SELF_MERGE_MIN_AGE_SECONDS.
SELF_MERGE_MIN_AGE_SECONDS="${ZIGGY_SELF_MERGE_MIN_AGE_SECONDS:-180}"

# Ensure we always run from the ZiggyStarClaw worktree root even if invoked from elsewhere.
repo_root=$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || true)
if [[ -z "${repo_root}" ]]; then
  echo "[auto-merge] ERROR: not inside a git repo" >&2
  exit 2
fi
cd "$repo_root"

log() { echo "[auto-merge] $*"; }

normalize_tag() {
  local tag="$1"
  tag="${tag#[}"
  tag="${tag%]}"
  tag="${tag,,}"
  echo "$tag"
}

resolve_repo() {
  local tag=""
  if [[ -n "${ZIGGY_REPO:-}" ]]; then
    echo "$ZIGGY_REPO"
    return 0
  fi

  if [[ -n "${ROUTING_TAG:-}" ]]; then
    tag="$(normalize_tag "$ROUTING_TAG")"
  elif [[ -n "${ZIGGY_WORK_ITEM_TAGS:-}" ]]; then
    if echo " $ZIGGY_WORK_ITEM_TAGS " | grep -qiE "(^|[[:space:],])\\[?openclaw\\]?([[:space:],]|$)"; then
      tag="openclaw"
    elif echo " $ZIGGY_WORK_ITEM_TAGS " | grep -qiE "(^|[[:space:],])\\[?zsc\\]?([[:space:],]|$)"; then
      tag="zsc"
    fi
  fi

  case "$tag" in
    openclaw) echo "DeanoC/openclaw" ;;
    zsc|"") echo "$DEFAULT_REPO" ;;
    *)
      log "ERROR: unknown routing tag '$tag'. Expected [zsc] or [openclaw]." >&2
      return 2
      ;;
  esac
}

load_allowed_repos() {
  local raw="${ZIGGY_ALLOWED_REPOS:-}"
  if [[ -z "$raw" ]]; then
    ALLOWED_REPOS=("${DEFAULT_ALLOWED_REPOS[@]}")
    return 0
  fi

  raw="${raw//,/ }"
  read -r -a ALLOWED_REPOS <<<"$raw"
}

repo_in_allowlist() {
  local repo="$1"
  local allowed
  for allowed in "${ALLOWED_REPOS[@]}"; do
    if [[ "$allowed" == "$repo" ]]; then
      return 0
    fi
  done
  return 1
}

has_upstream_opt_in() {
  if [[ "${ZIGGY_ALLOW_UPSTREAM:-}" =~ ^(1|true|TRUE|yes|YES)$ ]]; then
    return 0
  fi
  if [[ -n "${ZIGGY_WORK_ITEM_TAGS:-}" ]] && echo " $ZIGGY_WORK_ITEM_TAGS " | grep -qiE "(^|[[:space:],])\\[?(upstream|allow-upstream)\\]?([[:space:],]|$)"; then
    return 0
  fi
  if [[ -n "${ZIGGY_UPSTREAM_TAG:-}" ]]; then
    return 0
  fi
  return 1
}

ensure_repo_allowed() {
  local repo="$1"
  local owner="${repo%%/*}"
  if ! repo_in_allowlist "$repo"; then
    log "ERROR: repo '$repo' is not in allowlist. Set ZIGGY_ALLOWED_REPOS to override." >&2
    return 3
  fi
  if [[ "$owner" != "DeanoC" ]]; then
    if ! has_upstream_opt_in; then
      log "ERROR: repo '$repo' is outside DeanoC. Add explicit upstream opt-in tag (e.g., 'upstream' or 'allow-upstream') or set ZIGGY_ALLOW_UPSTREAM=1." >&2
      return 4
    fi
  fi
  return 0
}

run_check_case() {
  local name="$1"
  shift
  (
    set -euo pipefail
    eval "$@"
    REPO="$(resolve_repo)"
    load_allowed_repos
    ensure_repo_allowed "$REPO"
  ) >/dev/null
}

self_check() {
  log "Running allowlist self-check"

  run_check_case "default repo" \
    'ZIGGY_REPO="DeanoC/ZiggyStarClaw" ZIGGY_ALLOWED_REPOS="" ZIGGY_ALLOW_UPSTREAM="" ZIGGY_WORK_ITEM_TAGS=""'

  if run_check_case "upstream without opt-in" \
    'ZIGGY_REPO="openclaw/openclaw" ZIGGY_ALLOWED_REPOS="openclaw/openclaw" ZIGGY_ALLOW_UPSTREAM=""'; then
    log "Self-check failed: upstream repo allowed without explicit opt-in" >&2
    return 10
  fi

  run_check_case "upstream with opt-in" \
    'ZIGGY_REPO="openclaw/openclaw" ZIGGY_ALLOWED_REPOS="openclaw/openclaw" ZIGGY_ALLOW_UPSTREAM=1'

  log "Self-check OK"
}

if [[ "${1:-}" == "--check" ]]; then
  self_check
  exit 0
fi

REPO="$(resolve_repo)"
load_allowed_repos
ensure_repo_allowed "$REPO"
log "Using repo: $REPO"

epoch_seconds() {
  # GNU date on Linux supports -d; return 0 on parse failure.
  date -d "$1" +%s 2>/dev/null || echo 0
}

has_min_age_for_self_merge() {
  local pr_number="$1"
  local pr_author="$2"

  if [[ "$pr_author" != "DeanoC" ]]; then
    return 0
  fi

  local updated_at now_s updated_s age_s
  updated_at=$(gh pr view "$pr_number" --repo "$REPO" --json updatedAt --jq '.updatedAt')
  now_s=$(date +%s)
  updated_s=$(epoch_seconds "$updated_at")

  if [[ "$updated_s" -le 0 ]]; then
    # If we can't parse time, be conservative.
    return 1
  fi

  age_s=$((now_s - updated_s))
  if [[ "$age_s" -lt "$SELF_MERGE_MIN_AGE_SECONDS" ]]; then
    log "PR #$pr_number is self-authored and only ${age_s}s old (< ${SELF_MERGE_MIN_AGE_SECONDS}s); waiting to reduce race risk"
    return 1
  fi
  return 0
}

has_blocking_review_threads() {
  local pr_number="$1"
  local owner repo
  owner=${REPO%%/*}
  repo=${REPO##*/}

  # GraphQL: reviewThreads contain isResolved state (the "Resolve conversation" feature).
  # We block if there exists any UNRESOLVED thread where at least one comment author is:
  # - a human (login does NOT end with [bot])
  # - OR the codex connector bot (actionable feedback)
  # Other bots are ignored.
  gh api graphql \
    -F owner="$owner" \
    -F repo="$repo" \
    -F prNumber="$pr_number" \
    -f query='query($owner: String!, $repo: String!, $prNumber: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $prNumber) {
          reviewThreads(first: 100) {
            nodes {
              isResolved
              comments(first: 50) {
                nodes { author { login } }
              }
            }
          }
        }
      }
    }' \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[]? 
            | select(.isResolved == false)
            | (.comments.nodes[]?.author.login // "")
          ]
          | any(. == "chatgpt-codex-connector[bot]" or (endswith("[bot]") | not))'
}

prs=$(gh pr list --repo "$REPO" --state open --json number --jq '.[].number')
if [[ -z "${prs}" ]]; then
  log "No open PRs."
  exit 0
fi

# We only run the local build if we actually have at least one PR that passes all
# remote gates (checks/reviews/threads) and is ready to merge. This avoids doing
# expensive work when CI is pending/stuck.
need_local_build=false
merge_queue=()

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

  # Review thread gate (uses the "Resolve conversation" mechanism):
  # Block if any UNRESOLVED review thread contains a human comment OR Codex bot comment.
  # This is more robust than scanning raw inline review comments.
  if [[ "$(has_blocking_review_threads "$pr")" == "true" ]]; then
    log "PR #$pr has unresolved blocking review threads (human and/or codex bot); skipping"
    continue
  fi

  # Minimum age gate for self-authored PRs.
  if ! has_min_age_for_self_merge "$pr" "$author"; then
    continue
  fi

  # Review decision gate:
  # GitHub does not allow authors to approve their own PRs. For a solo-maintainer
  # repo, requiring APPROVED blocks self-authored PRs forever.
  #
  # Policy:
  # - Always block CHANGES_REQUESTED.
  # - If APPROVED, great.
  # - If there is no decision / review required and the author is DeanoC, allow merge
  #   once checks are green and there are no unresolved blocking review threads.
  # - Otherwise (non-self-authored), require either GitHub APPROVED OR a lightweight
  #   "LGTM" signal from our Codex connector bot (👍 comment or +1 reaction).
  reviewDecision=$(gh pr view "$pr" --repo "$REPO" --json reviewDecision --jq '.reviewDecision // ""')

  if [[ "$reviewDecision" == "CHANGES_REQUESTED" ]]; then
    log "PR #$pr reviewDecision=CHANGES_REQUESTED; skipping"
    continue
  fi

  if [[ -n "$reviewDecision" && "$reviewDecision" != "APPROVED" ]]; then
    if [[ "$author" == "DeanoC" ]]; then
      log "PR #$pr reviewDecision=$reviewDecision but author=DeanoC (self-authored); allowing on green checks"
    else
      log "PR #$pr reviewDecision=$reviewDecision; skipping"
      continue
    fi
  fi

  if [[ -z "$reviewDecision" ]]; then
    if [[ "$author" != "DeanoC" ]]; then
      # Accept either:
      # - an issue comment whose body contains 👍, OR
      # - an issue reaction (+1) by the bot (often used as the "LGTM" signal).
      bot_lgtm_comment=$(gh api "repos/$REPO/issues/$pr/comments" \
        --jq 'map(select(.user.login == "chatgpt-codex-connector[bot]") | .body) | any(test("👍"))')

      bot_lgtm_reaction=$(gh api -H "Accept: application/vnd.github+json" "repos/$REPO/issues/$pr/reactions" \
        --jq 'map(select(.user.login == "chatgpt-codex-connector[bot]" and .content == "+1")) | length > 0')

      if [[ "$bot_lgtm_comment" != "true" && "$bot_lgtm_reaction" != "true" ]]; then
        log "PR #$pr has no GitHub APPROVED review and no bot LGTM (👍 comment or +1 reaction) from chatgpt-codex-connector[bot]; skipping"
        continue
      fi
    fi
  fi

  # Passed all remote gates; queue it for merge after local build.
  merge_queue+=("$pr")
  need_local_build=true
done

if [[ "${#merge_queue[@]}" -eq 0 ]]; then
  log "No PRs are ready to merge (most likely CI/reviews still pending)."
  exit 0
fi

# Local sanity build (acts as our 'local tests')
log "Running local build: zig build (required before auto-merge)"
zig build

for pr in "${merge_queue[@]}"; do
  url=$(gh pr view "$pr" --repo "$REPO" --json url --jq '.url')
  title=$(gh pr view "$pr" --repo "$REPO" --json title --jq '.title')
  log "Merging PR #$pr: $title ($url)"

  gh pr merge "$pr" --repo "$REPO" --merge --delete-branch --admin
  log "Merged PR #$pr"
done
