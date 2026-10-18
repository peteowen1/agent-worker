# agent-worker

Pete's overnight coding worker. Every night it takes issues labelled `agent-ok` in his
**public** repos, has Claude Code fix or investigate each one on a branch cut from `dev`, has a
second Claude pass review the change, and opens a PR into `dev` (or posts an investigation report
on the issue). It never merges and never touches `main`.

This repo is public so its GitHub Actions minutes are free. Its logs and artifacts are public
too, which is why it only takes issues from public repos. A copy in the private `peteowen1/ops`
repo takes the private ones.

Design, security model and labels: [`scripts/agent-worker/README.md`](scripts/agent-worker/README.md).

Setup (once): the repository secret `WORKFLOW_PAT` and the repository variables
`ANTHROPIC_ORGANIZATION_ID`, `ANTHROPIC_SERVICE_ACCOUNT_ID`, `ANTHROPIC_FEDERATION_RULE_ID` and
`ANTHROPIC_WORKSPACE_ID` (a Workload Identity Federation rule whose subject is
`repo:peteowen1/agent-worker:*`, allowed events: any).
