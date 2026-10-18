#!/usr/bin/env bash
# Run the worker, then the reviewer, in _w. MODEL/EFFORT pick the coder; the
# reviewer is always Sonnet. Logged in by Workload Identity Federation
# (ANTHROPIC_API_KEY must stay unset or it overrides federation). Both run as the unprivileged user `agent`: no sudo, and
# a different uid, so they cannot read this script's or the refresher's
# /proc/*/environ. Writes /tmp/agent-summary.md, /tmp/review.md and /tmp/costs.txt.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN GH_TOKEN GITHUB_TOKEN
W="$PWD/_w"

# GitHub's OIDC token lasts ~5 minutes and each one is single-use, and Claude Code
# re-reads the file whenever it renews its Anthropic token, so keep it fresh. The
# refresher runs as `runner`; the file it writes is world-readable (umask 022).
# Each call writes its own temp file, so the background refresher and a foreground
# fetch never write into the same one; mv swaps a whole token in.
fetch_jwt() {
  local t
  t=$(mktemp "$ANTHROPIC_IDENTITY_TOKEN_FILE.XXXXXX") || return 1
  if curl -fsS -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
       "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=https://api.anthropic.com" | jq -er .value > "$t"; then
    chmod 644 "$t" && mv -f "$t" "$ANTHROPIC_IDENTITY_TOKEN_FILE"
  else
    rm -f "$t"
    return 1
  fi
}
fetch_jwt || { echo "::error::no GitHub OIDC token (is id-token: write set?)"; exit 1; }
( while sleep 120; do fetch_jwt || echo "::warning::OIDC refresh failed $(date -u +%T)"; done ) &
REFRESHER=$!
trap 'kill $REFRESHER 2>/dev/null || true' EXIT

# The agent user: owns the clone, can traverse to it and read the R library.
id agent >/dev/null 2>&1 || sudo useradd -m -s /bin/bash agent
sudo chown -R agent:agent "$W"
for p in "$W" ${R_LIBS_USER:+"$R_LIBS_USER"}; do
  d=$p; while [ "$d" != / ]; do sudo chmod o+x "$d"; d=$(dirname "$d"); done
done
[ -n "${R_LIBS_USER:-}" ] && [ -d "$R_LIBS_USER" ] && sudo chmod -R o+rX "$R_LIBS_USER"
# Never run git as runner in the clone: its .git/config is agent-writable, and
# core.fsmonitor or a clean filter would execute agent code as runner (sudo).
# Every git call on $W goes through ag_git, as agent, with fsmonitor off.

# Only what the agent needs; nothing else from this job's environment.
as_agent() {
  sudo -u agent env -i HOME=/home/agent PATH="$PATH" LANG=C.UTF-8 TZ=UTC CI=true \
    TMPDIR=/tmp R_LIBS_USER="${R_LIBS_USER:-}" R_LIBS_SITE="${R_LIBS_SITE:-}" \
    ANTHROPIC_ORGANIZATION_ID="$ANTHROPIC_ORGANIZATION_ID" \
    ANTHROPIC_SERVICE_ACCOUNT_ID="$ANTHROPIC_SERVICE_ACCOUNT_ID" \
    ANTHROPIC_FEDERATION_RULE_ID="$ANTHROPIC_FEDERATION_RULE_ID" \
    ANTHROPIC_WORKSPACE_ID="$ANTHROPIC_WORKSPACE_ID" \
    ANTHROPIC_IDENTITY_TOKEN_FILE="$ANTHROPIC_IDENTITY_TOKEN_FILE" \
    BASH_DEFAULT_TIMEOUT_MS=1200000 BASH_MAX_TIMEOUT_MS=1800000 \
    "$@"
}
# The same 100k context cap as Pete's local settings: past 100k tokens a Haiku 5.5
# request costs 5x, and without this the agent's fresh HOME has no cap at all
# (the 2026-10-18 Haiku run on panna#284 ran uncapped).
sudo -u agent mkdir -p /home/agent/.claude
printf '%s
' '{"modelSettings": {"claude-haiku-5-5": {"autoCompactWindow": 100000}}}'   | sudo -u agent tee /home/agent/.claude/settings.json >/dev/null
ag_git() { as_agent git -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$W" "$@"; }
ag_git config user.name "claude-agent-worker"
ag_git config user.email "github-actions[bot]@users.noreply.github.com"
base=$(ag_git rev-parse HEAD)

# 1. The work. Prompt files go in /tmp, readable by the agent.
sed -e "s/{{REPO}}/$REPO/g" -e "s/{{ISSUE}}/$ISSUE/g" "$HERE/worker-prompt.md" > /tmp/worker-prompt.md
cat /tmp/issue.md >> /tmp/worker-prompt.md
set +e
# The prompt goes on stdin: one argv string is capped at 128 KiB. OIDC tokens are
# single-use and the refresher rotates only every 2 minutes, so a Claude process
# starting soon after the last exchange could reuse a spent one (both reviewers
# failed that way on 2026-10-18): fetch a fresh one right before each start.
fetch_jwt || echo "::warning::fresh OIDC token fetch failed before the worker; it may fail to log in"
# timeout: a wall-clock cap, so a stuck run still leaves time for the review and
# the artifact upload inside the job's 120 minutes.
( cd "$W" && timeout 75m sudo -u agent env -i HOME=/home/agent PATH="$PATH" LANG=C.UTF-8 TZ=UTC CI=true     TMPDIR=/tmp R_LIBS_USER="${R_LIBS_USER:-}" R_LIBS_SITE="${R_LIBS_SITE:-}"     ANTHROPIC_ORGANIZATION_ID="$ANTHROPIC_ORGANIZATION_ID" ANTHROPIC_SERVICE_ACCOUNT_ID="$ANTHROPIC_SERVICE_ACCOUNT_ID"     ANTHROPIC_FEDERATION_RULE_ID="$ANTHROPIC_FEDERATION_RULE_ID" ANTHROPIC_WORKSPACE_ID="$ANTHROPIC_WORKSPACE_ID"     ANTHROPIC_IDENTITY_TOKEN_FILE="$ANTHROPIC_IDENTITY_TOKEN_FILE"     BASH_DEFAULT_TIMEOUT_MS=1200000 BASH_MAX_TIMEOUT_MS=1800000     claude -p --model "$MODEL" --effort "$EFFORT" \
    --max-budget-usd "$WORKER_BUDGET_USD" --max-turns 250 \
    --permission-mode dontAsk \
    --allowedTools "Read" "Edit" "Write" "Glob" "Grep" "Bash" "TodoWrite" "Task" \
    --output-format json --no-session-persistence < /tmp/worker-prompt.md ) > /tmp/worker.json
rc=$?
set -e
echo "worker exit $rc"
jq -c '{is_error, subtype, num_turns, duration_ms, total_cost_usd}' /tmp/worker.json || head -c 2000 /tmp/worker.json
# Full token and cache breakdown per model, so cost can be checked, not just trusted.
jq -c '{usage, modelUsage}' /tmp/worker.json 2>/dev/null | tee /tmp/worker-usage.json || true
echo "worker $MODEL (effort $EFFORT) \$$(jq -r '.total_cost_usd // 0' /tmp/worker.json), $(jq -r '.num_turns // 0' /tmp/worker.json) turns, $(( $(jq -r '.duration_ms // 0' /tmp/worker.json) / 60000 )) min, exit $rc" > /tmp/costs.txt
jq -r '.usage // {} | "worker tokens: input \(.input_tokens // 0), cache read \(.cache_read_input_tokens // 0), cache write \(.cache_creation_input_tokens // 0), output \(.output_tokens // 0)"' /tmp/worker.json >> /tmp/costs.txt 2>/dev/null || true
[ -s /tmp/agent-summary.md ] || jq -r '.result // "The worker wrote no summary."' /tmp/worker.json > /tmp/agent-summary.md

# Anything left uncommitted is committed here so it reaches the PR, and flagged.
# Untracked files over 5 MB (downloaded data the prompt said to keep in /tmp) are
# left out: they would bloat the PR or exceed GitHub's 100 MB push limit.
while IFS= read -r -d '' f; do
  if [ "$(sudo -u agent stat -c %s "$W/$f" 2>/dev/null || echo 0)" -gt 5000000 ]; then
    echo "/$f" | sudo -u agent tee -a "$W/.git/info/exclude" >/dev/null
    echo "LEFT OUT (over 5 MB, untracked): $f" >> /tmp/costs.txt
  fi
done < <(ag_git ls-files -z --others --exclude-standard)
if [ -n "$(ag_git status --porcelain)" ]; then
  ag_git add -A
  ag_git commit -q --no-verify -m "Uncommitted changes the worker left behind (issue #$ISSUE)"
  echo "UNCOMMITTED" >> /tmp/costs.txt
fi
n=$(ag_git rev-list --count "$base"..HEAD)
echo "commits=$n" >> "$GITHUB_OUTPUT"
if [ "$n" = 0 ]; then
  echo "Worker made no commits."
  exit 0
fi
# The commits travel to the deliver job as a bundle, made as agent.
ag_git bundle create /tmp/agent.bundle "$base"..HEAD || { echo "::error::git bundle create failed"; echo "BUNDLE FAILED" >> /tmp/costs.txt; exit 1; }

# 2. The review: read-only tools, the diff against dev only.
sed -e "s/{{REPO}}/$REPO/g" -e "s/{{ISSUE}}/$ISSUE/g" -e "s/{{BASE}}/$base/g" "$HERE/review-prompt.md" > /tmp/review-prompt.md
cat /tmp/issue.md >> /tmp/review-prompt.md
set +e
fetch_jwt || echo "::warning::fresh OIDC token fetch failed before the review; it may fail to log in"
( cd "$W" && as_agent claude -p --model sonnet --effort high \
    --max-budget-usd "$REVIEW_BUDGET_USD" --max-turns 60 \
    --permission-mode dontAsk \
    --allowedTools "Read" "Glob" "Grep" "Bash(git diff *)" "Bash(git log *)" "Bash(git show *)" \
    --output-format json --no-session-persistence < /tmp/review-prompt.md ) > /tmp/reviewer.json
set -e
jq -r '.result // "The reviewer returned nothing."' /tmp/reviewer.json > /tmp/review.md
echo "reviewer \$$(jq -r '.total_cost_usd // 0' /tmp/reviewer.json)" >> /tmp/costs.txt
cat /tmp/costs.txt
