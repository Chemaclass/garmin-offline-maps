---
name: changelog
description: Record a user-visible change in CHANGELOG.md, or cut a version section at release time. Use after adding a feature, fixing a bug, or changing/removing behaviour someone would notice; when the user asks what changed, mentions the changelog or release notes, or is preparing a release.
---

# Changelog

`CHANGELOG.md` at the repo root. [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
format, [SemVer](https://semver.org/spec/v2.0.0.html) versioning.

## What earns an entry

**Only things a user would notice.** The test is: would someone who installs the
app, or builds a pack, experience this differently?

| Earns an entry | Does not |
|---|---|
| New feature, new device support | Refactors, renames, file moves |
| Behaviour change, new default | Test reorganisation, new tests |
| Bug fix someone could have hit | Doc edits, CI tweaks, tooling config |
| New/changed packer flag or output | Internal constants nobody sets |
| Performance or memory change they would feel | Comment fixes |

When in doubt, leave it out. A changelog padded with refactors stops being read,
and this repo already keeps its engineering history in git.

## Adding an entry

1. Open `CHANGELOG.md` and find `## [Unreleased]`.
2. Pick the section (`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`,
   `Security`) and create it if missing, keeping that order.
3. Add one line at the **end** of that section's list.

Write what changed from the user's side:

```
- **Waypoints.** Drop a pin on the map, save it, and see bearing and distance
  back to it from anywhere in the pack.
```

Not how it was built:

```
- Added WaypointStore.mc and a new layer id in classify.py     <- no
```

No file paths, no commit hashes, no "refactored X to support Y". Lead with the
capability in bold when it is a feature; a plain sentence is fine for a fix.
One or two lines each.

If an entry for the same change already exists, amend it rather than adding a
second: several commits often add up to one user-visible change.

## Honesty rules for this project

- Describe what the change does, not how thoroughly it was tested. The
  changelog is read by users deciding whether to install, not by reviewers
  auditing coverage.
- Do not list work that is planned or in progress. The roadmap lives in
  `README.md`.
- If a change only shows up when someone rebuilds their pack, say so. Packs are
  compiled in, so users do not get map changes without repacking.

## Cutting a release

1. Choose the version. Breaking pack-format or manifest changes bump major, new
   features minor, fixes patch. A format-version bump in `docs/FORMAT.md` is
   always at least a minor.
2. Rename `## [Unreleased]` to `## [x.y.z] - YYYY-MM-DD` using today's real date.
3. Add a fresh, empty `## [Unreleased]` above it.
4. Update the link definitions at the bottom of the file.
5. Sanity-check the section against `git log` since the last tag. A
   user-visible change that never got an entry is the usual miss. Read the
   diff, not just the subjects: a commit labelled `ref:` has carried
   user-visible fixes before.
6. Commit as `docs: cut x.y.z`, then tag and push:

```bash
git tag -s vX.Y.Z -m "vX.Y.Z

<a few lines of prose, not the bullet list>"
git push origin main
git push origin vX.Y.Z          # tags do not ride along with a branch push
```

7. **Create the GitHub release.** A pushed tag is not a release: it shows under
   `/tags`, and the Releases page stays empty until a release object exists.

The body is that version's CHANGELOG section verbatim, from the first `###`
heading down to the next `## [`:

```bash
python3 - <<'PY' > /tmp/notes.md
import re
text = open("CHANGELOG.md", encoding="utf-8").read()
print(re.search(r"## \[X\.Y\.Z\] - [\d-]+\n(.*?)\n## \[", text, re.S).group(1).strip())
PY
gh release create vX.Y.Z --title vX.Y.Z --notes-file /tmp/notes.md
gh release list --limit 3      # confirm it is there and marked Latest
```

No assets. The `.iq` goes to Garmin, not to GitHub.

Releasing to the Connect IQ store also needs `make package` and the same
`developer_key` that signed any previous upload. See `.claude/skills/sdk`.
