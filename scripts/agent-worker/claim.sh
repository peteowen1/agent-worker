#!/usr/bin/env bash
# Label the issue agent-working, clone the repo into _w at dev, cut the branch.
# The clone keeps NO credentials: the token is used for the fetch only, then the
# remote is reset to the plain URL, so the agent step cannot push.
set -euo pipefail
OWNER=peteowen1
for l in "agent-working:fbca04" "agent-pr:0e8a16" "agent-failed:b60205" "agent-sonnet:5319e7" "agent-report:1d76db"; do
  # a parallel first run in the same repo may create it at the same moment
  gh label create "${l%%:*}" -R "$OWNER/$REPO" --color "${l##*:}" --force >/dev/null 2>&1 || true
done
# (The "claimed by another run" check is in pick.sh, before repo/issue are output:
# a refusal here would leave them set, and deliver would strip the other run's label.)
# agent-failed comes off too, so a re-run that succeeds does not end with both labels.
gh issue edit "$ISSUE" -R "$OWNER/$REPO" --add-label agent-working --remove-label agent-failed >/dev/null

git clone -q "https://x-access-token:${GH_TOKEN}@github.com/$OWNER/$REPO.git" _w
git -C _w remote set-url origin "https://github.com/$OWNER/$REPO.git"
if ! git -C _w rev-parse -q --verify origin/dev >/dev/null; then
  echo "::error::$REPO has no dev branch; the worker only works from dev"
  exit 1
fi
git -C _w checkout -q -b "agent/issue-$ISSUE" origin/dev
git -C _w config user.name "claude-agent-worker"
git -C _w config user.email "github-actions[bot]@users.noreply.github.com"

# The issue as the agent will read it: title, body, and Pete's comments only.
gh issue view "$ISSUE" -R "$OWNER/$REPO" --json title,body,comments \
  | jq -r --arg o "$OWNER" '"# \(.title)\n\n\(.body)\n" +
      ([.comments[] | select(.author.login == $o) | "\n---\nComment from Pete:\n\(.body)"] | join("\n"))' \
  > /tmp/issue.md
echo "Branch agent/issue-$ISSUE from dev $(git -C _w rev-parse --short HEAD); issue text $(wc -c < /tmp/issue.md) chars"
