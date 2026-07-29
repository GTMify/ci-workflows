# ci-workflows

Shared quality gates for GTMify repos. One reusable workflow, called by many repos, so a rule is fixed once rather than thirty times.

**This repo is public on purpose, and holds no secrets.** Workflow YAML and check scripts only, no business logic and no repo data. It has to be public because a private reusable workflow can only be called from inside the same organization or user account, and several active repos live under the personal `scott-wueschinski-GTMify` account rather than the `GTMify` org. A public workflow is callable from any repo, private ones included.

## Adding a repo

Drop this in `.github/workflows/gate.yml` and set the tier:

```yaml
name: gate
on: [pull_request, workflow_dispatch]
jobs:
  gate:
    uses: GTMify/ci-workflows/.github/workflows/gate.yml@v1
    with:
      tier: c
```

Pin to `@v1`, never `@main`. `v1` is a tag that moves only deliberately, so a bad push here cannot break every repo at once.

`workflow_dispatch` is worth keeping. With no pull request base to compare against, the gate switches to auditing every tracked file, which makes manual dispatch the cleanup tool for a repo that already carries junk.

## Tiers

| Tier | For | Checks |
| :-- | :-- | :-- |
| `a` | The config repo | junk, shell, and the config-specific checks |
| `b` | Repos that build and deploy | junk, shell, plus `build_cmd` must succeed |
| `c` | Content and docs repos | junk only |

Tier B passes its build command in:

```yaml
    with:
      tier: b
      build_cmd: npm ci && npm run build
```

`GTMify/GTMify` is deliberately excluded. The app has its own three workflows built around platformOS constraints (tests execute on a deployed instance, so they cannot run locally) that apply to no other repo. Do not point it here.

## The junk-file gate

`scripts/junk_file_gate.sh` refuses to let ephemeral, generated, or credential files become tracked content.

It exists because nothing stopped 33 `.claude/worktrees/*` gitlinks and 40 `.pos-supervisor/*` files, one of them a SQLite `analytics.db-wal`, from becoming tracked in `GTMify/GTMify`. A write-ahead log is rewritten on nearly every run, so that repo was permanently dirty, the session-end auto-commit hook turned the dirt into a commit every time, and local `master` drifted 19 commits off origin with no app code in any of them. `gtmify-config` carries a committed `hooks/Icon` for the same reason.

What it rejects: worktree gitlinks, `.pos-supervisor/`, SQLite `-wal`/`-shm`/`-journal` sidecars, `.pos` and `.pos-*`, `.siteglide-config`, `*.token`, `*.secret`, `.env` and friends, `node_modules/`, `__pycache__/` and `*.pyc`, and macOS `.DS_Store`, `Icon`, and `._*` artifacts.

Two properties worth knowing:

**Only tracked paths can fail.** Every mode enumerates paths through git, so a file that exists on disk but is gitignored is invisible by construction. The gate objects to junk being tracked, not to junk existing.

**`.env.template`, `.env.sops`, `.env.example` and `.env.sample` are allowed.** Templates and sops-encrypted files are meant to be shared. Everything else beginning `.env` is treated as secret-bearing.

If a flagged path is genuinely intended content, add it to `.ci-junk-allowlist` in the repo root, one glob per line, with a comment saying why. A gate with no legitimate override gets switched off the first time it is wrong.

## Enforcement, and its limit

The GTMify org is on the free plan, where branch protection and rulesets return `403 Upgrade to GitHub Pro` on private repos. These checks therefore **run and show red on a pull request but cannot be made required**.

Real enforcement for the junk gate comes from the local pre-commit hook in `gtmify-config`, which runs `junk_file_gate.sh --staged` and blocks junk before it can be committed at all, with no dependence on a GitHub plan. That is earlier than a required check would catch it.

## House style

Off by default. The linter lives in the private `GTMify/claude-house-style` repo, which this public workflow cannot read without a token. Turning it on means either making that linter public or minting a read-only PAT and passing it as `house_style_token`. Until that is decided, house style is enforced by the local write-time hook, which already covers the common case.

## Tests

```bash
tests/junk_file_gate_test.sh
```

35 cases, one throwaway git repo each, dirty in exactly one way. Two of them carry most of the value: `ignored_but_present` proves the tracked-only property, and `icon_in_a_longer_name` pins a real false-positive class that once made `auto_commit_on_exit.sh` silently drop work whose only sin was a filename containing the word Icon.

The suite has been observed failing, not just passing. Removing the worktree pattern from the gate turns 3 cases red, which is the check that the tests are actually asserting something.
