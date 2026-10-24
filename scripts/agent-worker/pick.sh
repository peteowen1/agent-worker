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
# The claim below runs before claim.sh, so in a repo no run has worked in yet the
# labels do not exist and the claim fails. That left the worker idle for three
# nights (2026-10-19 to 10-21): every candidate failed its claim, silently.
ensure_labels() {
  local l
  for l in "agent-working:fbca04" "agent-pr:0e8a16" "agent-failed:b60205" "agent-sonnet:5319e7" "agent-report:1d76db"; do
    # no --force: an existing label keeps its colour; "already exists" is the normal case
    gh label create "${l%%:*}" -R "$OWNER/$1" --color "${l##*:}" >/dev/null 2>&1 || true
  done
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
# Searched first, not fed in through < <(...): a failing search inside a process
# substitution is invisible to set -e, so it used to log "nothing waiting" and
# exit green, the same silent idle as the claim failures of 2026-10-19 to 10-21.
if ! found=$(gh api -X GET search/issues -f q="$q" -f sort=created -f order=asc -f per_page=5 \
               -q '.items[] | "\(.repository_url | split("/") | last) \(.number) \(.title)"'); then
  echo "::error::the issue search failed (gh's error is above); nothing taken tonight"
  out "" ""; exit 1
fi
failed=0
while read -r repo issue title; do
  [ -n "$repo" ] || continue
  if claimed "$repo" "$issue"; then echo "$repo#$issue is claimed by another run; trying the next"; continue; fi
  if [ "${GITHUB_EVENT_NAME:-}" != push ]; then
    ensure_labels "$repo"
    if ! err=$(gh issue edit "$issue" -R "$OWNER/$repo" --add-label agent-working 2>&1 >/dev/null); then
      echo "::warning::could not claim $repo#$issue ($err); trying the next"; failed=$((failed + 1)); continue
    fi
  fi
  echo "Tonight: $repo#$issue $title"
  out "$repo" "$issue"
  exit 0
done <<<"$found"
# Not "nothing waiting" when every candidate was there but could not be claimed:
# that is a fault, and the run goes red so it is seen in the morning.
if [ "$failed" -gt 0 ]; then
  echo "::error::$failed waiting issue(s) could not be claimed (see the warnings above); nothing taken tonight"
  out "" ""; exit 1
fi
echo "No open agent-ok issue waiting; nothing to do tonight."
out "" ""
