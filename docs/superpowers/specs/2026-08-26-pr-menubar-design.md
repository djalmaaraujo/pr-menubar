# PR Bar — design spec

A native macOS menu bar app that lists **your open pull requests** across the
GitHub orgs/accounts you have access to, using the `gh` CLI already installed
and authenticated on your machine. Each row shows state, title, `#id`,
repository, and CI progress. PRs stacked on one another are shown visually as an
indented tree. Filter by org/user via a dropdown.

Modeled after `claude-usage-menubar`: single Swift file, `swiftc` build, zero
runtime dependencies, same visual palette.

## Goals

- List PRs **authored by me** (`--author=@me`), open state only.
- Filter by org/user via a dropdown auto-populated from the accounts I can see.
- Per row: state, title, `#number`, `owner/repo`, CI rollup status.
- Visually represent **stacked PRs** (base→head branch chains).
- Menu bar shows the app icon + count of open PRs in the current filter.
- Click a row → open the PR in the browser.
- Clear failure states (gh missing / not logged in / offline) with retry.

## Non-goals (YAGNI)

Cut for a first simple release: auto-update / Homebrew tap, notch alert panel,
threshold alerts, token stats/charts, review actions, non-authored PRs
(review-requested/assigned/involves), closed/merged history.

## Stack & packaging

- **Language/UI:** Swift 6, SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`.
- **Build:** `app/build.sh` runs `swiftc -parse-as-library` producing
  `build/PRBar.app`, ad-hoc codesigned. No Xcode project.
- **Frameworks:** SwiftUI, AppKit only. Zero third-party deps.
- **Bundle:** `LSUIElement = true` (menu bar only, no Dock icon).
  `LSMinimumSystemVersion 13.0`, target `arm64-apple-macos13.0`.
- **Bundle id:** `com.djalma.prbar`. Name: `PR Bar`.

## Data flow

All data comes from shelling out to `gh`. The binary is resolved the same way
`claude-usage-menubar` resolves `claude`: try known paths
(`/opt/homebrew/bin/gh`, `/usr/local/bin/gh`), then fall back to
`$SHELL -l -i -c 'command -v gh'`. `PATH` is augmented with
`/opt/homebrew/bin:/usr/local/bin` and cwd pinned to `$HOME`. Every `Process`
drains its stdout pipe **before** `waitUntilExit()` and has a watchdog that
terminates a hung child after a timeout.

Two steps, both verified against the real CLI:

**Step 1 — find PRs (one call).** `gh search prs` does *not* expose CI or branch
fields, so it is used only to enumerate:

```
gh search prs --author=@me --state=open [--owner=ORG] --limit 100 \
  --json number,repository,title,isDraft,createdAt
```

`repository` gives `nameWithOwner` (e.g. `99Drive/DataServicesAPI`). When a
specific org filter is active, `--owner=ORG` is added; for "All", it is omitted.

**Step 2 — enrich each PR (parallel, bounded).** `gh search prs` lacks CI and
branch data; `gh pr view` has them:

```
gh pr view <number> --repo <owner/repo> \
  --json number,title,state,url,isDraft,reviewDecision,headRefName,baseRefName,statusCheckRollup
```

Run with bounded concurrency (~6 at a time) to stay responsive without
hammering the API. A single failed enrichment degrades that one row (unknown CI)
rather than failing the whole list.

## Org/user filter

The dropdown options are the **union** of:

1. `gh api user/orgs --jq '.[].login'` — orgs with visible membership.
2. Owners that actually appear in the current PR results — this recovers orgs
   whose membership is private and therefore absent from step 1 (confirmed: a
   real PR lived in `99Drive`, an org not returned by `user/orgs`).
3. `@me` — the personal account (own repos).
4. **All** — no `--owner` filter (default).

Selected filter persists in `UserDefaults` (`selectedOwner`). Selecting an owner
re-runs step 1 with `--owner`.

## CI status

`statusCheckRollup` is an array of check contexts (each with
`status`/`state`/`conclusion`). Reduce to one of four:

| Rollup | Meaning | Glyph | Color |
|--------|---------|-------|-------|
| `.success` | all checks passed | ✓ filled circle | green |
| `.failure` | any failed / errored / timed out | ✕ | red |
| `.pending` | any queued / in-progress and none failed | ◐ | amber |
| `.none` | no checks configured / empty array | · | secondary/grey |

Reduction rule: failure if any context is failure/error/timed_out/action_required;
else pending if any is pending/queued/in_progress/waiting; else success if there
is at least one successful context; else none.

## Row state

Derived per PR, in priority order:

- **Draft** (`isDraft`) → grey dot, "Draft".
- **Changes requested** (`reviewDecision == CHANGES_REQUESTED`) → red-ish.
- **Approved** (`reviewDecision == APPROVED`) → green.
- **Open / review required** otherwise → the accent color.

Row layout: `[state dot]  title  #123  ·  owner/repo  [CI glyph]`. The whole row
is a button; clicking opens `url` via `NSWorkspace.shared.open`.

## Stacked PRs

Within the **same repository**, PR *B* is stacked on PR *A* when
`B.baseRefName == A.headRefName`. Build a forest:

- Roots: PRs whose `baseRefName` is not the `headRefName` of any other PR in the
  same repo (typically based on `main`/`master`).
- Children: attached under the PR whose `headRefName` matches their base.
- Render depth-first, indenting children and drawing a vertical guide (`│`) so a
  chain of N is visible at a glance.

Only PRs present in the current filtered list participate — a missing
intermediate PR just means the chain renders from what is known. Cycles (should
not happen) are broken by tracking visited nodes.

## Menu bar label

Icon + count of open PRs in the current filter (e.g. icon then `7`). Count
hidden when 0. Icon is a template PNG (`isTemplate = true`, explicit
`NSImage.size`, **no** `.resizable()`/`.frame()` — same constraints as the
reference app, or `MenuBarExtra` renders nothing). Warning triangle
(`exclamationmark.triangle`) replaces the icon on error.

## Refresh & lifecycle

- Refresh on launch, then a 60s `Timer`, plus a manual refresh button.
- `@MainActor` `PRStore: ObservableObject` holds `[PullRequest]`, `lastUpdated`,
  `errorText`, `isLoading`.
- Popover body: header (filter dropdown + refresh + count), the PR tree, a
  footer (last-updated, quit).

## Error handling

- `gh` not found → "Install GitHub CLI (`brew install gh`)".
- Not authenticated (`gh` exits non-zero / auth error) → "Run `gh auth login`".
- Offline / timeout → generic retry message.
- Any error: menu bar swaps to warning triangle; popover shows the message + a
  Retry button instead of an empty list.

## Testable units (pure, no Process)

Isolated from I/O so they can be exercised directly:

- `rollupState(from: [CheckContext]) -> CIState` — the 4-way reduction.
- `buildStackForest(_ prs: [PullRequest]) -> [StackNode]` — grouping + tree.
- `mergeOwners(orgs:, resultOwners:) -> [String]` — dropdown union, deduped,
  sorted, `All`/`@me` pinned.
- `decodePRs(from: Data) -> [PullRequest]` — JSON decoding of `gh` output.
- `rowState(for: PullRequest) -> RowState` — draft/approved/changes/open.

A standalone `app/Tests.swift` compiled and run with `swiftc` asserts these
against fixture JSON (captured from real `gh` output). `build.sh` gains a
`--test` path, or a separate `test.sh`.

## Deliverables

- `app/App.swift` — the whole app.
- `app/Tests.swift` — pure-unit tests over fixtures.
- `app/build.sh`, `app/test.sh`, `app/Info.plist`.
- `app/make_icon.swift` + generated menu bar PNG(s) + `AppIcon.icns`.
- `README.md` — badges, screenshots, install/build, what-it-does (matching the
  reference's shape).
- `docs/index.html` — landing page reusing the palette.
- `.gitignore` — ignores `app/build/`.

## Palette (from the reference)

Cyan `#22d3ee`, indigo `#6366f1`, sky `#38bdf8`, slates `#0f172a` / `#94a3b8` /
`#e2e8f0`, deep indigo `#1e1b4b`. Green/red/amber for CI reuse system semantic
colors tuned to sit with the palette.

## Manual test instructions

1. `cd app && ./build.sh` → app builds clean and launches.
2. Menu bar shows the icon + a PR count.
3. Open the popover: PRs authored by me are listed with state, `#id`, repo, CI.
4. Change the org in the dropdown → list refilters; an org with private
   membership (not in `user/orgs`) still appears because it showed up in results.
5. A repo with a stacked chain renders indented with the vertical guide.
6. Click a row → the PR opens in the browser.
7. Kill network / rename `gh` on PATH → popover shows the matching error + retry;
   menu bar shows the warning triangle.
8. `cd app && ./test.sh` → all pure-unit assertions pass.
