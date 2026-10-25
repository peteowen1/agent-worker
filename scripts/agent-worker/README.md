# Agent worker

Overnight Claude Code worker (`.github/workflows/agent-worker.yml`). Approved by Pete on 2026-10-18.

**Why:** the Max plan's monthly $200 API credit was over 99% unused, while the weekly Claude Code limit is the
scarce resource. Unattended `claude -p` under Workload Identity Federation bills the API credit: on 2026-10-17
the probe on branch `agent-worker-probe` ran `claude -p` and the Agent SDK on an account with no payment method,
and both succeeded.

## Models

Haiku 5.5 at effort `xhigh` by default (Pete, 2026-10-18), with the same 100k context cap as his local settings: about
$0.10 an issue. **Label a harder issue `agent-sonnet`** and it gets Sonnet 5.5 at effort `high` (about $0.20-1.00).
A dispatch can force either model or effort. Each model gets its own branch, `agent/issue-N-<model>`, so both can do
the same issue. The reviewer is always Sonnet. Evidence so far, panna#284 and citiusdata#33: both models fixed both;
on citiusdata#33 Haiku cost half as much ($0.11 vs $0.21) but its fix was judged "needs fixes" and Sonnet's "ready".

## How Pete uses it

1. Open an issue in any peteowen1 repo, written so it can be done cold: what, where, what done looks like.
2. Label it `agent-ok`.
3. The next night, every 10 minutes from 2:00 to 3:50 AM Sydney, the worker takes the twelve oldest such issues (one per run) and opens a PR into
   `dev` titled `Agent: ...`, with the worker's own summary and a second Claude review. The issue gets
   `agent-pr`. If there's no change, it gets a comment saying why and the label `agent-failed`. Remove that label to retry.
4. Review and merge the PR like any other. The worker never merges.

Run one now: Actions, then "Agent worker", then Run workflow, with a repo and an issue number.

## Flow

| step | where | GitHub token? |
|---|---|---|
| `pick.sh`: oldest open `agent-ok` issue opened by peteowen1, not already `agent-working`/`agent-pr`/`agent-failed` | prepare job | yes |
| `claim.sh`: label `agent-working`, clone at `dev` (remote reset to the plain URL, no stored credentials), branch `agent/issue-N`, issue text (Pete's comments only); the clone goes to the work job as an artifact | prepare job | yes |
| R and the package's dependencies, if there is a `DESCRIPTION` (public sources only) | work job | **no** |
| `run.sh`: worker (`claude -p`: Haiku xhigh with a $1 cap, or Sonnet high with $3 for `agent-sonnet` issues; 250 turns, 75 min), then reviewer (Sonnet, read-only tools, $1 cap) | work job | **no** |
| commits as a git bundle, plus the summary, review and costs, uploaded as an artifact | work job | no |
| `deliver.sh`: bare clone, fetch the bundle, refuse any change under `.github/`, push, open the PR, relabel | **deliver job, fresh machine** | yes |

## Security choices

- Only issues opened by peteowen1 are fed to the agent, and only his comments, because the issue text becomes the agent's instructions.
- The agent has full Bash (R checks need it) with `--permission-mode dontAsk`, so nothing waits for an answer. It
  runs with no GitHub token in its job. It does have network access
  and the Anthropic token file, which is the remaining risk Pete accepted.
- The agent can write anywhere on the work job's machine, so nothing on that machine is trusted after it
  runs. The push happens in a separate job from a fresh checkout. Git there runs with `core.hooksPath=/dev/null`.
- `WORKFLOW_PAT` can edit workflows, so a branch touching `.github/` (in any commit or the net diff) or containing a
  merge commit is never pushed.
- An issue labelled `docs-drift` (opened by ops `scripts/docs-drift.sh`, which also dispatches the worker on it)
  may only change the `.md` files its checklist names (`- [ ] \`path.md:line\``). `deliver.sh` refuses anything
  else, and refuses if it cannot read the issue.
- Pushing makes the target repo's own CI run the agent's unreviewed code, with that repo's secrets. `ci_guard.py`
  reads the target's workflows and refuses the push if any workflow that uses secrets would fire on the agent branch
  or a PR into `dev`. Checked 2026-10-18: torp, panna, bouncer, citiusdata, torpdata pass; inthegame-blog is refused
  (its Cloudflare deploy workflows run on PRs into `dev`).
- Not covered by `ci_guard.py`: `GITHUB_TOKEN` itself (exempt; on a same-repo push it can have write access,
  depending on the repo's default token permissions) and cloud roles reached through `id-token: write`.
- No git command runs as `runner` inside the agent's clone (its `.git/config` is agent-writable, and
  `core.fsmonitor` or a clean filter would run agent code as runner); run.sh does all of it as `agent`.

- The agent and its reviewer run as the unprivileged user `agent` (`sudo -u agent env -i ...` with an explicit
  variable list): no sudo, and a different uid from `runner`, so they cannot read the OIDC refresher's
  `/proc/*/environ` (which holds the token-minting variables) or anything else from the job's environment.

## Still open

- A push token without `workflow` scope for deliver (a fine-grained PAT), so the `.github/` guard is not the only
  thing standing between an agent branch and a workflow change.

## Auth gotchas (from the 2026-10-17 probe)

- Claude Code reads the WIF variables natively (`ANTHROPIC_FEDERATION_RULE_ID` etc.). `ANTHROPIC_API_KEY` or
  `ANTHROPIC_AUTH_TOKEN`, even set to an empty value, overrides federation, so `run.sh` unsets them. `--bare` ignores federation.
- GitHub's OIDC token lasts about 5 minutes and is single-use, so a background loop rewrites the token file every 2 minutes.
- Probe test C asked Haiku to run three sleeps; it ran none and replied "3 of 3 done" in under a second. The
  worker's summary is a claim, which is why a separate review pass reads the diff.
