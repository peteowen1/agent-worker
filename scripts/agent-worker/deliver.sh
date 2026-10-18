#!/usr/bin/env bash
# Runs in the deliver job, on a fresh machine, from the work job's artifact in _out/:
# agent.bundle (the commits) and the summary, review and cost files. Commits ->
# push the branch and open a PR into dev. No commits, a refused branch, or any
# failure here -> say why on the issue. Every path that is not a delivered PR ends
# in report_failure (also on an unexpected exit, via the trap), so agent-working
# always comes off and a failed run never wedges the queue. Never merges.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OWNER=peteowen1
BR="agent/issue-$ISSUE-${MODEL_SHORT:-sonnet}"
read_or() { [ -s "$1" ] && cat "$1" || echo "$2"; }
summary=$(read_or _out/agent-summary.md "(no summary written)")
costs=$(read_or _out/costs.txt "(no cost line: the agent step did not finish)")
G="git -c core.hooksPath=/dev/null -c core.fsmonitor=false"
delivered=0
why=""

report_failure() {
  [ "$delivered" = 1 ] && return
  delivered=1  # once only, even if called again from the trap
  {
    echo "The overnight agent worker delivered no PR for this issue (${MODEL_SHORT:-sonnet}; agent step: ${AGENT_OUTCOME:-did not run})."
    [ -n "$why" ] && printf '\n**%s**\n' "$why"
    printf '\n%s\n\n%s. Log: %s\nRemove the `agent-failed` label to let it try again.\n' "$summary" "$costs" "$RUN_URL"
  } > /tmp/fail.md
  gh issue comment "$ISSUE" -R "$OWNER/$REPO" --body-file /tmp/fail.md >/dev/null || echo "::error::could not comment on the issue"
  gh issue edit "$ISSUE" -R "$OWNER/$REPO" --remove-label agent-working --add-label agent-failed >/dev/null \
    || echo "::error::could not relabel $REPO#$ISSUE; it may still carry agent-working"
  echo "No PR delivered; reported on $REPO#$ISSUE: ${why:-no commits}"
}
trap report_failure EXIT
refuse() { why="$1"; echo "::error::$1"; exit 0; }

# An investigation with no fix: post the report on the issue; it is a result, not a failure.
if [ ! -s _out/agent.bundle ] && [ -s _out/agent-report.md ]; then
  {
    [ "$AGENT_OUTCOME" = success ] || printf '**PARTIAL: the agent step ended with %s (budget cap, time limit or crash), so this report may be unfinished.**

' "${AGENT_OUTCOME:-unknown}"
    printf 'Agent worker report (%s, overnight run; no code change; not reviewed by a second pass).

' "${MODEL_SHORT:-sonnet}"
    head -c 60000 _out/agent-report.md
    printf '

%s. Log: %s
Remove `agent-report` and keep `agent-ok` to have it try again, e.g. after a decision.
' "$costs" "$RUN_URL"
  } > /tmp/report.md
  gh issue comment "$ISSUE" -R "$OWNER/$REPO" --body-file /tmp/report.md >/dev/null || refuse "Could not post the report."
  delivered=1
  lbl=agent-report; [ "$AGENT_OUTCOME" = success ] || lbl=agent-failed
  gh issue edit "$ISSUE" -R "$OWNER/$REPO" --remove-label agent-working --add-label "$lbl" >/dev/null     || echo "::error::posted the report but could not relabel $REPO#$ISSUE"
  echo "Posted a report on $REPO#$ISSUE"
  exit 0
fi
[ -s _out/agent.bundle ] || refuse "The worker made no commits."

# A bare clone, so nothing from the agent is ever checked out or executed here.
$G clone -q --bare "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$REPO.git" /tmp/clean.git \
  || refuse "Could not clone $REPO to deliver the branch."
if $G -C /tmp/clean.git rev-parse -q --verify "refs/heads/$BR" >/dev/null; then
  refuse "Branch $BR already exists on GitHub (an earlier run). Delete it, or close its PR, before re-running."
fi
$G -C /tmp/clean.git bundle verify -q "$PWD/_out/agent.bundle" \
  || refuse "The agent's commits do not apply: the bundle's base is missing (dev was force-pushed during the run?)."
$G -C /tmp/clean.git fetch -q "$PWD/_out/agent.bundle" "HEAD:refs/heads/$BR" \
  || refuse "Could not read the agent's commits from the bundle."
n=$($G -C /tmp/clean.git rev-list --count "refs/heads/dev..refs/heads/$BR")
[ "$n" -gt 0 ] || refuse "The agent's branch has no commits beyond dev."

# Fails closed. No merge commits at all (an evil merge can add files that no
# commit's own file list shows); then every file any commit touched, and the net diff.
[ -z "$($G -C /tmp/clean.git rev-list --merges "refs/heads/dev..refs/heads/$BR")" ] \
  || refuse "The branch contains a merge commit; the worker only pushes linear commits."
touched=$( { $G -C /tmp/clean.git -c core.quotePath=false log --no-renames --format= --name-only "refs/heads/dev..refs/heads/$BR" \
             && $G -C /tmp/clean.git -c core.quotePath=false diff --no-renames --name-only "refs/heads/dev...refs/heads/$BR"; } ) \
  || refuse "Could not list the files the branch changes."
if printf '%s\n' "$touched" | grep -qi '^\.github/'; then
  refuse "The change touches .github/, which the worker never pushes (the push token can edit workflows)."
fi
# Pushing triggers this repo's own CI on the agent's code; refuse if that CI has secrets.
if ! ci=$(python3 "$HERE/ci_guard.py" /tmp/clean.git "$BR" 2>&1); then
  refuse "Not pushed: this repo's CI would run the agent's unreviewed code with secrets. $(echo "$ci" | tr '\n' ' ')"
fi
$G -C /tmp/clean.git merge-base --is-ancestor refs/heads/dev "refs/heads/$BR" \
  || echo "::warning::branch is not on top of current dev (dev moved during the run); the PR shows the drift"

$G -C /tmp/clean.git -c credential.helper= push -q origin "refs/heads/$BR:refs/heads/$BR" \
  || refuse "Push of $BR failed."

{
  echo "Overnight agent worker run for #$ISSUE, coded by **${MODEL_SHORT:-sonnet}** ($n commit(s) on \`$BR\`, cut from \`dev\`). **Not merged and not reviewed by Pete yet**: it goes through the usual review gate before anything reaches \`main\`."
  printf '\n## What the worker says it did\n%s\n' "$summary"
  if [ -s _out/agent-report.md ]; then printf '\n## Investigation report\n%s\n' "$(head -c 20000 _out/agent-report.md)"; fi
  printf '\n## Independent review (second Claude pass, read-only)\n%s\n' "$(read_or _out/review.md "(the review did not run)")"
  printf '\n## Run\n%s. Log: %s\n' "$costs" "$RUN_URL"
  [ "$AGENT_OUTCOME" = success ] || printf '**The agent step ended with: %s**; treat this PR as partial.\n' "$AGENT_OUTCOME"
  printf '\nRefs #%s\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' "$ISSUE"
} > /tmp/body.md
head -c 60000 /tmp/body.md > /tmp/body.trim.md  # GitHub caps a PR body at 65,536 chars
title=$(gh issue view "$ISSUE" -R "$OWNER/$REPO" --json title -q .title | head -c 200)
url=$(gh pr create -R "$OWNER/$REPO" --base dev --head "$BR" \
        --title "Agent (${MODEL_SHORT:-sonnet}): $title (#$ISSUE)" --body-file /tmp/body.trim.md) \
  || refuse "Pushed $BR but could not open the PR."
delivered=1
echo "Opened $url"
gh issue edit "$ISSUE" -R "$OWNER/$REPO" --remove-label agent-working --add-label agent-pr >/dev/null   || echo "::error::opened $url but could not relabel $REPO#$ISSUE; remove agent-working by hand"
gh issue comment "$ISSUE" -R "$OWNER/$REPO" --body "Agent worker (${MODEL_SHORT:-sonnet}) opened $url (into \`dev\`, not merged)." >/dev/null   || echo "::warning::could not comment on $REPO#$ISSUE"
