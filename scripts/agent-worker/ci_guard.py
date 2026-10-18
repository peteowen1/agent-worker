#!/usr/bin/env python3
"""Would pushing an agent branch and opening a PR into dev run a workflow that has secrets?

  ci_guard.py BARE_REPO BRANCH      exit 0 = safe to push; exit 1 = refuse (reasons printed)

A push made with the PAT triggers the target repo's own `push` and `pull_request`
workflows, and same-repo PRs get that repo's secrets, so agent-written code (tests,
scripts, DESCRIPTION) would run next to them before Pete reviews anything.

A workflow "fires" for the agent when its `push` matches the agent branch, its
`pull_request`/`pull_request_target` matches dev (the PR's base), or it has `create`
(the push creates the branch). A `workflow_run` workflow fires only if a workflow it
names fires, and its own `branches` filter (on the triggering run's head branch, the
agent branch) allows it; chains are followed to a fixed point. A secret-using
workflow that fires is a refusal. Workflow files are read from dev for pull_request
(the .github/ guard in deliver.sh refuses a branch that changes them, so dev and the
branch hold the same files). Conservative: a trigger it cannot read counts as firing.
"""
import fnmatch
import re
import subprocess
import sys

import yaml

repo, branch = sys.argv[1], sys.argv[2]
EXEMPT = {"GITHUB_TOKEN"}


def git(*a):
    # UTF-8 explicitly: on Windows the default code page cannot decode some workflow files
    return subprocess.run(["git", "-C", repo, "-c", "core.hooksPath=/dev/null", *a], capture_output=True,
                          text=True, encoding="utf-8", errors="replace", check=True).stdout


def as_list(v):
    # `branches: dev` (a scalar) is legal YAML; iterating it would test characters
    return [str(v)] if isinstance(v, str) else [str(b) for b in (v or [])]


def matches(filters, name):
    # GitHub globs give ? and + a meaning fnmatch does not ("zero or one" / "one or more"
    # of the previous character); a filter using them is treated as matching (fails closed).
    return any(("?" in f or "+" in f) or fnmatch.fnmatchcase(name, f) for f in filters)


def branch_ok(cfg, ref):
    """cfg is one event's config (None, dict, list); does its branch filter admit ref?"""
    if not isinstance(cfg, dict):
        return True  # no filter: every branch
    if "branches" in cfg:
        return matches(as_list(cfg["branches"]), ref)
    if "branches-ignore" in cfg:
        return not matches(as_list(cfg["branches-ignore"]), ref)
    if "tags" in cfg:
        return False  # tag-only push filter
    return True


def secrets_in(text):
    s = sorted(set(re.findall(r"secrets\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)", text)) - EXEMPT)
    if re.search(r"secrets\s*\[", text) or re.search(r"toJSON\(\s*secrets\s*\)", text):
        s.append("(indexed or whole secrets object)")
    if re.search(r"secrets:\s*[\"']?inherit", text):
        s.append("(inherit)")
    return s


def load(tree):
    git("rev-parse", "--verify", "-q", tree)  # a missing ref is an error, not "no workflows"
    try:
        names = [x for x in git("ls-tree", "-z", "--name-only", f"{tree}:.github/workflows").split("\0") if x]
    except subprocess.CalledProcessError:
        return {}  # no .github/workflows directory
    wf = {}
    for n in names:
        if not n.endswith((".yml", ".yaml")):
            continue
        text = git("show", f"{tree}:.github/workflows/{n}")
        try:
            d = yaml.safe_load(text) or {}
            on = d.get(True, d.get("on"))
            title = d.get("name") or n
        except yaml.YAMLError:
            m = re.search(r"^name:[ \t]*[\"']?([^\"'\r\n]+)", text, re.M)
            on, title = None, (m.group(1).strip() if m else n)
        if isinstance(on, str):
            on = {on: None}
        elif isinstance(on, list):
            on = {k: None for k in on}
        wf[n] = {"on": on, "name": str(title), "secrets": secrets_in(text)}
    return wf


dev = load("refs/heads/dev")
br = load(f"refs/heads/{branch}")
# workflow_run workflows run from the DEFAULT branch, so read those from there too
default_ref = git("symbolic-ref", "-q", "HEAD").strip() or "refs/heads/main"
default = load(default_ref) if default_ref != "refs/heads/dev" else dev
fires = {}  # file -> reason it fires for the agent
for n, w in dev.items():
    on = w["on"]
    if not isinstance(on, dict):
        fires[n] = "triggers unreadable"
        continue
    for ev in ("pull_request", "pull_request_target"):
        if ev in on and branch_ok(on[ev], "dev"):
            fires[n] = f"`{ev}` into dev"
    if "create" in on:
        fires[n] = "`create` (the push creates the agent branch)"
for n, w in br.items():
    on = w["on"]
    if isinstance(on, dict) and "push" in on and branch_ok(on["push"], branch):
        fires.setdefault(n, f"`push` to {branch}")
def named(pattern, file, w):
    return any(fnmatch.fnmatchcase(c, pattern) for c in (w["name"], file, f".github/workflows/{file}"))


# workflow_run chains, to a fixed point, over the default branch's files (where they
# run) keyed "default:<file>"; the triggering workflows are anything that fires.
chain = {f"default:{n}": w for n, w in default.items()}
everything = {**{n: w for n, w in dev.items()}, **{n: w for n, w in br.items()}, **chain}
changed = True
while changed:
    changed = False
    for key, w in chain.items():
        on = w["on"]
        if key in fires or not isinstance(on, dict) or "workflow_run" not in on:
            continue
        cfg = on["workflow_run"] if isinstance(on["workflow_run"], dict) else {}
        if not branch_ok(cfg, branch):
            continue
        pats = as_list(cfg.get("workflows"))
        hit = [k for k in fires if any(named(p, k.split(":", 1)[-1], everything[k]) for p in pats)]
        if hit or not pats:
            fires[key] = f"`workflow_run` after {', '.join(hit) or '(any workflow)'}"
            changed = True

problems = [f"{n}: fires on {why} and uses secrets {', '.join(everything[n]['secrets'])}"
            for n, why in sorted(fires.items()) if everything[n]["secrets"]]
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
