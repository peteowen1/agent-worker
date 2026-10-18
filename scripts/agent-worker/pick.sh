#!/usr/bin/env bash
# Pick the issue the worker takes: the dispatch inputs if given, else the oldest
# open issue labelled agent-ok, opened by peteowen1 (an issue anyone else wrote is
# never fed to the agent: its text becomes the agent's instructions), and not
# already claimed (agent-working), delivered (agent-pr) or failed (agent-failed).
# Writes repo= and issue= to $GITHUB_OUTPUT; both empty means nothing to do.
set -euo pipefail
OWNER=peteowen1
# Mandatory: the public copy must never take a private repo (its logs are public),
# so a missing or misspelt setting stops the run instead of searching everything.
case "${WORKER_VISIBILITY:-}" in public|private) ;; *) echo "::error::WORKER_VISIBILITY must be public or private (got '${WORKER_VISIBILITY:-}')"; exit 1 ;; esac
# Model: Haiku at effort xhigh by default (Pete, 2026-10-18; ~$0.10 an issue with
# the 100k cap). An issue labelled agent-sonnet is a harder one and gets Sonnet at
# effort high. A dispatch can force either with IN_MODEL / IN_EFFORT.
choose_model() {  # repo issue -> sets MODEL_SHORT, EFFORT_PICK
  local m=${IN_MODEL:-auto} v
  case "$m" in auto|haiku|sonnet) ;; *) echo "::error::unknown model '$m'"; exit 1 ;; esac
  case "${IN_EFFORT:-auto}" in auto|high|xhigh|max) ;; *) echo "::error::unknown effort '$IN_EFFORT'"; exit 1 ;; esac
  if [ "$m" = auto ]; then
    m=haiku
    v=$(gh issue view "$2" -R "$OWNER/$1" --json labels -q 'any(.labels[]; .name == "agent-sonnet")')       || { echo "::warning::could not read $1#$2's labels; coding with Haiku"; v=false; }
    [ "$v" = true ] && m=sonnet
  fi
  MODEL_SHORT=$m
  EFFORT_PICK=${IN_EFFORT:-auto}
  [ "$EFFORT_PICK" = auto ] && { [ "$m" = haiku ] && EFFORT_PICK=xhigh || EFFORT_PICK=high; }
  return 0
}
out() {
  local o=${GITHUB_OUTPUT:-/dev/stdout}
  echo "repo=$1" >> "$o"; echo "issue=$2" >> "$o"
  if [ -n "$1" ]; then
    choose_model "$1" "$2"
    echo "model_short=$MODEL_SHORT" >> "$o"
    echo "model=claude-$MODEL_SHORT-5-5" >> "$o"
    echo "effort=$EFFORT_PICK" >> "$o"
    echo "Model: $MODEL_SHORT, effort $EFFORT_PICK"
  fi
}
# Read the issue directly (search lags label changes by seconds). Fails closed:
# a gh error counts as claimed. Runs before out(), so a refusal outputs nothing
# and no later job touches the issue.
claimed() {
  local v
  v=$(gh issue view "$2" -R "$OWNER/$1" --json labels -q 'any(.labels[]; .name == "agent-working")') || return 0
  [ "$v" != false ]
}

if [ -n "${IN_REPO:-}" ] || [ -n "${IN_ISSUE:-}" ]; then
  : "${IN_REPO:?give both repo and issue}" "${IN_ISSUE:?give both repo and issue}"
  # Visibility first, before anything about the issue reaches the (possibly public) log.
  vis=$(gh repo view "$OWNER/$IN_REPO" --json visibility -q '.visibility|ascii_downcase')
  [ "$vis" = "$WORKER_VISIBILITY" ] || { echo "::error::this worker only takes $WORKER_VISIBILITY repos"; exit 1; }
  # A dispatch may re-run a delivered or failed issue (e.g. the other model), but
  # never one a run is working on right now.
  st=$(gh issue view "$IN_ISSUE" -R "$OWNER/$IN_REPO" --json author,state,labels \
         -q '.state+" "+.author.login+" "+([.labels[].name]|join(","))')
  read -r state author labels <<<"$st"
  [ "$state $author" = "OPEN $OWNER" ] || { echo "::error::$IN_REPO#$IN_ISSUE is not an open issue by $OWNER ($state $author)"; exit 1; }
  if claimed "$IN_REPO" "$IN_ISSUE"; then
    echo "::error::$IN_REPO#$IN_ISSUE is labelled agent-working: a run has it now (or one died; remove the label)"; exit 1
  fi
  echo "Dispatched: $IN_REPO#$IN_ISSUE"
  out "$IN_REPO" "$IN_ISSUE"
  exit 0
fi

# The exclusions go in the query, not a filter after it, so 50+ failed issues can
# never hide a newer one past the page limit.
q="user:$OWNER is:issue is:open is:$WORKER_VISIBILITY author:$OWNER label:agent-ok -label:agent-working -label:agent-pr -label:agent-failed -label:agent-report"
# The 5 oldest: if a parallel run (the twelve nightly slots start 10 minutes apart,
# but GitHub can start them late) claimed one, take the next instead of idling.
# The claim is made HERE, right after the check, so the race window is about a
# second (claim.sh adding the same label again is a no-op).
while read -r repo issue title; do
  [ -n "$repo" ] || continue
  if claimed "$repo" "$issue"; then echo "$repo#$issue is claimed by another run; trying the next"; continue; fi
  if [ "${GITHUB_EVENT_NAME:-}" != push ]; then
    gh issue edit "$issue" -R "$OWNER/$repo" --add-label agent-working >/dev/null 2>&1 \
      || { echo "::warning::could not claim $repo#$issue; trying the next"; continue; }
  fi
  echo "Tonight: $repo#$issue $title"
  out "$repo" "$issue"
  exit 0
done < <(gh api -X GET search/issues -f q="$q" -f sort=created -f order=asc -f per_page=5 \
           -q '.items[] | "\(.repository_url | split("/") | last) \(.number) \(.title)"')
echo "No open agent-ok issue waiting; nothing to do tonight."
out "" ""
