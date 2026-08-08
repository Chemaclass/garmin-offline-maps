---
name: gh-issues
description: Walk the open GitHub issues that are unassigned or assigned to you, and work each one through the gh-issue skill in turn. Use when asked to work through the backlog, clear the issues, or process several issues in one go.
argument-hint: "[--limit N] [--label foo] [--lane packer|watch-app] [--dry-run]"
disable-model-invocation: true
allowed-tools: "Read, Grep, Glob, Bash(gh *), Bash(git *), Bash(make *), Bash(python3 *), Skill(gh-issue), Skill(changelog), Skill(contracts)"
---

# Work through the open issues

Process every open issue that is **unassigned** or **assigned to you**, oldest
first, by delegating each to `/gh-issue`. Stop on the first hard failure so it
can be looked at rather than papered over.

## Args

- `--limit N`: at most N issues this run (default: all)
- `--label foo`: only issues carrying that label
- `--lane packer|watch-app`: only issues in one half of the repo, which is
  worth using: the packer lane verifies in under a second and the watch lane
  needs a compile and a simulator per issue
- `--dry-run`: print the queue and stop

Strip a leading `#` from any number the user passes.

## Before anything: is this the right tool?

**Check the queue before starting the loop.** Several issues in this repo are
multi-day features rather than fixes, and a sequential loop will either stall on
one or, worse, half-build it. Read the titles and bodies first, then say which
you intend to work and which you are skipping and why.

Signals an issue is not loop-material:

- it changes the byte format (bumps the version, touches all three
  implementations, `docs/FORMAT.md` moves)
- it needs a measurement campaign rather than an edit
- its body says the cause is unknown, or lists ruled-out hypotheses
- it needs hardware

Say so up front rather than discovering it three issues in. Finishing four
issues properly and naming the six you did not is a better outcome than ten
half-done.

## Phase 1: discover

GitHub search will not OR these cleanly, so run two queries and merge.

```bash
gh issue list --state open --search "no:assignee" \
  --json number,title,labels,assignees,createdAt --limit 200
gh issue list --state open --assignee "@me" \
  --json number,title,labels,assignees,createdAt --limit 200
```

Merge by:
- dedupe on `number`
- keep only those with an empty `assignees` **or** containing `gh api user -q .login`
- drop anything assigned to someone else
- apply `--label` and `--lane` filters (lane maps to the `packer` /
  `watch-app` / `rendering` labels)
- sort ascending by `createdAt`, then apply `--limit`

Print the queue as `#<n> <title> [unassigned|@me] <labels>`. Exit cleanly if
empty.

## Phase 2: worktree sanity

```bash
git status --porcelain
git fetch origin main && git checkout main && git reset --hard origin/main
```

Abort if dirty. **Never auto-stash.** `mapdata/active/**` and
`source/generated/MapIndex.mc` are generated, and a stash containing them is
easy to lose and hard to notice. If the tree is dirty with generated files, the
fix is `make demo` and a `git checkout`, not a stash.

## Phase 3: the loop

For each issue:

1. **Re-check assignment**, because someone may have taken it since Phase 1:
   ```bash
   gh issue view <n> --json assignees -q '.assignees[].login'
   ```
   Empty or only you → proceed. Anyone else → skip.

2. **Invoke `/gh-issue <n>`.** That skill owns the lane decision, the branch,
   the invariants, verification and the PR.

3. **Watch CI**: `gh pr checks --watch`.

   Remember the **Connect IQ build job is skipped** without the
   `GARMIN_USERNAME`/`GARMIN_PASSWORD` secrets and `CIQ_AGREEMENT_HASH`. Green
   CI therefore does not mean the watch app compiles. If the issue touched
   `source/`, your local `make build` is the only evidence, and it should be
   named as such.

4. **Merge and sync**:
   ```bash
   gh pr merge <n> --squash --delete-branch
   git checkout main && git fetch origin main && git reset --hard origin/main
   ```

5. Next issue.

## Between issues, re-verify the shared state

Two issues in a row touching the packer can leave the committed demo pack
stale, and the second PR then carries the first's regeneration. Before starting
each issue:

```bash
make demo && git diff --exit-code -- mapdata/active source/generated/MapIndex.mc
```

Clean, or stop and work out why.

## Stop conditions

Halt and report:

- `/gh-issue` errors, or leaves the worktree dirty
- `make test` fails, or the `make demo` diff is non-empty
- `make build` gains a warning. It is warning-free today, and that is what
  makes a new one worth reading
- a contract test fails: that means "go edit the other side", and whether the
  other side should move is a judgement call, not a loop step
- CI stays red after one fix attempt
- `--limit` reached, or the queue is empty

Do not retry blindly. Name the issue and the reason.

## Reporting at the end

Give a table of what closed and what did not, with the reason for each
skip. For anything left open, add a comment to the issue recording what you
learned. A ruled-out hypothesis is worth as much as a fix, and this repo's
issues are written that way on purpose.

Be exact about verification. If the watch app changed and no hardware was
involved, say that plainly in the summary rather than letting a green CI badge
imply otherwise.

## Preconditions

- `gh` authenticated with read on issues and write on PRs
- clean worktree, `main` tracking `origin/main`
- `/gh-issue` available in this session
- for watch-lane issues: the SDK, a 9.1.x simulator SDK, and `make doctor` clean
